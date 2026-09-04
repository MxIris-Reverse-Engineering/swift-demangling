# 大栈任务执行器：让 async 管线里的每次调用都不再跳线程

日期：2026-09-04（实现落地 2026-09-03，随 0.6.3 发布）

对应提案：`Evolutions/0014-large-stack-task-executor.md`（决策过程与被否的方案在那里）
概念背景：[Concepts/RecursionAndStack.md](Concepts/RecursionAndStack.md)（栈为什么会爆、
线程栈大小、`StackSafeExecutor` 为什么存在）。本文假设你没读过它，第 1 节会把要用到的
部分重讲一遍；想深究再去读。词条速查见 [Glossary.md](Glossary.md)。

## 一句话结论

`StackSafeExecutor` 决定「要不要换条大栈线程跑」时看的是**当前线程还剩多少栈**，而不是
「当前是哪条线程」。所以只要把一个 Swift Concurrency 任务整个放到一条 16 MB 栈的线程上，
任务里每一次 demangle / print / remangle 的探测都会直接通过、原地执行——原来每次调用都要
付的一次线程往返（release 下 8–21 µs）就没了，而且一行引擎代码都不用改。这条 16 MB 线程
由新增的 `LargeStackTaskExecutor` 提供，用 `withTaskExecutorPreference(StackSafeExecutor.taskExecutor)`
把任务放上去即可。

## 1. 背景：三件事凑在一起，才有这个问题

### 1.1 递归引擎需要大栈，而大多数线程没有

本库有三个递归引擎：打印器（`NodePrinter`，把节点树变成人读的字符串）、remangler（把节点
树重新编码回 mangled 符号）、`TypeDecoder`。它们按节点树的深度递归，一个套了几百层泛型的
类型就要几百层栈帧。

线程栈不是无限的，而且**不同线程差很多**：macOS 主线程 8 MB；Swift 并发的协作线程池
（cooperative thread pool，`Task {}` 和 `async` 函数默认跑在上面的那组线程）每条只有
**512 KB**；libdispatch 的线程也是 512 KB。栈压满不是抛异常，是进程直接被系统杀掉。

### 1.2 `StackSafeExecutor`：不够就搬到大栈线程上

为了让引擎在 512 KB 的线程上也不崩，每个公开入口（`demangleAsNode`、`print(using:)`、
`mangleAsString`）都经过 `StackSafeExecutor`。它做的事只有两步：

1. **探测**：用 `pthread_get_stackaddr_np` / `pthread_get_stacksize_np` 算出当前线程还剩
   多少栈。
2. **决定**：剩余 ≥ 2 MB 就在当前线程原地跑；不够就把闭包交给一条 8 MB 栈的常驻 worker
   线程，当前线程在信号量上等它跑完。

```
调用线程剩余栈 ≥ 2 MB  →  原地跑（主线程、你自己建的大栈线程：零开销）
调用线程剩余栈 < 2 MB  →  搬到 8 MB worker 上跑，等结果（512 KB 的协作线程走这条）
```

第二条路我们叫**跳转**（hop）。一次跳转的成本不是线程创建（worker 是常驻的、池化的，
创建只发生一次），而是**每次调用**都要付的：把闭包排进队列、唤醒一条停着的 worker、
调用线程在信号量上睡下、worker 跑完再把调用线程叫醒。两次上下文切换外加两次同步原语操作。

### 1.3 async 管线卡在这里

下游 MachOSwiftSection 的打印管线是 `async` 的，跑在协作线程上。协作线程 512 KB，探测
**永远不通过**，于是每次打印都跳一次。它自己实测（release 构建，`Documentations/Internal/Reviews/2026-07-31-node-store-migration-review.md`）：

| 符号 | 协作线程上每次打印比原地跑多付 | 相当于 |
|---|---|---|
| 小树 | 8.2 µs | 原地跑的 2.28 倍 |
| 916 字符的真实符号 | 20.8 µs | 原地跑的 1.14 倍 |

对小符号，跳转比工作本身还贵一倍多。索引一个框架要打印几十万个符号，这笔钱是按次付的。

本库早就有针对批量场景的办法：`withLargeStack { … }`。它自己先跳一次到大栈线程，然后
在闭包里跑整批——闭包里每次调用探测到「栈很多」，全部原地跑，整批只付一次跳转。下游的
索引扫描就是这么做的（10 万符号 1317 ms → 701 ms）。

但 `withLargeStack` 接的是一个**同步**闭包。async 的打印循环里有 `await`，`await` 不能
出现在同步闭包里，所以**包不住**。评审记录里写着两条出路：把打印循环改回同步（要砍下游
的 async API），或者「自定义一个跑在大栈线程上的执行器」。本文就是后者。

## 2. 优化思路：不搬工作，搬任务

原来的模型是「工作在小栈线程上发起，需要时**把工作搬到**大栈线程」。换个方向：**让任务
一开始就住在大栈线程上**，工作根本不用搬。

Swift Concurrency 从 Swift 6.0 起（SE-0417，运行时 macOS 15 / iOS 18 / tvOS 18 /
watchOS 11 / visionOS 2）允许给任务指定一个**任务执行器**（`TaskExecutor`）。几个名词：

- **job**：任务被切成的一段段可执行单元。任务每次从 `await` 恢复，运行时就产生一个新 job。
- **执行器**（executor）：拿到 job 后决定「在哪条线程上跑它」的对象。协议只要求实现一个
  方法 `enqueue(_ job:)`，拿到 job 后自己安排线程，在那条线程上调
  `job.runSynchronously(on:)` 就把这段任务跑完了。
- **执行器偏好**（executor preference）：`withTaskExecutorPreference(executor) { … }` 把
  闭包里的任务（含它派生的子任务、`async let`、`TaskGroup` 的子任务，以及没有指定执行器
  的 actor）都交给这个执行器；用 `Task(executorPreference:)` 也可以。**非结构化的
  `Task {}` / `Task.detached {}` 不继承偏好**——这是官方规则，接入时容易忘。

本库新增 `LargeStackTaskExecutor`：一个 `TaskExecutor`，它的线程是本库自己用
`pthread_create` 建的、栈 16 MB。把任务放上去之后：

```
withTaskExecutorPreference(StackSafeExecutor.taskExecutor) {
    for symbol in symbols {
        let node = try demangleAsNode(symbol)      // 探测：剩余栈 ≈ 16 MB ≥ 2 MB → 原地跑
        let text = node.print(using: .default)      // 同上
        await sink.write(text)                      // 挂起；恢复后的 job 仍回到执行器线程
    }
}
```

任务里每一次调用探测都通过，全部原地跑。`await` 之后任务恢复，新的 job 仍交给同一个执行器，
仍在 16 MB 线程上——所以这是「整个任务生命周期内零跳转」，而不是「某一段里零跳转」。同步
被调方（比如下游自己写的同步辅助函数，里面再调 `print`）也一样受益，因为探测看的是线程，
不区分调用来自 async 还是同步代码。

## 3. 为什么可以这么优化

这个做法成立，靠的是三条既有事实，没有引入任何新假设。

**第一，探针看栈不看线程。** `currentThreadHasSufficientStack` 只算「当前栈指针离栈底
还有多远」。它不知道也不关心自己是在主线程、协作线程还是本库的执行器线程上。所以执行器
线程不需要任何「特殊通道」，它只是一条恰好栈很大的线程，探针对它的判断和对主线程一样。
这也是为什么引擎、探针、跳转池一行都不用改。

**第二，输出与线程无关。** 三个引擎的深度上限是**帧计数**（递归到第 768 / 1024 层就停），
不是「看栈还剩多少」。同一棵树在 512 KB 线程和 16 MB 线程上走的是同样的递归路径、停在
同样的位置，输出逐字节相同（`StackSafetyTests.printedOutputIsIndependentOfTheCallingThreadStackSize`
钉着这条）。跳转本来就是一个纯粹的「换地方跑」，省掉它不改变任何结果。

**第三，跳转的正确性从来不依赖跳转本身。** 跳转只是让「栈够」这个前提成立的一种手段；
`withLargeStack` 早就证明了「让前提成立一次、整批原地跑」是安全的。执行器做的是同一件事，
只是让前提在整个任务里都成立。

换句话说：这不是在跳转路径上做微优化，而是让跳转路径**不再被走到**。

## 4. 细节

### 4.1 执行器有自己的一组线程，不和跳转池共用

本库已经有一个线程池 `LargeStackThreadPool.shared`，给跳转用。最省事的做法是执行器也从
这个池里拿 worker。没这么做，原因是**两种活的寿命差太多**：

| | 跳转 | 执行器 job |
|---|---|---|
| 一个条目是什么 | 一次 demangle / print / remangle | 一段任务：从一次 `await` 到下一次 `await`，可能是整个 `printRoot` |
| 典型时长 | 微秒到毫秒 | 毫秒到上百秒 |
| 提交者会不会等 | 会，阻塞在信号量上 | 不会，`enqueue` 立即返回 |

池按 QoS 类（后面讲）分成五个子池，每个子池稳态最多 `max(2, 核数)` 条 worker；只有
「提交者要阻塞等待」的提交才允许超过稳态，最多到 `max(32, 4 × 稳态)`，这个额度叫突发额度，
存在的意义是打破「A 等 B、B 排在 A 后面」的死锁环。如果执行器和跳转共用一个池，几个长 job
就把某个类的稳态额度占满，之后每次同步跳转都被挤进突发额度、突发额度也满了就每次新建一条
临时线程——跳转从「唤醒一条停着的 worker」退化成「创建一条线程」（约 41 µs），而跳转正是
下游索引一个框架要走几十万次的路径。

所以执行器持有**自己的一个 `LargeStackThreadPool` 实例**。池的代码（`pthread_create` 建线程、
按 QoS 类分区、`NSCondition` 停车与唤醒、创建失败时的回滚与排空、worker 永不退休）全部复用，
只把「栈多大」和「线程叫什么名」做成了初始化参数：

| | `LargeStackThreadPool.shared`（跳转） | 执行器的池 |
|---|---|---|
| 线程栈 | 8 MB | 16 MB |
| 线程名 | `swift-demangling.large-stack-worker.<qos>` | `swift-demangling.task-executor.<qos>` |
| 提交额度 | 阻塞提交可用突发额度 | 只用稳态额度 |

「只用稳态额度」是因为 enqueue 的一方从不阻塞，没有环可破；每个类最多 `max(2, 核数)` 条
线程，和 Swift 自己的协作线程池一样宽。

### 4.2 job 在哪个 QoS 类上跑

QoS（quality of service）类是 Darwin 给线程排优先级的机制，从高到低：user-interactive、
user-initiated、default、utility、background。跳转池按类分区的规则是：**一条 worker 建出来
时就定了类，终身不改；提交只会唤醒或创建同类的 worker。** 这样高优先级的调用者绝不会等在
低优先级线程上（细节见 `StackSafety.md` 第三节）。

执行器沿用这套分区，但有一个新问题：跳转的提交者就是调用线程，它的类就是活的类；而
**调 `enqueue` 的线程是「恢复这个任务的那条线程」**，可以是任何线程，它的类和任务本身的
优先级没关系。所以执行器不能看提交线程，要看 job 自己的优先级。

好在 Swift 运行时把这件事做得很直接：`JobPriority` 的原始值**就是** Darwin QoS 类的数值
（user-interactive = 0x21、user-initiated = 0x19、default = 0x15、utility = 0x11、
background = 0x09），运行时自己的全局执行器就是把 priority 直接强转成 QoS 类交给
`dispatch_get_global_queue` 的。执行器照做：

```swift
static func qualityOfServiceClass(for priority: JobPriority) -> qos_class_t {
    if priority.rawValue == 0 { return QOS_CLASS_DEFAULT }      // unspecified：dispatch 也是这么处理的
    return qos_class_t(rawValue: UInt32(priority.rawValue))    // 其余：原始值就是 QoS 类
}
```

一个本构建不认识的值（未来 OS 新增的类）会原样交给池，池按既有规则**拒绝而不是归到某个
已知类**（归到已知类等于擅自抬高或压低一个未知等级的活），拒绝后走下面的回退。

### 4.3 `enqueue` 的完整流程

```
enqueue(job)
  │  类 = job.priority 对应的 QoS 类
  ├─ 1. 执行器的池 trySubmit（稳态额度）        成功 → 某条 16 MB worker 跑它
  ├─ 2. 一次性 16 MB 专用线程（按 job 的类建）  成功 → 那条线程跑它
  └─ 3. DispatchQueue.global(qos: 类).async     job 照跑，只是回到 512 KB 线程、探针照跳
```

第 2、3 步只在「操作系统建不出线程」时才会走到；第 3 步保证 job 永远不丢——GCD 的队列
不会拒绝，只会排队。`enqueue` **绝不在当前线程就地跑 job**：它是被运行时的调度代码调用的，
就地跑等于在调度路径里递归回去。

### 4.4 为什么是 16 MB，以及它买到了什么

跳转池的 worker 是 8 MB。执行器线程翻倍到 16 MB，是为了顺手处理一个登记在案的问题
（`KnownIssues.md` 第 4 条）：**debug 构建下，深度上限还没轮到生效，栈就先崩了。**

原因在 [Concepts/RecursionAndStack.md](Concepts/RecursionAndStack.md) 第 3 节：未优化构建的
栈帧比优化构建大一个数量级。打印器的上限是 768 个深度单位，debug 下每单位约 11.6 KB，
768 × 11.6 KB ≈ 8.9 MB > 8 MB。上限的取值和上游 Swift 编译器相同，不能下调（下调过一次，
把正常的 SwiftUI 模块截断成了 `<<too complex>>`，已回退）。

16 MB 够不够，算是算不出来的（每层帧大小随符号形状变），所以实测（2026-09-03，debug，
arm64，用 `Int` 外面套 n 层 `Optional` 的符号；这个形状每层占打印器 2 个深度单位、
remangler 4 个）：

| 引擎 | 8 MB 线程 | 16 MB 执行器线程 |
|---|---|---|
| 打印器 | 380 层嵌套即 SIGBUS（≈ 760 单位，计数器还没到 768） | 380 层完整输出；383 层起干净返回 `<<too complex>>` |
| remangler | 200 层即 SIGBUS（≈ 800 单位，上限 1024） | 240 层往返成功；260 层起抛 `.tooComplex` |
| `TypeDecoder` | 约 250 单位崩（每单位约 30 KB） | 仍会先崩：1024 单位需要约 30 MB |

所以在执行器路径上，打印器和 remangler 的「计数器来不及生效」窗口关闭了：栈先撑到计数器
触发，超限时得到的是标记 / 错误而不是崩溃。`TypeDecoder` 的窗口 16 MB 关不掉，而且它本来
就不经过 `StackSafeExecutor`（它调用的是使用方的回调，必须留在调用线程），跑在执行器上只是
从 512 KB 变成 16 MB。跳转池仍是 8 MB，那条路径上第 4 条照旧开放。

16 MB 的代价：线程栈是**虚拟地址预留**，只有真正递归到那么深时才会按页提交物理内存。
最坏情形是五个 QoS 类各 `max(2, 核数)` 条 16 MB 线程的地址空间预留，双核手表上 160 MB
地址空间、几乎为零的实际内存。

### 4.5 和既有机制怎么互动

- **执行器 worker 也打「我是池 worker」的标记**（`isRunningOnPoolWorker`）。这个标记的作用
  是：一条 worker 自己栈不够时，绝不向自己所在的池回提交（那个等待可能排在它自己正在跑的
  条目后面），而是起一条一次性线程。16 MB 下这种情况实际不会发生，但规则保持一致。
- **执行器线程上的 `executeAsync`**：探测通过就原地跑；万一不通过，它提交的是 `shared`
  跳转池，不是执行器自己的池，没有自锁。
- **打印时嵌套的 demangle**：打印器遇到内嵌的 mangled 名会再次调 demangle，那次调用一样
  探测、一样原地跑。

### 4.6 怎么用

```swift
@_spi(Internals) import Demangling

if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
    try await withTaskExecutorPreference(StackSafeExecutor.taskExecutor) {
        // 这里面，以及这里派生出的子任务里，demangle / print / remangle 全部原地跑
    }
}
```

- 它是 `@_spi(Internals)`，和 `withLargeStack` 一样要用 SPI 导入；先以 SPI 形态跑一个版本，
  再决定要不要转正为 public。
- 老系统上没有这个符号，`#available` 是必须的；本库最低支持 macOS 10.15。
- 非 Darwin 平台没有它（线程池本身就是 Darwin 专属）。
- **`Task {}` 不继承偏好**：入口函数里若用非结构化任务，要写 `Task(executorPreference: StackSafeExecutor.taskExecutor) { … }`。
- **不要在 job 里阻塞线程等另一个同类 job**：每个类只有 `max(2, 核数)` 条线程，阻塞式
  互等会把它们耗光，和协作线程池的规矩一样。
- 它不是 `SerialExecutor`，actor 不能隔离到它上面。

## 5. 保留的限制

- **Thread Performance Checker 可能报告一条「优先级反转」**：停在条件变量上的执行器 worker
  可能被一条比它类低的线程唤醒（因为恢复任务的线程是任意的）。没有人等在那条 worker 上，
  所以不是真正会让谁变慢的反转；任何「job 由任意线程恢复」的自定义执行器都有这个形状。
- **优先级提升（escalation）不处理**：job 已经在某个类的线程上跑起来后，即使任务被提升
  优先级，线程也不会换类。
- **`TypeDecoder` 在执行器上仍可能爆栈**（4.4 节）。

## 6. 怎么验证的

`Tests/DemanglingTests/LargeStackTaskExecutorTests.swift`，十条测试，每条以运行时可用性
门控开头（老系统上直接跳过）：

| 测试 | 钉住的性质 |
|---|---|
| `callsInsideATaskOnTheExecutorRunInline` | 核心性质：执行器上 `execute` 与 `executeAsync` 都在任务自己的线程上跑（比 `pthread_self`）。池子没有「提交次数」计数器，线程身份是唯一干净的断言 |
| `executorThreadsCarryTheExecutorStackAndName` | 线程 ≥ 16 MB、名字带执行器前缀 |
| `aJobRunsAtTheClassOfItsPriority` | `.background` / `.utility` / `.medium` / `.userInitiated` 各落各的 QoS 类 |
| `priorityMapsToTheQualityOfServiceClassOfTheSameRawValue` | 映射是原始值恒等；unspecified → default；未知值被池拒绝 |
| `jobsOnTheExecutorDoNotOccupyTheHopPool` | 占满执行器某类全部稳态 worker 后，同类的同步跳转仍落在 8 MB 跳转池 worker 上、跳转池不增长——分池与共池的判别性断言 |
| `aJobThePoolCannotTakeStillRunsOnALargeStackThread` | 模拟建线程失败，job 落在 16 MB 专用线程上、不在 enqueue 线程上 |
| `printingOnTheExecutorSurvivesADepthThatOverflowsAnEightMegabyteThread` | 380 层在执行器上完整打印（同深度 8 MB 上 SIGBUS） |
| `printingOnTheExecutorDegradesPastTheDepthLimitInsteadOfCrashing` | 1000 层返回 `<<too complex>>`——第 4 条当年从 `StackSafetyTests` 移除的断言，在这条路径上恢复 |
| `remanglingOnTheExecutorSurvivesADepthThatOverflowsAnEightMegabyteThread` | 200 层在执行器上往返（同深度 8 MB 上 SIGBUS） |
| `remanglingOnTheExecutorDegradesPastTheDepthLimitInsteadOfCrashing` | 1000 层抛 `.tooComplex`——同上 |

完整测试集 588 个测试全绿。8 MB 上的两处 SIGBUS 是一次性探针跑出来的（进程直接死，进不了
测试集），数字记在提案 0014 的前期调研里。

## 在本库的哪里

- `Utils/LargeStackTaskExecutor.swift` — 执行器本体、优先级映射、回退链、`StackSafeExecutor.taskExecutor`
- `Utils/StackSafeExecutor.swift` — 探针、跳转、`LargeStackThreadPool`（栈大小与线程名现在是参数）
- `Tests/DemanglingTests/LargeStackTaskExecutorTests.swift`

相关文档：[StackSafety.md](StackSafety.md) 第三节（跳转池的全部性质）与第八节（本文的
浓缩版）、[KnownIssues.md](KnownIssues.md) 第 4 条、
[Concepts/RecursionAndStack.md](Concepts/RecursionAndStack.md)。
