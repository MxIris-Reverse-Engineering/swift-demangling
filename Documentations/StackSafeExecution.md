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

### 保护归位：从调用方约定改为引擎内建

第二层刚落地时，每个打印入口都要自己写一遍 `executeWithinStackBudget` 的两个闭包。这是**约定式**保护：调用方得记得包，漏一个就是静默失去保护。而这个坑已经踩过一次——MachOSwiftSection 的 `printSemantic` 直接驱动 `DemanglingPrinter`，历史上就没包 `StackSafeExecutor`，深嵌套泛型符号能把它打爆；这次第二层落地时它又一次没跟上，白付跨线程开销。同一个位置栽两回，说明责任放错了地方。

于是把保护挪进引擎，成为 `DemanglingPrinter.print(_:options:)`：

```swift
public static func print(_ root: SomeNode, options: DemangleOptions = .default) -> Target {
    StackSafeExecutor.executeWithinStackBudget { stackFloorAddress in
        var printer = DemanglingPrinter(options: options)
        return printer.printRootWithinStackBudget(root, stackFloorAddress: stackFloorAddress)
    } unbudgetedFallback: {
        var printer = DemanglingPrinter(options: options)
        return printer.printRoot(root)
    }
}
```

它**必须是 static**：回退要用一个全新的 printer 重跑，而 `printRoot` 是 `mutating`，放弃那次已经污染了实例状态，没法自己重来。

`printRoot` / `printRootWithinStackBudget` 保留为低层入口，供已知有栈余量、想自己管理 printer 生命周期的调用方使用；库内四个打印入口全部塌缩成一行转发。`Node.description` 是例外，它走的是私有的 `printNode` 树 dump（debug 用途）而非打印引擎，继续用第一层。

### Remangler

`Remangler` 用完全相同的形状接入（`mangleWithinStackBudget(_:stackFloorAddress:)`），检查点放在它已有的收敛点 `mangle(_:depth:)` 上——那里原本就在做 `maxDepth`（1024，对齐上游 `Remangler.cpp`）判断。放弃时丢弃整个 remangler 值，残缺的 `buffer` 同样不会外泄。因为 remangle 是 `throws(ManglingError)`，`StackSafeExecutor` 相应多一个 typed-throws 重载；其中「抛错」与「预算耗尽」是两回事：抛错说明树本身有问题，直接向上传播而不去 worker 上重跑（重跑只会复现同一个错误），预算耗尽才走回退。

## 效果

同一台机器、同一符号、2000 次：

| 场景 | 改动前 | 仅线程池 | 线程池 + 栈预算 |
|---|---|---|---|
| `print` @512 KB 栈线程 | 127.5 ms | 42.4 ms | **17.5 ms** |
| `remangle` @512 KB 栈线程 | — | 160.0 ms | **130.1 ms** |
| `demangle` @512 KB 栈线程 | 162.5 ms | 78.0 ms | 74.8 ms |
| 32 任务并发 6400 次 demangle | 162.7 ms | 101.1 ms | 99.6 ms |

打印路径提速 **7.3 倍**，且在 512 KB 栈线程上的耗时已低于主线程；remangle 从 1.24 倍主线程耗时回落到 1.00 倍 —— 两条路径的跨线程成本都完全消失。

提升幅度的差异完全由「本体耗时」决定：print 本体约 10 µs，线程开销占 84%，所以收益最大；remangle 本体约 65 µs，开销占比小，收益相应就是约 20%。

## 影响面与限制

- **行为不变**：深递归仍然受保护，只是保护方式从「无条件换线程」变成「先试，不够再换」。`maxPrintDepth`（768 帧，对齐上游 C++ `NodePrinter`）、`Remangler.maxDepth`（1024，对齐上游 `Remangler.cpp`）与 `<<too complex>>` / `.tooComplex` 语义都保持原样。
- **`Demangler` 只享受第一层的线程复用**，这是刻意的，且与上游一致：它的主解析路径**根本不是递归下降**——`parseAndPushNames()` 是 `while !scanner.isAtEnd` 配合 `nameStack` 显式栈，嵌套结构靠弹栈拼装而非调用栈，所以上游 `Demangler.cpp` 同样没有任何递归深度限制（有 `depth` 的是 `Remangler` 和 `NodePrinter`，本库两者都已对齐）。对 160 个方法做过调用图分析，真正参与递归的只有 21 个，且都不在主循环上：`demangleBoundGenericArgs`（深度 = 嵌套泛型上下文层数）、`setParentForOpaqueReturnTypeNodesImpl` ↔ `getParentId`（树遍历），以及 19 个 `demangleSwift3*` 组成的互递归团（Swift 3 老 mangling 才是真正的递归下降）。前两类深度很浅；Swift 3 那条路径理论上可被构造的深嵌套老符号打爆栈，但今天 `_T` 前缀符号已基本绝迹。若将来要给它加保护，正确做法是只覆盖这 21 个方法，而不是给全部方法塞一个恒为常数的参数。
- **非 Darwin 平台**行为不变（整套机制都在 `#if canImport(Darwin)` 内，其他平台一律直接执行）。
- **回归验证**：MachOSwiftSection 的 `MachOSwiftSectionTests` + `SwiftLayoutTests` 全量对比，改动前后失败集合逐条一致（157 项，均为该分支既有失败）；`SwiftDumpTests` / `SwiftPrintingTests` / `MachOSymbolsTests` 共 100 项中除一项既有的快照失败外全部通过。
