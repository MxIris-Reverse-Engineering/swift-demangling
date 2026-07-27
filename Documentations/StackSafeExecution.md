# 栈安全执行：从「每次新建线程」到「复用 + 乐观内联」

## 动机

`StackSafeExecutor` 是本库所有递归入口（demangle / remangle / print）的栈安全包装。它的判断逻辑是：

```swift
private static let minimumRequiredStackSize = 2 * 1024 * 1024 // 2MB

private static var currentThreadHasSufficientStack: Bool {
    let remainingStackSpace = currentAddress - Int(bitPattern: stackBase)
    return remainingStackSpace >= minimumRequiredStackSize
}
```

判断的是**当前栈剩余空间是否 ≥ 2 MB**。实测三类线程的栈事实（Apple silicon，macOS 26）：

| 线程 | 栈总大小 | 进入时剩余 | 判断结果 |
|---|---|---|---|
| 主线程 | 8,372,224 (8 MB) | 8,358,432 | 够 → 内联执行 |
| `DispatchQueue.global()` | 536,576 (524 KB) | 536,064 | **不够 → 另起线程** |
| Swift Concurrency 协作线程 | 536,576 (524 KB) | 535,568 | **不够 → 另起线程** |

后两类线程的**栈总量**（524 KB）就低于阈值（2 MB），因此剩余空间无论如何都不可能达标 —— 判断在这两类线程上**恒为假**。也就是说：只要不在主线程上，每一次 demangle、每一次 remangle、每一次 print 都会新建一条 8 MB 栈的 `Thread`，用信号量等它跑完，然后销毁。

这不是边缘情况，而是常态：`SymbolIndexStore` 的索引构建跑在 `DispatchQueue.global()` 上，逐个符号调用 `demangleAsNodeTransient`；任何 `async` 的打印管线都跑在协作线程上。实测单次线程建立/销毁成本约 50 µs：

| 场景（2000 次，同一符号） | 主线程 | 512 KB 栈线程 | 倍率 |
|---|---|---|---|
| `demangleAsNodeTransient` | 63.9 ms | 162.5 ms | 2.54× |
| `Node.print(using:)` | 20.8 ms | 127.5 ms | **6.12×** |

打印那一行最能说明问题：打印本体只要约 10 µs，线程开销 53 µs —— **开销是本体的 5 倍**。按一个框架 20 万个符号估算，仅线程建立就是十秒量级的纯浪费。

## 改动

分两层，互相独立、叠加生效。

### 第一层：常驻线程复用（`LargeStackThreadPool`）

把「每次 `Thread(...)` + `start()` + 销毁」换成一个按需增长、空闲回收的常驻大栈线程池：

- 提交任务时，仅当**待处理任务数超过空闲 worker 数**才新建线程；竞态下多建一条也无妨，它会在空闲超时（30 秒）后自行退出。
- worker 拿到任务就执行，执行完回到 `NSCondition` 上等下一个，不销毁。
- worker 自身跑在 8 MB 栈上，因此它内部的嵌套调用（例如 demangler 调用 remangler 处理 opaque return type）走的是 `currentThreadHasSufficientStack` 的内联分支，**不会**再往池子里提交，从而不存在「池子被占满导致自我死锁」的风险。

这一层对 demangle / remangle / print **三条路径同时生效**，且完全不触碰任何递归引擎。

### 第二层：乐观内联 + 栈预算回退（`executeWithinStackBudget`）

线程池把单次成本从 ~50 µs 降到 ~8 µs（信号量往返 + 上下文切换），但这 8 µs 仍然是白付的 —— 绝大多数符号的递归深度只有几十帧，压根不需要 8 MB 栈。

于是新增一条乐观路径：

```swift
StackSafeExecutor.executeWithinStackBudget { stackFloorAddress in
    // 在当前线程直接跑，递归逼近 stackFloorAddress 时返回 nil 放弃
} unbudgetedFallback: {
    // 只有放弃了才在大栈 worker 上无限制重跑
}
```

`stackFloorAddress` 由当前线程的栈底加上 64 KB 安全余量算出。打印引擎在**已有的递归收敛点** `DemanglingPrinter.printName` 上做检查 —— 该函数是所有打印递归的必经之路（原本就在那里做 `maxPrintDepth` 判断），因此覆盖是完整的：

```swift
if didExhaustStackBudget { return nil }          // 已放弃：快速退栈
if stackFloorAddress != 0 {
    var stackProbe = 0
    let currentAddress = withUnsafeMutablePointer(to: &stackProbe) { UInt(bitPattern: $0) }
    if currentAddress <= stackFloorAddress {
        didExhaustStackBudget = true
        return nil
    }
}
```

用**实测栈指针**而不是固定深度阈值，是刻意的选择：每帧占用多少字节随 `Target` 类型（`String` 与 `SemanticString` 的帧大小不同）和优化级别变化，固定深度必然要保守到浪费；直接比地址则无需猜测，且天然适配任何栈大小的线程。

放弃时整个 printer 值被丢弃、在大栈上重跑，因此中途写入 `target` 和 `printCache` 的残缺片段不会外泄。

## 效果

同一台机器、同一符号、2000 次：

| 场景 | 改动前 | 仅线程池 | 线程池 + 栈预算 |
|---|---|---|---|
| `print` @512 KB 栈线程 | 127.5 ms | 42.4 ms | **17.5 ms** |
| `demangle` @512 KB 栈线程 | 162.5 ms | 78.0 ms | 74.8 ms |
| 32 任务并发 6400 次 demangle | 162.7 ms | 101.1 ms | 99.6 ms |

打印路径提速 **7.3 倍**，且在 512 KB 栈线程上的耗时已低于主线程 —— 跨线程成本完全消失。

## 影响面与限制

- **行为不变**：深递归仍然受保护，只是保护方式从「无条件换线程」变成「先试，不够再换」。`maxPrintDepth`（768 帧，对齐上游 C++ `NodePrinter`）与 `<<too complex>>` 语义保持原样。
- **只有打印路径接入了第二层**。`Demangler` 没有单一递归收敛点（`demangleType` / `demangleOperator` 等多个方法互递归），`Remangler` 虽有收敛点 `mangle(_:depth:)` 但暂未接入。两者目前只享受第一层的线程复用收益。若后续要给 demangler 加栈预算，前提是先为它建立一个真正覆盖全部递归路径的收敛点 —— 保护不完整反而比现状危险。
- **非 Darwin 平台**行为不变（整套机制都在 `#if canImport(Darwin)` 内，其他平台一律直接执行）。
- **回归验证**：MachOSwiftSection 的 `MachOSwiftSectionTests` + `SwiftLayoutTests` 全量对比，改动前后失败集合逐条一致（157 项，均为该分支既有失败）；`SwiftDumpTests` / `SwiftPrintingTests` / `MachOSymbolsTests` 共 100 项中除一项既有的快照失败外全部通过。
