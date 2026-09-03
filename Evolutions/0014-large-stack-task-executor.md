# 0014 - 大栈 TaskExecutor：让 Swift Concurrency 任务整体跑在大栈线程上

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-09-03
- **最后更新**: 2026-09-03
- **所属愿景**: `Evolutions/README.md` 愿景第 3 条（计价纪律与健壮性：深符号在 512 KB 协作线程栈上爆栈是真实事故形态）与第 4 条（API 演进：实验期 API 圈在 `@_spi(Internals)`，OS 版本用 `#available` 双路径）
- **关联提案**: [0002](0002-stack-safety.md)（`StackSafeExecutor` 与 8 MB 大栈的由来）、[0013](0013-punycode-upstream-parity-and-review-round-four-fixes.md)（`StackSafeExecutor` 的 QoS 分池是 0.6.2 的内容，本提案在其上加一组执行器线程）；下游 MachOSwiftSection 提案 `draft-large-stack-executor-and-cross-version-parallelism`（接入方）
- **实现分支 / PR**: `next`，与本提案同批次提交；目标版本 0.6.3（合入 `main` 后打 tag——仓库没有 CHANGELOG 文件，发版就是 tag）
- **配套文档**: `Documentations/StackSafety.md` 第八节「任务执行器」；`KnownIssues.md` #4 已更新；`README.md`「Deep Generic Nesting and Thread Stacks」一节；`AGENTS.md` 栈安全段

## 摘要

`StackSafeExecutor` 的每个入口都按调用线程的剩余栈空间探测，不足 2 MB 就把工作挪到 8 MB 池线程并阻塞等待。下游 MachOSwiftSection 的打印管线是 async 的，跑在 512 KB 的协作线程上，探测永远不通过：每次 `print` 都付一次线程往返（release 下 8–21 µs），而 async 循环又包不进同步的 `withLargeStack`。本提案新增一个 `TaskExecutor`：一组 16 MB 栈的线程，Swift Concurrency 任务用 `withTaskExecutorPreference` 整体跑在上面，此后任务内的每次 demangle / print / remangle 探测直接通过、原地执行，同步被调方一并受益。执行器与现有阻塞式跳转池**分池共码**（各自一组线程，复用建线程、QoS 分区与排队代码），以 `@_spi(Internals)` 暴露，`@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2)`。job 的 QoS 类就是它的 priority（`JobPriority` 原始值与 Darwin QoS 类数值相同），提交只用稳态额度，池拒绝时回退到一次性 16 MB 线程、再到全局 dispatch 队列。

## 动机

### 1. 探测机制天然支持「让整个任务住在大栈上」，缺的只是一个执行器

`currentThreadHasSufficientStack`（`Sources/Demangling/Utils/StackSafeExecutor.swift`）用 `pthread_get_stackaddr_np` / `pthread_get_stacksize_np` 算剩余栈，与线程身份无关。`execute` 与 `executeAsync` 都先探测再决定是否提交。只要任务跑在一条大栈线程上，所有入口都走内联分支，`withLargeStack` 想做的「一次跳转、整批内联」就自动成立——而且覆盖的是整个任务，不只是一个同步循环。

### 2. 下游的 async 打印路径今天付不起、也包不住

MachOSwiftSection 的实测（其 `Documentations/Internal/Reviews/2026-07-31-node-store-migration-review.md`）：协作线程上每次打印固定多付 8.2 µs（小树，2.28×）到 20.8 µs（916 字符真实符号，1.14×）；其索引扫描已用 `withLargeStack` 包整批（10 万符号 1317 → 701 ms），打印循环是 async，同步的 `withLargeStack` 无法包裹。该仓库的评审记录写着两条出路：「自定义一个跑在 8 MB 线程上的 `SerialExecutor`，或把打印批次改成同步」。前者就是本提案；后者要砍它的 async API。

### 3. 已登记问题 #4 的一部分可以顺手关掉

`KnownIssues.md` #4：打印器 768 层上限所需的栈超过 8 MB worker，debug 构建下有两个窗口会 SIGSEGV 而不是返回 `<<too complex>>`。执行器线程开 16 MB，跑在执行器上的路径不再有这两个窗口（打印器与 remangler，实测见下）；阻塞式跳转池保持 8 MB，问题在那条路径上照旧登记。

## 前期调研

- **SE-0417 Task Executor Preference**（Swift 6.0 实现；运行时 macOS 15 / iOS 18 / tvOS 18 / watchOS 11 / visionOS 2，已对照 macOS 26 SDK 的 `_Concurrency.swiftinterface` 核实）：`withTaskExecutorPreference(_:isolation:operation:)`、`Task(executorPreference:priority:operation:)`；偏好被子任务与默认 actor 继承，不被非结构化 `Task {}` 继承；`nonisolated async` 函数在有偏好时跑在偏好的执行器上。`TaskExecutor` 协议只要求 `enqueue(_ job: consuming ExecutorJob)`，`asUnownedTaskExecutor()` 有默认实现；worker 用 `UnownedJob.runSynchronously(on: UnownedTaskExecutor)` 执行。
- **`JobPriority` 的原始值就是 Darwin 的 QoS 类数值**：运行时的全局执行器（`stdlib/public/Concurrency/DispatchGlobalExecutor.cpp`，`getGlobalQueue`）把 job 的 priority 直接强转成 `dispatch_qos_class_t` 交给 `dispatch_get_global_queue`。`TaskPriority.userInteractive = 0x21`、`.userInitiated`/`.high = 0x19`、`.medium = 0x15`、`.utility`/`.low = 0x11`、`.background = 0x09`、`unspecified = 0`；其中 `userInteractive` 与 `unspecified` 两个常量已标记废弃，所以按 `TaskPriority` 的具名 case 写 switch 拼不出 user-interactive。
- **现有池的形态**（`StackSafeExecutor.swift`）：`LargeStackThreadPool.shared` 按五个 QoS 类各一个子池；worker 用 `pthread_create` + `pthread_attr_setstacksize(8 MB)` + detached 建，永不退休，`NSCondition` 停车；稳态上限 `max(2, activeProcessorCount)`、突发上限 `max(32, 4 × 稳态)`，异步提交不许用突发额度；`pthread_key` 标记「我是池 worker」。常量 `minimumRemainingStackSize = 2 MB`、`largeStackThreadSize = 8 MB`。**`trySubmit` 已有显式 QoS 类参数的重载**（`trySubmit(allowingOverflow:submitterQualityOfService:_:)`，0.6.2 为测试加的），执行器直接用，草稿里「新增显式参数」一项不需要。
- **两类任务的寿命完全不同**：跳转任务是一次 demangle / print，毫秒级；执行器任务是一次 `printRoot` 或 `prepare()`，可能占住线程上百秒。混在一个稳态额度里，几个长任务就能把同步跳转挤到突发额度甚至每次新建临时线程。这是分池的理由。
- **栈耗实测**（2026-09-03，debug，arm64，嵌套 `Optional` 形状 `$sSi` + `Sg`×n + `D`）：该形状每层占打印器 2 个深度单位、remangler 4 个。8 MB 线程：打印器 380 层（≈760 单位）SIGBUS，remangler 200 层（≈800 单位）SIGBUS，都死在计数器之前——这就是 #4 的窗口。16 MB 执行器线程：打印器 380 层完整输出、383 层起返回 `<<too complex>>`；remangler 240 层往返成功、260 层起抛 `.tooComplex`；1000 层两者都干净退化。TypeDecoder 每单位约 30 KB，1024 单位需约 30 MB，16 MB 关不掉它的窗口。草稿里「768 层 × 11.6 KB ≈ 8.9 MB」的估算与 `StackSafetyTests` 留下的「8 MB 上 300 层过、400 层崩」并不矛盾——前者按深度单位、后者按嵌套层数，一层是两个单位。
- **本包平台下限**：macOS 10.15 / iOS 13（`Package.swift`），执行器需要 `@available` 门控，符合愿景第 4 条的双路径原则。测试目标的部署版本也是 10.15，所以 `swift build` 本身就是门控正确的验证。
- **可见性现状**：`StackSafeExecutor` 是 `@_spi(Internals) public`，`LargeStackThreadPool` 是 internal。
- **下游版本约束**：MachOSwiftSection 钉 0.6.0；0.6.1 的按跳重排 QoS 让其 dump 慢 3–4 倍（已由 0.6.2 的分池修复，下游 2026-09-03 实测恢复）；本提案随 0.6.3 发版。

## 提议方案

1. 新增 `LargeStackTaskExecutor: TaskExecutor`（`Sources/Demangling/Utils/LargeStackTaskExecutor.swift`），`@_spi(Internals) public`，`@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)`，经 `StackSafeExecutor.taskExecutor` 取用。与线程池同在 `#if canImport(Darwin)` 内，非 Darwin 平台没有它。
2. **分池共码**：执行器持有自己的一个 `LargeStackThreadPool` 实例（栈 16 MB，线程名前缀 `swift-demangling.task-executor.`），与 `LargeStackThreadPool.shared`（8 MB，阻塞跳转用）互不共享 worker；`LargeStackThreadPool.init` 新增 `stackSize` 与 `workerThreadNamePrefix` 参数，内部 `QualityOfServiceClassPool` 按参数建线程。
3. `enqueue`：job 的 QoS 类 = `JobPriority` 原始值本身；`unspecified`（0）归 `DEFAULT`（dispatch 对 `QOS_CLASS_UNSPECIFIED` 的处理）；未知值原样交给池，池按既有规则**拒绝而不抬升**，走下一级回退。worker 上 `runSynchronously(on: asUnownedTaskExecutor())`。
4. 提交用 `allowingOverflow: false`（稳态额度 `max(2, 核数)`）：enqueue 的一方从不阻塞，突发额度存在的意义是打破阻塞提交者互等的环，这里没有环可破；每类宽度与协作线程池相同。
5. **回退链**：池拒绝（线程建不出来）→ 一次性 16 MB 专用线程（`spawnDedicatedLargeStackThread` 新增 `stackSize` 与 `qualityOfServiceClass` 参数，按 **job 的类**创建，而不是 enqueue 线程的类——enqueue 的线程是恢复这个 job 的任意线程）→ `DispatchQueue.global(qos:)`（job 照跑，探针照跳）。`enqueue` 绝不就地跑 job：它在运行时的调度路径里被调用，就地跑会递归回去。
6. 执行器 worker 照常打 `isRunningOnPoolWorker` 标记：它属于「池 worker」，`runOnLargeStack` 的路由规则 1 因此对它生效（低栈时走一次性线程而不是回投池；16 MB 下实际不会发生）。`executeAsync` 在执行器线程上若探测不过，提交的是 `shared` 跳转池而非执行器自己的池，没有自锁。
7. `KnownIssues.md` #4 更新为「执行器路径上打印器与 remangler 的窗口已关；TypeDecoder 与阻塞池路径照旧」；`StackSafety.md` 增补「任务执行器」一节；README 与 `AGENTS.md` 同步。

### 非目标

- 不改探测阈值、不改阻塞池的栈大小与额度。
- 不改任何 demangle / print / remangle 入口的签名与语义。
- 不提供 `SerialExecutor`（actor 执行器）形态。
- 不做 macOS 15 以下的替代机制。
- 不转正为 public API。
- 不处理优先级提升（escalation）：job 已在某类的线程上运行后不再改类，与任何自定义执行器相同。

## 详细设计

```swift
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
@_spi(Internals)
public final class LargeStackTaskExecutor: TaskExecutor, Sendable {
    public static let threadStackSize = 16 * 1024 * 1024
    /// One executor per process; its threads are separate from
    /// `LargeStackThreadPool.shared`, which keeps serving the blocking hops.
    public static let shared: LargeStackTaskExecutor
    public func enqueue(_ job: consuming ExecutorJob)
}

extension StackSafeExecutor {
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public static var taskExecutor: LargeStackTaskExecutor { .shared }
}
```

内部：

```swift
final class LargeStackThreadPool: Sendable {
    init(stackSize: Int = StackSafeExecutor.largeStackThreadSize,
         workerThreadNamePrefix: String = LargeStackThreadPool.hopWorkerThreadNamePrefix,
         /* existing testing hooks */)
    static let shared = LargeStackThreadPool()
}

extension LargeStackTaskExecutor {
    public func enqueue(_ job: consuming ExecutorJob) {
        let qualityOfServiceClass = Self.qualityOfServiceClass(for: job.priority)
        let unownedJob = UnownedJob(job)
        let unownedExecutor = asUnownedTaskExecutor()
        let runJob: @Sendable () -> Void = { unownedJob.runSynchronously(on: unownedExecutor) }

        if pool.trySubmit(allowingOverflow: false, submitterQualityOfService: qualityOfServiceClass, runJob) { return }
        if StackSafeExecutor.spawnDedicatedLargeStackThread(stackSize: Self.threadStackSize, qualityOfServiceClass: qualityOfServiceClass, runJob) { return }
        DispatchQueue.global(qos: DispatchQoS.QoSClass(rawValue: qualityOfServiceClass) ?? .default).async(execute: runJob)
    }

    static func qualityOfServiceClass(for priority: JobPriority) -> qos_class_t {
        if priority.rawValue == 0 { return QOS_CLASS_DEFAULT }
        return qos_class_t(rawValue: UInt32(priority.rawValue))
    }
}
```

worker 线程名 `swift-demangling.task-executor.<qos>`（最长 47 字节，低于 `pthread_setname_np` 的 63）。执行器线程上 `LargeStackThreadPool.isRunningOnPoolWorker` 的标记仍然打。

**有意保留的限制**：不是 `SerialExecutor`；job 阻塞线程等同类另一个 job 会耗尽该类 worker（与协作线程池同一契约）；enqueue 线程可能低于 job 的类，停车 worker 因而可能被更低的线程 signal——Thread Performance Checker 可能报告，但没有人等在那条 worker 上，且这是任何「job 由任意线程恢复」的执行器都有的形状。

### 测试

`Tests/DemanglingTests/LargeStackTaskExecutorTests.swift`，每条以 `guard #available(...)` 开头（仓库既有惯例，`@Suite`/`@Test` 宏不接受 `@available`）：

| 测试 | 钉住的性质 |
|---|---|
| `callsInsideATaskOnTheExecutorRunInline` | 执行器上 `execute` 与 `executeAsync` 都在任务自己的线程上跑（以 `pthread_self` 比对）——池子没有「提交次数」钩子，共享池的 worker 计数又被别的 suite 污染，线程身份是唯一干净的断言 |
| `executorThreadsCarryTheExecutorStackAndName` | 线程 ≥ 16 MB、名字带执行器前缀（`pthread_get_stacksize_np` 会多报 12 KB 的守卫页，故用 `>=`，与既有测试一致） |
| `aJobRunsAtTheClassOfItsPriority`（4 个参数化用例） | `.background` / `.utility` / `.medium` / `.userInitiated` 各落各的 QoS 类 |
| `priorityMapsToTheQualityOfServiceClassOfTheSameRawValue` | 映射是原始值恒等（含 0x21 → user-interactive）、unspecified → default、未知值被池拒绝 |
| `jobsOnTheExecutorDoNotOccupyTheHopPool` | 占满执行器 utility 类全部稳态 worker 后，同类的同步跳转仍落在 8 MB 跳转池 worker 上，且跳转池没有为执行器的 job 增长——这是分池而非共池的判别性断言 |
| `aJobThePoolCannotTakeStillRunsOnALargeStackThread` | 私有池模拟建线程失败，job 落在 16 MB 专用线程上、不在 enqueue 线程上 |
| `printingOnTheExecutorSurvivesADepthThatOverflowsAnEightMegabyteThread` | 380 层（8 MB 上 SIGBUS）在执行器上完整打印 |
| `printingOnTheExecutorDegradesPastTheDepthLimitInsteadOfCrashing` | 1000 层返回 `<<too complex>>`——#4 从 `StackSafetyTests` 移除的断言，在执行器路径上恢复 |
| `remanglingOnTheExecutorSurvivesADepthThatOverflowsAnEightMegabyteThread` | 200 层（8 MB 上 SIGBUS）在执行器上往返 |
| `remanglingOnTheExecutorDegradesPastTheDepthLimitInsteadOfCrashing` | 1000 层抛 `.tooComplex`——同上 |

平台下限的编译验证不需要单独的测试：测试目标部署版本就是 macOS 10.15，`swift build` 通过即门控正确。

## 替代方案考量

- **共用 `LargeStackThreadPool.shared` 的 worker**：线程最少，但长任务占满稳态额度后同步跳转退到突发额度乃至每次新建临时线程，2026-09-03 用户选分池。
- **执行器线程也是 8 MB**：与阻塞池一致，但 #4 的两个窗口在执行器路径上原样保留；16 MB 是虚拟地址预留、按需提交物理页，代价可忽略。用户选 16 MB。
- **32 MB**：能连 TypeDecoder 的窗口一起关。用户在得知 16 MB 关不掉 TypeDecoder 后仍选维持 16 MB、实测后如实登记（2026-09-03）。
- **全池抬到 16 MB**：连阻塞池一起改，要重新校准 0002 的深度上限与崩溃边界测试，影响面大于本提案需要。否决。
- **执行器提交用突发额度**（草稿写法）：突发额度是给互相等待的阻塞提交者破环用的，enqueue 一方从不阻塞，用它只会让执行器每类线程数膨胀到 `max(32, 4 × 核数)`。改用稳态额度。
- **按 `TaskPriority` 具名 case 写 switch 做映射**（草稿写法）：拼不出 user-interactive（常量已废弃），且运行时本身就是按原始值强转的。改为原始值恒等。
- **池拒绝时在 `enqueue` 里就地跑 job**：`enqueue` 在运行时调度路径里被调用，就地跑会递归回去。改为专用线程 → 全局 dispatch 队列。
- **public API**：任何下游都能用，但进入公开契约要文档与变更日志；目前唯一消费者是 MachOSwiftSection，先以 SPI 形态跑一个版本再议。用户选 `@_spi(Internals)`。
- **下游自建执行器**：不等本包发版，但进程里两套大栈线程池、栈策略分散在两个仓库。下游用户选上游。

## 影响

### 源码兼容性（source compatibility）

**纯新增**（SPI 面）。`LargeStackThreadPool.init` 与 `StackSafeExecutor.spawnDedicatedLargeStackThread` 加的参数都带默认值、都是 internal，既有调用点不变。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

MachOSwiftSection（接入方，提案 `draft-large-stack-executor-and-cross-version-parallelism`）；RuntimeViewer 经 MachOSwiftSection 间接受益，不直接接触本 SPI。

### 文档与示例

`Documentations/StackSafety.md` 第八节「任务执行器」（探测为什么对执行器线程直接通过、分池理由、优先级映射、回退链、实测数据、保留的限制）；`KnownIssues.md` #4 加 2026-09-03 部分关闭的裁决；`README.md`「Deep Generic Nesting and Thread Stacks」加 async 管线的用法；`AGENTS.md` 栈安全段加执行器速查。

## API 演进与废弃策略

无废弃项。SPI 形态运行一个版本后视下游反馈决定是否转正为 public（届时另起提案）。

## 落地步骤

1. ✅ `LargeStackThreadPool` 栈大小与线程名前缀参数化、`spawnDedicatedLargeStackThread` 栈大小与 QoS 类参数化，现有测试全绿（行为不变）。
2. ✅ `LargeStackTaskExecutor` + `StackSafeExecutor.taskExecutor`，门控与 SPI 标注。
3. ✅ 实测 16 MB 能关掉什么（见前期调研末条），据此写十条测试。
4. ✅ 文档：`StackSafety.md`、`KnownIssues.md` #4、README、`AGENTS.md`；两处索引状态。
5. ⏳ 合入 `main` 后打 tag 0.6.3（用户操作）。

**收尾时判断**：实现说明——并入 `StackSafety.md`，不另立；术语——「task executor」为 Swift 官方术语，不入术语表。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-09-03 | Created as Draft | 下游 MachOSwiftSection 调研「全库 async 化」时得出：真正的开销是 async 打印路径的逐次跳转，解法是让任务整体跑在大栈线程上；用户定执行器归上游 |
| 2026-09-03 | 分池共码；执行器 16 MB、阻塞池 8 MB；`@_spi(Internals)` | 下游澄清提问第四轮（用户否决了推荐的 public 可见性） |
| 2026-09-03 | 目标版本 0.6.3 | 0.6.2 已由用户实测恢复 0.6.0 的速度 |
| 2026-09-03 | 交接本仓库会话后四处修订：映射改原始值恒等；提交改稳态额度；回退链定为专用线程 → 全局 dispatch 队列、不就地跑；测试 1 改以线程身份断言 | 交接时授权由实现方自定的项；理由见「替代方案考量」 |
| 2026-09-03 | Accepted | 用户批准修订后的方案 |
| 2026-09-03 | 栈大小维持 16 MB，实测后如实登记 | 用户在得知 16 MB 关不掉 TypeDecoder 窗口（需约 30 MB）后的选择；实测结论：打印器与 remangler 的窗口在执行器路径上关闭 |
| 2026-09-03 | Implemented | 代码、十条测试与文档同批次提交到 `next`；发版 0.6.3 待用户打 tag |
