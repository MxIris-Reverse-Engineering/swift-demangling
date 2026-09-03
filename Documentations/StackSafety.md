# 栈安全：与上游同构的「8MB 大栈 + 固定深度上限」模型

日期：2026-07-29（首版 2026-07-28 采用按剩余栈字节的 `StackBudget` 方案，后按 review
结论撤回，见「曾经的方案与撤回原因」；2026-08-02 三个深度上限回退为上游值；2026-09-03
加第八节「任务执行器」）

对应提案：`Evolutions/0002-stack-safety.md`；第八节对应 `Evolutions/0014-large-stack-task-executor.md`
概念背景：[Concepts/RecursionAndStack.md](Concepts/RecursionAndStack.md)（栈为什么会爆、线程栈
大小、trap 与 SIGSEGV 的区别）。词条速查见 [Glossary.md](Glossary.md)。

## 一句话结论

三个递归引擎（printer、remangler、TypeDecoder）各带一个固定深度上限，取值**与上游
Swift 编译器相同**；`StackSafeExecutor` 在调用线程剩余栈不足 2 MB 时，把工作搬到一条
8 MB 栈的常驻 worker 上；所有不经过引擎入口的整树遍历（interning、`copy`、`Rewriter`、
析构、remangler 的替换哈希等）一律改成**迭代**，不依赖任何护栏。

这与 Swift 上游的模型同构。但有一个**尚未解决**的缺口：debug 构建下栈帧大一个数量级，
深度上限来不及生效栈就先崩了（见 `KnownIssues.md` 第 4 条）。async 管线包不进同步的
`withLargeStack`，为它们另有一个 16 MB 线程的 `TaskExecutor`（`StackSafeExecutor.taskExecutor`，
第八节）：任务整体住在大栈上，任务内每次调用探针直接通过；那条路径上打印器与 remangler
的缺口已关。

## 动机

两个症状，同一个根因。

**症状一：debug 构建下固定深度上限够不着，先崩。** 上游三个常数（`NodePrinter` 768、
`Remangler` 1024、`TypeDecoder` 1024）是按 release 帧大小校准的。本库会被消费方以
debug 配置编译，而 debug 的帧大一个数量级。实测（8MB 线程、嵌套 `Optional`）：

- printer：725 层存活、745 层 SIGBUS——**768 的上限永远轮不到生效**；
- remangler：上限之外还有个洞（见下），150 层就崩；
- TypeDecoder：约 125 层崩，1024 的上限纯属装饰。

**症状二：remangler 的上限有结构性绕过。** `hashForNode` ↔ `entryForNode` 是一对互
递归，第一次 `trySubstitution` 时就把整棵子树走完，全程不经过 `mangle(_:depth:)`——
depth 计数器根本没机会涨。上游 C++ 有完全相同的洞，靠「调用方保证在大栈上」活着。

## 上游怎么做的（实证）

`swift/lib/Demangling/` **没有任何栈相关代码**，只有固定深度常数。它的运行环境靠调用方
安排：

- **IRGen worker 线程**（`IRGen.cpp`）：`pthread_attr_setstacksize(8MB)`，注释原话
  "Increase the thread stack size on macosx to 8MB (default is 512KB). This matches the
  main thread."
- **ModuleInterfaceBuilder**（`ModuleInterfaceBuilder.cpp`）：`ThreadStackSize = 8 << 20`，
  子编译跑在 `RunSafelyOnThread(..., 8MB)` 上。
- **运行时**（`stdlib/public/runtime`）：demangle / remangle / TypeDecoder 直接跑在调用者
  线程上，零栈检测——赌注是 runtime 永远 release 构建、帧足够小，深度常数真能够到。
- **clang 的同款先例**（`clang/lib/Basic/Stack.cpp`）：`DesiredStackSize = 8MB`，
  `isStackNearlyExhausted()` 判「距栈底剩余 < 256KB」，快耗尽时换到新 8MB 栈继续——
  「探测剩余栈 + 不够就换 8MB 栈」在 LLVM 生态有正统出处。
- **解析器为什么不用限**：新版 mangling 是后缀文法，`Demangler` 主循环靠 `NodeStack`
  迭代，天生不深递归。旧版 Swift3（`OldDemangler.cpp`）是递归下降，上游给它配了
  `MaxDepth = 1024`（本库的 `demangleSwift3*` 未移植该计数，`_T` 前缀符号基本绝迹，
  已决定不管）。

本库与上游环境唯一的本质差别：**会被人用 debug 配置编译**。

## 方案

### 一、深度上限：维持上游值

现行常数（`swift::Demangle` 同名常数的取值）：

| 引擎 | 常数 | 现行值 |
|---|---|---|
| `DemanglingPrinter.maxPrintDepth` | `NodePrinter::MaxDepth` | **768** |
| `Remangler.maxDepth` | `Remangler::MaxDepth` | **1024** |
| `TypeDecoderEngine.maxDepth` | `TypeDecoder::MaxDepth` | **1024** |

> **2026-08-02：这三个值曾按 debug 实测下调，现已全部回退。**
> 下调（printer 512、remangler 384、TypeDecoder 160）依据的是「实测过的最深真实符号是
> 41 层」这一语料结论，而下游消费方报告：普通的 SwiftUI 及同类泛型密集模块在 512 的
> 打印上限下会输出 `<<too complex>>`。也就是说该语料结论不成立，下调不是「削掉理论
> 能力」，而是在截断本该正确的输出。前提被证伪后，同批同论证的另外两个常数一并回退。
> 详见 `KnownIssues.md` 第二部分 N8。
>
> **不要在没有下游语料证据的情况下再次下调任何一个上限。** 三处常量的注释里都写了
> 这句话。

下方的崩溃边界实测（8MB 线程、debug 构建、嵌套 `Optional` 符号逐深度探测）仍然有效，
它现在是**尚未解决的栈安全问题**的依据（`KnownIssues.md` 第 4 条）：

| 引擎 | 现行上限 | 实测崩溃边界（debug、8MB 线程） | 曾短暂下调至 |
|---|---|---|---|
| `DemanglingPrinter.maxPrintDepth` | 768 | 725 层过 / 745 层崩（每层约 11.6 KB） | ~~512~~（已回退） |
| `Remangler.maxDepth` | 1024 | 深度 565 过 / 605 崩（140/150 层，每层 4 个深度单位） | ~~384~~（已回退） |
| `TypeDecoderEngine.maxDepth` | 1024 | 深度约 250 崩（120/130 层，每深度单位约 30 KB！） | ~~160~~（已回退） |

**教训**：常数校准建立在一次语料扫描给出的「最深 41 层」上，而那次扫描的覆盖面不足以
代表下游真实负载。

### 二、`hashForNode` 改迭代，让 remangler 的上限第一次真正生效

互递归改成显式栈后序折叠，缓存语义逐条保持。这不是「新增保护」，而是**修补 main 上
已有保护的绕过**——改完之后 `maxDepth` 才是真实的上限，上表中 remangler 的边界也才
有意义。它同时消灭了一个 DoS：没有深度上限时，靠栈耗尽拒绝一个 3.2 万层的构造符号要
烧约 9.5 分钟 CPU（每层都重走整棵子树，Θ(D_max·N)）；深度检查 0.1 秒内拒绝。

### 三、执行器：2MB 门槛 + 8MB 常驻池

- **门槛 2MB**（`minimumRemainingStackSize`）：剩余栈 ≥ 2MB 就地跑（clang 的对应值是
  256KB，我们保守 8 倍）。主线程、消费方自建的大栈线程零开销、LLDB `po` 可用；512KB
  的协作 / dispatch 线程跳到 worker。
- **worker 栈 8MB**（`largeStackThreadSize`）：与主线程、与上游一致。深度常数按它校准。
- **池化保留**（对 node store 批量场景是刚需：每次新建线程约 41µs，23 万符号就是约
  10 秒纯开销）。稳态上限 `max(2, 核数)`，阻塞式提交可撑到 `max(32, 4×)`（扇出防互锁），
  异步提交守稳态上限。
- **`pthread_create` 而非 `Thread.start()`**，创建失败有返回码可查——`start()` 静默
  失败会永久毒化进程级单例。
- **幽灵预约不再挂死任何人**：并发提交、创建全部失败时，最后一个回滚到零的提交者
  **就地排空队列**再拒绝，且入队时复验存活 worker 数。之前的写法里，先回滚的提交者会
  把别人的幽灵预约当成存活 worker，入队后永久阻塞（测试可复现：8 个并发提交者 7 个
  挂死）。
- **worker 上的嵌套调用**：栈还多（≥2MB）就内联跑（嵌套 demangle 的常态）；真的深到
  不足 2MB 时起一条一次性 8MB 线程，绝不向自己所在的池子回提交（那个等待可能排在它
  自己正在执行的条目后面）。
- **worker 按 QoS 类分池，提交只触及自己的类**（2026-09-02；前身是 2026-08 的「每跳
  重排 QoS、空闲 worker 停在 background」，起因是 Thread Performance Checker 在 worker
  的 `condition.wait()` 处报优先级反转）：跳线程涉及的两个等待都无法继承优先级——提交者
  阻塞的 semaphore 不传递优先级，worker 停车的条件变量原理上不可能知道未来谁来
  signal——所以只能在构造上保证排序正确。现行做法：worker 在被某个提交者创建时就取该
  提交者的 QoS 类（`qos_class_self()`，`UNSPECIFIED` 折算为 user-initiated），**终身不改**；
  每个类各有一个子池（队列、空闲计数、稳态 / 突发上限都按类），提交只会 signal 或创建
  同类的 worker。于是高 QoS 调用者绝不等在低优先级线程上，停车的 worker 也绝不被比它低
  的线程唤醒——两条性质与前身相同，但热路径上零 QoS 系统调用。
  前身之所以要换：它让每次出队 `pthread_set_qos_class_self_np` 到条目的类、停车前降到
  background，结果**每一跳唤醒的都是一条 background 线程**（能效核调度 + 节流）外加两次
  QoS 系统调用；demangle / print / remangle 每次调用就是一跳，下游索引一个框架要跳几十万次，
  实测 MachOSwiftSection 的 SwiftUICore 普通 dump 从 50 s 变成 150–210 s、带布局注释的 dump
  从 80 s 变成 320–430 s（swift-demangling 0.6.0 → 0.6.1，其它依赖不变）。代价是进程真正
  用到几个类就有几个子池（最多五个），每个子池的上限与原单池相同。**上限故意按类、不做跨类
  全局预算**：worker 永不退休，全局预算会让某个类的空闲 worker 永久占着别的类需要的名额，
  等价于从侧门打穿「never retire」那条性质。最坏情形（五个类同时突发）：5 × `max(32, 4 × 核数)`
  条 worker，每条 8MB 未触碰的地址空间——32 位 watchOS 进程（4GB 地址空间）上是 1.28GB，
  但要**每个类**都有 32 个调用者同时阻塞才能到；稳态双核手表是 5 × 2 = 10 条、80MB 预留。
  本构建不认识的 QoS 类（未来 OS 新增）**拒绝入池而不是归到某个已知类**：第一版把它折进
  user-initiated，等于把未知等级的活抬高五级、又让 user-initiated 的停车 worker 被更低的线程
  唤醒；现在拒绝后调用方走一次性线程，那条路也不抬高（`pthread_attr_set_qos_class_np` 对
  未知值返回 EINVAL，线程停在 `pthread_create` 的默认类）。一次性 fallback 线程的创建 QoS
  取自提交者线程；线程创建崩溃时的就地排空路径跑在提交者线程上，按构造就是该子池的类。
  worker 线程名带类后缀（`swift-demangling.large-stack-worker.user-initiated`），spindump 里
  能看出哪个类的池涨了、活有没有落错池。回归测试：
  `workRunsAtTheSubmittersQualityOfServiceClass`（条目在提交者的类上运行）、
  `idleWorkerKeepsItsClassInsteadOfParkingAtBackground`（停车不降级；前身第一个采样就是
  background）、`submissionsOfDifferentClassesRunOnWorkersOfTheirOwnClass`（分池本身；前身
  两个类共用同一条 worker）、`unknownQualityOfServiceClassIsRefusedRatherThanPromoted`
  （未知类拒绝；合成注入的前向兼容守卫，公开 API 造不出这种线程）。
- **`withLargeStack {}`** 保留：批量场景包一次，作用域内全部内联，零往返。
- **`async` 变体**：`demangleAsNode` / `mangleAsString` / `print(using:)` 都有 `async`
  重载，走 `executeAsync`——需要换线程时**挂起**当前 task 而不是阻塞一条协作线程池的
  worker。

### 四、`TypeDecoder` 不跳线程（撤回首版的包装）

`TypeDecoder` 调的是**用户代码**（`TypeBuilder` 回调）。首版把整段搬到 worker 后，
`@MainActor` 隔离或线程绑定的 builder 会在一个看起来同步的调用背后被移到后台线程。
现在回到 main 的契约：**回调永远在调用者线程**，栈是调用者的责任，深批量自己包
`withLargeStack`。

> 注意这一条与「一」的回退叠加后留下了一个真实缺口：`maxDepth` 已回到 1024，而
> TypeDecoder 在 debug 下每深度单位约 30 KB，8MB 线程实测约 250 层就崩——**上限不再
> 能保证「先拒绝、后崩溃」**。这是 `KnownIssues.md` 第 2 条与第 4 条的交集。

### 五、引擎之外的整树遍历：迭代（全部保留）

这些不经过任何引擎入口，护栏永远覆盖不到，迭代是唯一正确形态：

- `NodeCache.internTreeUnsafe`（每次默认 demangle 都跑）、`NodeStoreBuilder.internTree`
- `Node.==` / `Node.hash(into:)`
- `Node.copy()` / `replacingDescendant(_:with:)`（`NodeBuilder` 持锁期间调用）
- `Node.Rewriter.rewrite`（`rewrite` 是 `final`，只有 `visit` 是 `open`，迭代化不改变
  任何可重写点）
- `Node.description` 的树转储——**并且不包 `StackSafeExecutor`**：迭代遍历不可能爆栈，
  而它恰是调试器 `po` 走的路，包一层只会把 `po` 变成挂死
- remangler 的 `hashForNode` / `deepEquals` / `getUnspecialized`
- `NodeStore.materializeNode`、`NodeReference.structurallyEquals` / `structuralHash`
- `.type` 链的解包判定：`DemanglingNode.isSimpleType` / `needSpaceBeforeType` 与
  `Node.isProtocol`——三者共用步数上限 `maxTypeWrapperUnwrapDepth = 64`，超限返回
  保守的 `false`。真实 demangle 输出走不到这个上限（全语料最长连续 `.type` 只有 1 层），
  它挡的是调用方手工拼装的树

**另有一层与栈无关但同源的保护**：上面几条里凡是「按节点重建或输出」的遍历，还都带了
按实例身份的 memo，否则在 DAG 上按路径计价会指数爆炸。详见 `SubtreeInterning.md` 文末
与 evolution 0005 / 0006 / 0007。

### 六、`Node` 迭代式析构（保留）

释放引用类型的树本身就是递归——由运行时执行，发生在最后一个引用消失的地方，**任何
引擎侧护栏都覆盖不到**，崩溃时栈顶没有本库的帧，几乎必然被误判。实测 512KB 线程上
620 层就崩。`deinit` 把 children 摘进显式工作队列逐个排空，只拆解唯一引用的节点。

### 七、打印入口收拢

`DemanglingPrinter.printRoot` / `NodePrinter.printRoot` 不再公开；唯一公开入口是静态
`print(_:using:)`（`NodePrinter<Target>.print` / SPI 的 `DemanglingPrinter.print`）
以及 `DemanglingNode.print(using:)` 便捷方法，内部统一过 `StackSafeExecutor`。之前
实例级 `printRoot` 是公开的，富文本消费方直驱它就绕开了大栈切换，同一棵树的截断点
取决于调用者当时用掉多少栈。下游（MachOSwiftSection）已迁移。

### 八、任务执行器：让整个 task 住在 16MB 线程上（2026-09-03，提案 0014）

- **问题**：探针按调用线程的剩余栈判断，协作线程的 512KB 永远不过；async 打印循环包不进同步的
  `withLargeStack`，于是每次 print 付一次线程往返（下游 MachOSwiftSection 实测 release 下 8–21 µs）。
- **做法**：`LargeStackTaskExecutor`（`@_spi(Internals)`，经 `StackSafeExecutor.taskExecutor` 取用，
  macOS 15 / iOS 18 / tvOS 18 / watchOS 11 / visionOS 2 起）是一个 `TaskExecutor`，线程 16MB。
  `withTaskExecutorPreference(StackSafeExecutor.taskExecutor) { … }` 里的任务、子任务与默认 actor 全在
  这些线程上跑，任务内每个入口的探针直接通过、原地执行——`withLargeStack` 的效果扩展到整个 task，
  同步被调方一并受益。非结构化 `Task {}` 不继承偏好（SE-0417）。
- **分池共码**：执行器持有自己的一个 `LargeStackThreadPool` 实例（`init(stackSize:workerThreadNamePrefix:)`，
  线程名 `swift-demangling.task-executor.<qos>`），与 `shared` 不共享 worker，其余全部复用（建线程、
  QoS 分区、排队、失败排空）。理由：跳转条目毫秒级、提交者阻塞等待；执行器的 job 是整段 task，一次
  `printRoot` 可占线程上百秒——几个长 job 就把同类的稳态额度吃光，同步跳转被挤进突发额度乃至每次新建
  临时线程，而跳转是下游索引一个框架要走几十万次的路径。
- **QoS**：job 的类就是它的 priority——`JobPriority` 的原始值与 Darwin QoS 类数值相同（运行时的全局
  执行器 `DispatchGlobalExecutor.cpp` 直接强转后交给 `dispatch_get_global_queue`），`unspecified`（0）归
  default（dispatch 对 `QOS_CLASS_UNSPECIFIED` 的处理），未知值池子照旧拒绝而不抬升。分区规则不变：
  worker 建在 job 的类上、终身不改，零 QoS 系统调用。
- **额度**：提交用稳态额度（`max(2, 核数)`），不用突发额度——突发额度是给互相等待的阻塞提交者破环
  用的，enqueue 一方从不阻塞。每类宽度等于协作线程池。最坏五个类各 `max(2, 核数)` 条 16MB 线程的
  地址预留（双核手表 5 × 2 × 16MB = 160MB）。
- **回退**：池拒绝（建不出线程）→ 一次性 16MB 专用线程（按 **job 的类**创建，不是 enqueue 线程的类：
  enqueue 的线程是恢复这个 job 的任意线程）→ `DispatchQueue.global(qos:)`（job 照跑、探针照跳）。
  `enqueue` 绝不就地跑 job——它在运行时的调度路径里被调用，就地跑会递归回去。
- **16MB 关掉了什么**（2026-09-03 实测，debug，arm64，嵌套 `Optional` 形状：打印器每层 2 个深度单位、
  remangler 4 个）：8MB 线程上打印器 380 层（≈760 单位）、remangler 200 层（≈800 单位）都先于计数器
  SIGBUS——这正是 `KnownIssues.md` #4 的窗口；16MB 上 380 层完整打印、383 层起 `<<too complex>>`，
  remangler 240 层往返、260 层起 `.tooComplex`，1000 层两者都干净退化。因此 #4 的两个窗口在**执行器
  路径**上对打印器与 remangler 关闭；TypeDecoder（每单位约 30KB，1024 单位需约 30MB，且它本就不经
  执行器）在执行器上仍会先爆栈；阻塞跳转池 8MB 照旧登记。#4 当年从 `StackSafetyTests` 移除的「超限
  退化而非崩溃」断言在执行器路径上恢复（`printingOnTheExecutorDegradesPastTheDepthLimitInsteadOfCrashing`、
  `remanglingOnTheExecutorDegradesPastTheDepthLimitInsteadOfCrashing`）。
- **有意保留的限制**：不是 `SerialExecutor`，actor 不能隔离到它；job 阻塞线程等同类的另一个 job 会耗尽
  该类 worker（与协作线程池同一契约）；enqueue 线程可能低于 job 的类，停车的 worker 因而可能被更低的
  线程 signal——Thread Performance Checker 可能报，但没有人等在那条 worker 上，且这是任何「job 由任意
  线程恢复」的执行器都有的形状；优先级提升（escalation）不处理，job 已在某类线程上就不再改类。
- **回归测试**：`LargeStackTaskExecutorTests`——`callsInsideATaskOnTheExecutorRunInline`（执行器上
  `execute` / `executeAsync` 都不跳）、`executorThreadsCarryTheExecutorStackAndName`、
  `aJobRunsAtTheClassOfItsPriority`（四个优先级各落各的类）、
  `priorityMapsToTheQualityOfServiceClassOfTheSameRawValue`（含 unspecified → default、未知值被拒）、
  `jobsOnTheExecutorDoNotOccupyTheHopPool`（占满执行器某类全部稳态 worker，同类同步跳转仍落在 8MB
  跳转池 worker 上、跳转池不增长——分池与共池的判别性断言）、
  `aJobThePoolCannotTakeStillRunsOnALargeStackThread`（池建不出线程时 job 落在 16MB 专用线程）、
  以及上面四条深度测试。

## 曾经的方案与撤回原因

首版（2026-07-28）用 `StackBudget` 按**剩余栈字节**做每层探针，并把「不足 64MB 一律
跳 worker」作为门槛，worker 栈 64MB。深度能力确实好（3000 层完整打印），但 review 确认
了五条不可接受的代价，且它们是这个形态的固有属性而非实现瑕疵：

1. **LLDB `po` 挂死**——64MB 门槛让主线程也无条件跳线程，而 LLDB 表达式求值默认只放行
   当前线程，worker 永远调度不到；
2. **优先级反转**——USER_INTERACTIVE 的主线程在 `DispatchSemaphore` 上等
   USER_INITIATED worker，信号量不传递优先级；
3. **`TypeBuilder` 回调换线程**——同步外观下把用户代码移到后台；
4. **栈上限不约束工作量**——移除 remangler 深度上限后，构造符号的拒绝代价变成
   Θ(D_max·N)（9.5 分钟 CPU 换一个 `.tooComplex`），而 demangle 同一输入只要 1 毫秒；
5. **数十条 64MB 栈常驻**（10 核机上限 40 条 = 2.5GB 地址空间；watchOS arm64_32 全进程
   只有 4GB）。

结论：**丢机制、留数字**。每层探针、`StackBudget` 类型、64MB 门槛全部移除；它测出的
帧大小数据（debug 下 printer 每层约 11.6KB、TypeDecoder 每深度单位约 30KB、512KB 栈上
deinit 约 620 层崩）成为常数校准的依据。首版顺带做出的正确修复（迭代化、池化、析构、
复用重置）全部保留。

## 数据

**校准探测**（debug、8MB 线程、嵌套 `Optional`）：见上表。

**语料**：dyld 共享缓存全量 **4,522,325 个真实符号**（release），demangle 失败 0、
node tree 不一致 0、remangle 不一致 0。

**线程池收益**（release、512KB 线程，池化 vs 每次建线程）：`demangleAsNode`
46.73 → 12.48 µs（−73%）、`print` 43.10 → 8.49 µs（−80%）、`mangleAsString`
53.89 → 17.73 µs（−67%）。`withLargeStack` 批次内往返为零。

## 影响面

- **`NodePrinter<Target>` 变为纯静态入口**：`print(_:using:)` + `maxPrintDepth`；
  实例构造与 `printRoot` 均已收为 internal，下游已迁移。
- **深度上限维持上游值**（768 / 1024 / 1024）：曾下调至 512 / 384 / 160，因下游在 512 下
  实测 `<<too complex>>` 而全部回退（`KnownIssues.md` N8）。debug 构建下「先崩后拒」的
  风险因此仍在，作为独立的栈安全问题追踪（`KnownIssues.md` 第 4 条）。
- **`TypeDecoder` 回调线程契约恢复为调用者线程**。
- **`Node.description` 不跳线程**（调试器安全）。
- **主线程 / 大栈线程上的调用零往返**。
- **三个入口都有 `async` 变体**：换线程时挂起 task，而不是阻塞协作线程池的 worker。
- 非 Darwin 平台无变化：没有执行器，深度上限单独生效。

## 迁移注意事项

- 富文本消费方：`var printer = NodePrinter<T>(...); printer.printRoot(node)` →
  `NodePrinter<T>.print(node, using: options)`。
- 批量场景包 `StackSafeExecutor.withLargeStack {}`；自建线程直接把 `stackSize` 设为
  8MB 以上，执行器判定栈足够会全程内联。
- Swift 并发环境下优先用 `async` 重载，避免阻塞协作线程池的 worker。

## 未解决 / 有意保留

- **debug 构建下深度上限来不及生效**（`KnownIssues.md` 第 4 条）：768 层打印最坏约需
  8.9 MB 栈，超过 worker 本身的 8 MB。这是回退上限如实付出的代价，要当作栈安全问题
  解决（提高探针阈值、或按实际剩余栈折算本次生效的上限），不能靠静默截断 release
  构建能正常渲染的输出来换。2026-09-03 起**执行器路径**上打印器与 remangler 的窗口已关
  （第八节，16MB 线程）；阻塞跳转池路径与 TypeDecoder 仍开着。
- **`Demangler` 的 `setParentForOpaqueReturnTypeNodesImpl` / `demangleBoundGenericArgs`
  仍是无保护递归**——与上游一致（上游解析器同样无深度限制），主循环迭代、这两处现实
  深度浅。失败模式是崩溃而非报错；要抬高预期深度得先加保护。
- **`demangleSwift3*` 未移植上游 `OldDemangler` 的 `MaxDepth = 1024`**——`_T` 前缀基本
  绝迹，已决定不管（2026-07-29）。
- **2MB 门槛不是「下面一定有 8MB」的保证**——一个已经吃掉 6MB 栈的调用者仍会内联跑，
  debug 下深符号可能崩。与 main、与上游 runtime 的暴露面相同；clang 的 256KB 门槛同理。
  若未来要绝对保证，把门槛提到「剩余 ≥ 上限所需」即可（一个常数的改动）。
