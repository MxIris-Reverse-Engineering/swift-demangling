# 栈安全：与上游同构的「8MB 大栈 + 帧数上限」模型

日期：2026-07-29（首版 2026-07-28 采用按剩余栈字节的 `StackBudget` 方案，后按 review 结论撤回，见「曾经的方案与撤回原因」）

对应提案：`evolution/0002-stack-safety.md`

## 最终模型（一句话）

三个递归引擎各带一个**按 debug 帧大小实测校准的固定深度上限**；`StackSafeExecutor` 在调用线程剩余栈不足 2MB 时把工作搬到 **8MB 常驻 worker 池**；所有不经过引擎入口的整树遍历（interning、`copy`、`Rewriter`、析构、remangler 的替换哈希等）一律**迭代**，不依赖任何护栏。

这与 Swift 上游的模型同构，且每个常数都有实测依据。

## 动机

两个症状，同一个根因。

**症状一：debug 构建下固定深度上限够不着，先崩。** 上游三个常数（`NodePrinter` 768、`Remangler` 1024、`TypeDecoder` 1024）按 release 帧大小校准。本库会被消费方以 debug 配置编译，而 debug 的帧大一个数量级。实测（8MB 线程、嵌套 `Optional`）：

- printer：725 层存活、745 层 SIGBUS——**768 的上限永远轮不到生效**；
- remangler：上限之外还有个洞（见下），150 层就崩；
- TypeDecoder：约 125 层崩，1024 的上限纯属装饰。

**症状二：remangler 的上限有结构性绕过。** `hashForNode` ↔ `entryForNode` 是一对互递归，第一次 `trySubstitution` 时就把整棵子树走完，全程不经过 `mangle(_:depth:)`——depth 计数器根本没机会涨。上游 C++ 有完全相同的洞，靠「调用方保证在大栈上」活着。

## 上游怎么做的（实证）

`swift/lib/Demangling/` **没有任何栈相关代码**，只有固定深度常数。它的运行环境靠调用方安排：

- **IRGen worker 线程**（`IRGen.cpp`）：`pthread_attr_setstacksize(8MB)`，注释原话 "Increase the thread stack size on macosx to 8MB (default is 512KB). This matches the main thread."
- **ModuleInterfaceBuilder**（`ModuleInterfaceBuilder.cpp`）：`ThreadStackSize = 8 << 20`，子编译跑在 `RunSafelyOnThread(..., 8MB)` 上。
- **运行时**（`stdlib/public/runtime`）：demangle/remangle/TypeDecoder 直接跑在调用者线程上，零栈检测——赌注是 runtime 永远 release 构建、帧足够小，深度常数真能够到。
- **clang 的同款先例**（`clang/lib/Basic/Stack.cpp`）：`DesiredStackSize = 8MB`，`isStackNearlyExhausted()` 判「距底部剩余 < 256KB」，快耗尽时换到新 8MB 栈继续——「探测剩余栈 + 不够就换 8MB 栈」在 LLVM 生态有正统出处。
- **解析器为什么不用限**：新版 mangling 是后缀文法，`Demangler` 主循环靠 `NodeStack` 迭代，天生不深递归。旧版 Swift3（`OldDemangler.cpp`）是递归下降，上游给它配了 `MaxDepth = 1024`（本库的 `demangleSwift3*` 未移植该计数，`_T` 前缀符号基本绝迹，已决定不管）。

本库与上游环境唯一的本质差别：**会被人用 debug 配置编译**。所以模型照搬、常数重新校准。

## 方案

### 一、深度上限按 debug 实测重定

方法：8MB 线程、debug 构建、嵌套 `Optional` 符号逐深度探测崩溃边界，取约 30% 安全余量。

| 引擎 | 上游常数 | 实测崩溃边界 | 新常数 | 覆盖的真实嵌套层数 |
|---|---|---|---|---|
| `DemanglingPrinter.maxPrintDepth` | 768 | 725 层过 / 745 层崩 | **512** | ≈253 层 |
| `Remangler.maxDepth` | 1024 | 深度 565 过 / 605 崩（140/150 层，每层 4 深度单位） | **384** | ≈94 层 |
| `TypeDecoderEngine.maxDepth` | 1024 | 深度约 250 崩（120/130 层，每深度单位约 30KB！） | **160** | ≈78 层 |

实测过的最深真实符号（SwiftUI `View.Body` typealias）是 41 层，全部常数都有 2 倍以上余量；**4,522,325 个 dyld cache 真实符号在新常数下零失配**。代价：release 下本可以处理更深的构造性输入，现在统一在同一深度拒绝——换来的是同一符号在两种配置下行为一致。

### 二、`hashForNode` 改迭代，让 remangler 的上限第一次真正生效

互递归改成显式栈后序折叠，缓存语义逐条保持。这不是「新增保护」，是**修补 main 上已有保护的绕过**——改完之后 `maxDepth` 才是真实的上限，上表中 remangler 的边界也才有意义。它同时消灭了一个 DoS：没有深度上限时，靠栈耗尽拒绝一个 3.2 万层的构造符号要烧约 9.5 分钟 CPU（每层都重走整棵子树，Θ(D_max·N)）；深度检查 0.1 秒内拒绝。

### 三、执行器：2MB 门槛 + 8MB 常驻池

- **门槛 2MB**：剩余栈 ≥ 2MB 就地跑（clang 的对应值是 256KB，我们保守 8 倍）。主线程、消费方自建的大栈线程零开销、LLDB `po` 可用；512KB 的协作/dispatch 线程跳到 worker。
- **worker 栈 8MB**：与主线程、与上游一致。深度常数按它校准。
- **池化保留**（对 node store 批量场景是刚需：每次新建线程约 41µs，23 万符号就是约 10 秒纯开销）。稳态上限 `max(2, 核数)`，阻塞式提交可撑到 `max(32, 4×)`（扇出防互锁），异步提交守稳态上限。
- **`pthread_create` 而非 `Thread.start()`**，创建失败有返回码可查——`start()` 静默失败会永久毒化进程级单例。
- **幽灵预约不再挂死任何人**：并发提交、创建全部失败时，最后一个回滚到零的提交者**就地排空队列**再拒绝，且入队时复验存活 worker 数。之前的写法里，先回滚的提交者会把别人的幽灵预约当成存活 worker，入队后永久阻塞（测试可复现：8 个并发提交者 7 个挂死）。
- **worker 上的嵌套调用**：栈还多（≥2MB）就内联跑（嵌套 demangle 的常态）；真的深到不足 2MB 时起一条一次性 8MB 线程，绝不向自己所在的池子回提交（那个等待可能排在它自己正在执行的条目后面）。
- **`withLargeStack {}`** 保留：批量场景包一次，作用域内全部内联，零往返。

### 四、`TypeDecoder` 不再跳线程（撤回首版的包装）

`TypeDecoder` 调的是**用户代码**（`TypeBuilder` 回调），首版把整段搬到 worker 后，`@MainActor` 隔离或线程绑定的 builder 会在一个看起来同步的调用背后被移到后台线程。现在回到 main 的契约：**回调永远在调用者线程**，栈是调用者的责任，深批量自己包 `withLargeStack`。深度上限（160）保证 debug 下上限先于栈崩溃生效。

### 五、引擎之外的整树遍历：迭代（全部保留）

这些不经过任何引擎入口，护栏永远覆盖不到，迭代是唯一正确形态：

- `NodeCache.internTreeUnsafe`（每次默认 demangle 都跑）、`NodeStoreBuilder.internTree`
- `Node.==` / `Node.hash(into:)`（后者现为记忆化摘要，见 NodeStore 相关文档）
- `Node.copy()` / `replacingDescendant(_:with:)`（`NodeBuilder` 持锁期间调用）
- `Node.Rewriter.rewrite`（`rewrite` 是 `final`，只有 `visit` 是 `open`，迭代化不改变任何可重写点）
- `Node.description` 的树转储——**并且不再包 `StackSafeExecutor`**：迭代遍历不可能爆栈，而它恰是调试器 `po` 走的路，包一层只会把 `po` 变成挂死
- remangler 的 `hashForNode` / `deepEquals` / `getUnspecialized`（pending-rebuild 迭代，`nil` 恢复单一含义）
- `NodeStore.materializeNode`、`NodeReference.structurallyEquals` / `structuralHash`
- `DemanglingNode.isSimpleType` / `needSpaceBeforeType`（`.type` 链解包，带步数上限防自引用环）

### 六、`Node` 迭代式析构（保留）

释放引用类型的树本身就是递归——由运行时执行，发生在最后一个引用消失的地方，**任何引擎侧护栏都覆盖不到**，崩溃时栈顶没有本库的帧，几乎必然被误判。实测 512KB 线程上 620 层就崩。`deinit` 把孩子摘进显式工作队列逐个排空，只拆解唯一引用的节点。

### 七、打印入口收拢

`DemanglingPrinter.printRoot` / `NodePrinter.printRoot` 不再公开；唯一公开入口是静态 `print(_:using:)`（`NodePrinter<Target>.print` / SPI 的 `DemanglingPrinter.print`），内部统一过 `StackSafeExecutor`。之前实例级 `printRoot` 是公开的，富文本消费方直驱它就绕开了大栈切换，同一棵树的截断点取决于调用者当时用掉多少栈。下游（MachOSwiftSection）已迁移。

## 曾经的方案与撤回原因

首版（2026-07-28）用 `StackBudget` 按**剩余栈字节**做每层探针，并把「不足 64MB 一律跳 worker」作为门槛，worker 栈 64MB。深度能力确实好（3000 层完整打印），但 review 确认了五条不可接受的代价，且它们是这个形态的固有属性而非实现瑕疵：

1. **LLDB `po` 挂死**——64MB 门槛让主线程也无条件跳线程，而 LLDB 表达式求值默认只放行当前线程，worker 永远调度不到；
2. **优先级反转**——USER_INTERACTIVE 的主线程在 `DispatchSemaphore` 上等 USER_INITIATED worker，信号量不传递优先级；
3. **`TypeBuilder` 回调换线程**——同步外观下把用户代码移到后台；
4. **栈上限不约束工作量**——移除 remangler 深度上限后，构造符号的拒绝代价变成 Θ(D_max·N)（9.5 分钟 CPU 换一个 `.tooComplex`），而 demangle 同一输入只要 1 毫秒；
5. **数十条 64MB 栈常驻**（10 核机上限 40 条 = 2.5GB 地址空间；watchOS arm64_32 全进程只有 4GB）。

结论：**丢机制、留数字**。每层探针、`StackBudget` 类型、64MB 门槛全部移除；它测出的帧大小数据（debug 下 printer 每层约 11.6KB、TypeDecoder 每深度单位约 30KB、512KB 栈上 deinit 约 620 层崩）成为新常数的校准依据。首版顺带做出的正确修复（迭代化、池化、析构、复用重置）全部保留。

## 数据

**校准探测**（debug、8MB 线程、嵌套 `Optional`）：见上表。

**语料**：dyld 共享缓存全量 **4,522,325 个真实符号**（release），demangle 失败 0、node tree 不一致 0、remangle 不一致 0——新常数没有伤到任何真实符号。

**线程池收益**（release、512KB 线程，池化 vs 每次建线程）：`demangleAsNode` 46.73 → 12.48 µs（−73%）、`print` 43.10 → 8.49 µs（−80%）、`mangleAsString` 53.89 → 17.73 µs（−67%）。`withLargeStack` 批次内往返为零。

## 影响面

- **`NodePrinter<Target>` 变为纯静态入口**：`print(_:using:)` + `maxPrintDepth`；实例构造与 `printRoot` 不再公开（#12 的修复，下游已迁移）。
- **深度上限下调**（768→512、1024→384、1024→160）：debug 下从「先崩」变成「先拒」；release 下拒绝点比上游早，但仍在任何真实符号的 2 倍以上。
- **`TypeDecoder` 回调线程契约恢复为调用者线程**。
- **`Node.description` 不再跳线程**（调试器安全）。
- **主线程 / 大栈线程上的调用零往返**（恢复 main 行为）。
- 非 Darwin 平台无变化：没有执行器，深度上限单独生效。

## 迁移注意事项

- 富文本消费方：`var printer = NodePrinter<T>(...); printer.printRoot(node)` → `NodePrinter<T>.print(node, using: options)`。
- 批量场景包 `StackSafeExecutor.withLargeStack {}`；自建线程直接把 `stackSize` 设为 8MB 以上，执行器判定栈足够会全程内联。
- 依赖「1000 层也能完整打印」的调用方（如果存在）：现在统一在校准过的深度拒绝，这是有意的取舍。

## 未解决 / 有意保留

- **`Demangler` 的 `setParentForOpaqueReturnTypeNodesImpl` / `demangleBoundGenericArgs` 仍是无保护递归**——与上游一致（上游解析器同样无深度限制），主循环迭代、这两处现实深度浅。失败模式是崩溃而非报错；要抬高预期深度得先加保护。
- **`demangleSwift3*` 未移植上游 `OldDemangler` 的 `MaxDepth = 1024`**——`_T` 前缀基本绝迹，已决定不管（2026-07-29）。
- **2MB 门槛不是「下面一定有 8MB」的保证**——一个已经吃掉 6MB 栈的调用者仍会内联跑，debug 下深符号可能崩。与 main、与上游 runtime 的暴露面相同；clang 的 256KB 门槛同理。若未来要绝对保证，把门槛提到「剩余 ≥ 上限所需」即可（一个常数的改动）。
