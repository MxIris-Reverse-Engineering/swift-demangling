# 栈安全：把「数帧」换成「量栈」

日期：2026-07-28

对应提案：`evolution/0002-stack-safety.md`

## 动机

两个症状，同一个根因。

**症状一：合法的深嵌套泛型被拒绝。** SwiftUI 里返回 `some View` 的声明，其底层具体类型可以嵌套得非常深。这类符号完全合法，但 release 构建下：

- `print` 嵌套到约 **384 层**就返回 `<<too complex>>`；
- `mangleAsString` 嵌套到约 **256 层**就返回 `.tooComplex`。

此时线程栈还剩几十兆，纯粹是被上限挡掉的。

**症状二：debug 构建下会崩。** 同一批符号，debug 构建在 8MB 的 worker 线程上：

- `mangleAsString` 到 **150 层** SIGBUS；
- `print` 到 **375 层** SIGBUS。

深度上限还没触发，栈就先耗尽了。

**根因：用帧数近似栈字节。** 三个引擎的护栏都是固定帧数（`NodePrinter` 768、`Remangler` 1024、`TypeDecoder` 1024，照搬上游 C++ 的 `MaxDepth`）。而「一帧多少字节」在以下三个维度上都不是常量：

- **构建配置**：debug 的帧比 release 大一个数量级。上游那三个常数是按 release 的帧大小定的，所以在 debug 下形同虚设。
- **泛型特化**：`DemanglingPrinter` 泛型于 `DemanglingNode`，会为 `Node`（class 引用）和 `NodeReference`（16 字节值类型）各特化一份，两份的帧大小不同。一个常数不可能同时对两者正确。
- **线程栈大小**：主线程 8MB，Swift 并发协作线程和 libdispatch 线程各 512KB，自建 `Thread` 任意。同一个帧数在不同线程上意味着完全不同的安全边界。

**调大常数解决不了问题**：调大到能容纳合法深符号，debug 就崩；调小到 debug 安全，release 就拒绝更多合法符号。这两个方向互相排斥。

## 上游怎么做的

`swift/lib/Demangling/` 整个目录**没有任何栈相关代码**。全仓 `pthread_get_stackaddr_np` 只有 `include/swift/Threading/Impl/Darwin.h` 一处封装，唯一使用者是 `stdlib/public/stubs/Stubs.cpp`，与 demangling 无关。上游从不用剩余栈空间做决策。

它靠两件事：

1. **引擎内部的固定帧数上限**（就是上面那三个常数）；
2. **调用方在任务边界上一次性换到大栈线程**：
   - SourceKit 的 `WorkQueue` 有个 `isStackDeep` 标志，命中时起一条 8MB 的 `llvm::thread` 跑完 join（`Concurrency-libdispatch.cpp`）。全 SourceKit 只有一处传 `true`（`Requests.cpp`，语义请求队列）——**一个请求一次，不是一次 demangle 一次**。
   - IRGen 的 worker 线程建的时候直接 `pthread_attr_setstacksize(8MB)`（`IRGen.cpp`），注释写着「macOS 默认 512KB，提到 8MB 和主线程一致」。
   - `ModuleInterfaceBuilder` 用 `CrashRecoveryContext().RunSafelyOnThread(..., 8MB)`。

值得注意的是：**上游的 remangler 有和本仓完全相同的无保护递归**——`RemanglerBase::hashForNode` 对每个 child 调 `entryForNode`，后者再调回 `hashForNode`，整条链没有 depth 参数；`SubstitutionEntry::deepEquals` 同样无界。上游能活下来，靠的就是「调用方保证在大栈上」这个前提。

作为库，我们没法把决策上推到调用方的任务边界，所以需要一个自己的答案。

## 方案

### 一、护栏改成量剩余栈字节

新增 `Utils/StackBudget.swift`。它在操作入口按当前线程的栈边界算出一个 floor（栈底 + 预留量），递归时把栈指针和 floor 比较。

- **每层都探**。曾经试过「每 N 层探一次、N 由预留量除以假定的每层开销推出」，**这是不安全的**：假定值必须对任意引擎、任意构建配置的最大帧都成立，一旦不成立，两次探针之间就能跨过整个预留区照样崩。猜帧大小正是固定帧数上限犯的错，这个类型的存在就是为了不再犯。实测代价见下。
- **读取动作放在 `@inline(never)` 辅助函数里**。对局部变量取地址会给所在函数的序言塞进 stack-protector 检查；隔离到一个小函数后，热路径的递归函数不受影响，只付一次调用。
- **非粘性**。某条深路径触发后照常写 `<<too complex>>` 并退栈；等递归退回到浅层兄弟节点时栈已经空出来了，兄弟节点正常输出。这与原来「一条深路径退化、其余不受影响」的语义一致，也避免了标记刷屏。
- **保留一个极大的帧数兜底**（`absoluteDepthLimit = 1_000_000`），只用来防节点图成环导致的真无限递归——环不会逼近栈底，光靠栈探针停不下来。

预留量取 `min(1MB, max(栈大小 / 8, 32KB))`：小栈上 1MB 会吃掉全部预算，所以按比例缩。

### 二、worker 栈 8MB → 64MB

线程栈是**虚拟地址空间预留**，只有真正写到的页才分配物理内存。所以放大栈的代价是地址空间（64 位下不稀缺），不是常驻内存。

### 三、堵掉所有无保护递归

护栏只有装在收敛点上才有效。动手前做了一次调用图审计：把每个引擎的函数调用图建出来，用 Tarjan 找强连通分量，然后**把候选收敛点从图里删掉再找一次**——剩下的环就是护栏覆盖不到的。

结果：

| 引擎 | 候选收敛点 | 删掉后剩余的环 |
|---|---|---|
| `DemanglingPrinter` | `printName` | 1 条：`findSugar` |
| `Remangler` | `mangle` + `mangleAnyNominalType` | **6 条**（去掉误报后） |
| `TypeDecoderEngine` | `decodeMangledType` | 4 条 |

（误报三个：`mangleIdentifier` 和 `mangleProtocolList` 是重载不是自递归，`lookupWord` 是嵌套局部函数。）

Remangler 那 6 条的处理：

| 递归 | 处理 |
|---|---|
| `hashForNode` ↔ `entryForNode` | **改成迭代**（显式栈后序折叠），缓存语义逐条保持 |
| `SubstitutionEntry.deepEquals` | **改成迭代**（成对工作队列） |
| `isSpecialized` | **改成循环**（本来就是尾递归） |
| `getUnspecialized` | 加独立深度上限（要在退栈时重建节点，不能改循环） |
| `mangleGenericArgs` | 补护栏检查（本来带 `depth` 但从不检查） |
| 7 个 protocol conformance 函数的互递归环 | 同上，逐个补 |

Printer 的 `findSugar` 只沿单子 `.type` 链下降，给了一个独立的小上限。TypeDecoder 的 6 处检查全部接上护栏。

### 四、顺带堵掉既有的全树递归

它们不属于任何引擎，因此从来不在任何护栏覆盖范围内：

- **`NodeCache.internTreeUnsafe`** —— 自底向上 hash-consing。`demangleAsNode` 默认 `internsSubtrees: true`，所以**每次 demangle 都会跑这趟**。改成迭代。
- **`Node.==` / `Node.hash(into:)`** —— 公开 API，深树上无界递归。改成迭代。（哈希的访问顺序变了，但相等的树仍产生完全相同的 `combine` 序列，契约只要求这个。）
- **store 侧五条**：`NodeStoreBuilder.internTree`（原 `internRecursively`）、`NodeStore.materializeNode`、`NodeReference.structurallyEquals` 两个重载、`NodeReference.structuralHash`。全部改成迭代。其中 `structurallyEquals(_ other: NodeReference)` 的同 store 短路现在在**每一层**生效，不只根节点。

`NodeStoreBuilder` 那条值得单独说：`demangle(_:isType:)` 把 transient demangle 交给 `StackSafeExecutor`，但**返回之后才 intern**，而 intern 跑在调用方自己的线程上。批量索引场景下那就是一条 512KB 的协作线程——恰恰是最深的泛型类型到达的地方。改成迭代之前实测：debug 下 **500 层**崩、release 下 **1200 层**崩。这个形状是 `NodeStoreBuilder.demangle` 本来就有的（不是本次改动引入），但本次把「支持深嵌套」立为目标之后，它就从边缘风险变成了必须堵的口子。

### 五、`Node` 改成迭代式析构

这条谁都没提，但它是支持深树的必要条件：**释放一棵引用类型的树本身就是递归的**——释放根会释放孩子，孩子的 deinit 再释放它的孩子，一层一帧。实测 512KB 线程上释放 620 层的树直接崩。

而且这条**任何引擎侧的护栏都覆盖不到**：释放发生在最后一个引用消失的地方，由运行时执行，不经过本库任何代码。

`Node.deinit` 改成：把孩子摘进一个显式工作队列然后逐个排空。只有在「这是最后一个引用」时才拆解一个节点（`isKnownUniquelyReferenced`），否则它还活着、必须保留孩子。因为每个被唯一引用的节点在释放前孩子已被摘走，它自己的 deinit 就没有可下降的东西了。

### 六、线程池重做

原来是**每次调用新建一条 `Thread` 再 join**，实测每次约 41 µs——对一个典型符号是本体工作量的 5～18 倍，索引一个框架就是好几秒的纯开销。

新的池子有三条承重性质：

- **worker 不退休。** 「空闲超时退休」有一个窗口：超时触发后 worker 要重新抢锁，这期间的提交会把它算作可用、于是不建替补也没人接收信号，任务就此丢失、调用方永久阻塞。保持 worker 存活是消除这个窗口，而不是试图关上它。空闲 worker 的代价是一个内核线程结构；它们的 64MB 栈是没被写过的地址空间。
- **池子有上限**（`activeProcessorCount`），所以并发突发不会无限建线程——`executeAsync` 立即返回、自身毫无背压。
- **worker 绝不等待池子。** printer 会为嵌套的 mangled 名字重新进入 demangle，这类从 worker 发出的提交会在有上限的池子上死锁。用线程本地标记识别 worker，让这些调用直接内联跑——它们本来就已经在大栈上了。

队列用头指针出队，不用 `removeFirst()`（那是持锁的 O(n) memmove）。每个 work item 包一层 `autoreleasepool`，否则 autorelease 对象的释放点会从「调用结束」漂移到「进程结束」。

### 七、新增批量作用域 API

`StackSafeExecutor.withLargeStack { }`，对应上游 SourceKit 的 `isStackDeep`。批量索引在最外层包一次，里面所有 demangle / print / remangle 直接内联跑，线程往返开销归零。

## 数据

**深度能力**（debug 构建，嵌套 Optional 符号）：

| | 改之前 | 改之后 |
|---|---|---|
| `print` | 384 层返回 `<<too complex>>`，**375 层崩溃** | **3000 层正常打印**，不崩 |

**线程往返开销**（release，512KB 线程）：

| 操作 | 改之前 | 改之后 | 改善 |
|---|---|---|---|
| `demangleAsNode` | 46.73 µs | 12.48 µs | −73% |
| `print` | 43.10 µs | 8.49 µs | −80% |
| `mangleAsString` | 53.89 µs | 17.73 µs | −67% |

**批量作用域**：50 次 demangle，用 `withLargeStack` 包住是 6.43 µs/次，不包是 11.3 µs/次；主线程内联基线是 6.58 µs/次——**作用域内的往返开销为零**。

**正确性**：dyld 共享缓存全量语料 **4,522,325 个真实符号**，demangle 失败 0、node tree 不一致 0、remangle 不一致 0。

## 影响面

- **`NodePrinter.maxPrintDepth` 标记为 deprecated**。它不再是护栏，保留只为让读它的代码继续编译。
- **`Remangler.maxDepth` / `TypeDecoder.maxDepth` 提高到兜底值**，实际限制由栈决定。
- **行为变化**：以前返回 `<<too complex>>` / `.tooComplex` 的深符号，现在多数会正常输出。依赖「超过 N 层就截断」的调用方需要知道这一点。
- **`StackSafeExecutor` 新增 `withLargeStack(_:)`**，批量消费方应当采用。
- **`Node.==` / `hash(into:)` 的遍历顺序变了**。哈希值在同一进程内自洽（Swift 的 `Hasher` 本来就是每进程随机种子），跨版本本就不保证稳定。
- **非 Darwin 平台**：`StackBudget.forCurrentThread()` 退化为 unlimited，行为与改动前一致（只剩兜底帧数上限）。

## 迁移注意事项

- 批量场景请改用 `StackSafeExecutor.withLargeStack { }` 包住整批，而不是依赖逐次调用的自动跳转。
- 直接驱动 `DemanglingPrinter` / `NodePrinter` 的富文本消费方不需要改动：护栏在 `printName` 内部，`printRoot` 也受保护。
- 若消费方自己建线程跑 demangling，建议把 `stackSize` 设为 64MB 并在其上直接调用——`StackSafeExecutor` 会判定栈足够而全程内联，零往返。

## 未解决 / 待评估

- **`Node.Rewriter.visit`** 仍是递归。它是 `open class`，子类可以任意重写，改成迭代会改变可重写点的语义，留待单独评估。
- **printer 改成显式栈迭代**（彻底与线程栈解耦）暂未做：64MB 已足够任何真实符号，而 printer 带着 `printCache`、`asPrefixContext` 等状态，迭代化的出错面远大于收益。
- 每层探针的实测代价尚未单独量化（当前数据是端到端的，且端到端是净改善）。若后续发现是热点，可考虑「探针 + 观测到的实际每层开销自适应调整间隔」，而不是回到固定间隔。
