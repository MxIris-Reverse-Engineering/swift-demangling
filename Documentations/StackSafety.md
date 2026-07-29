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
- **被截断的片段不进 `printCache`**。printer 会把每个可缓存节点的渲染结果记进 `printCache`，而深路径放弃时写下的 `<<too complex>>` 就落在祖先节点的片段里。若照常缓存，同一个节点后续在浅层位置命中缓存时会重放这段截断——「非粘性」就名存实亡了。所以缓存前比对放弃计数，只有整棵子树完整渲染才写入。
- **保留一个极大的帧数兜底**（`absoluteDepthLimit = 1_000_000`），只用来防节点图成环导致的真无限递归——环不会逼近栈底，光靠栈探针停不下来。注意它只约束**递归的**那三个引擎；下面那些改成迭代的辅助函数增长的是工作队列而不是栈，不查任何上限，真给它一个成环的图会耗尽内存。本库自己产出的永远是 DAG 而非环，但手工构造的 `Node` 图可以是。
- **拿不到栈边界时回退到帧数**。非 Darwin 平台（以及 `pthread_get_stackaddr_np` 失败时）没有栈测量，此时 `StackBudget` 退回各引擎在本次改动前使用的那个帧数常数（printer 768、remangler / TypeDecoder 1024）。**这一点是必须的**：如果只是「拿不到就不设限」，那么在把三个引擎的帧数上限提到兜底值之后，Linux 上就等于完全没有护栏了。

预留量取 `min(1MB, max(栈大小 / 8, 32KB))`：小栈上 1MB 会吃掉全部预算，所以按比例缩；32KB 是下限，因此在小于 256KB 的栈上预留会超过八分之一。

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
| `getUnspecialized` | 传入护栏自行探针（要在退栈时重建节点，不能改循环；用帧数上限会重蹈固定帧数的覆辙——它每层还分配一个数组） |
| `mangleGenericArgs` | 补护栏检查（本来带 `depth` 但从不检查） |
| 7 个 protocol conformance 函数的互递归环 | 同上，逐个补 |

Printer 的 `findSugar` 只沿单子 `.type` 链下降，给了一个独立的小上限。TypeDecoder 的 6 处检查全部接上护栏。

### 四、顺带堵掉既有的全树递归

它们不属于任何引擎，因此从来不在任何护栏覆盖范围内：

- **`NodeCache.internTreeUnsafe`** —— 自底向上 hash-consing。`demangleAsNode` 默认 `internsSubtrees: true`，所以**每次 demangle 都会跑这趟**。改成迭代。
- **`Node.==` / `Node.hash(into:)`** —— 公开 API，深树上无界递归。改成迭代。（哈希的访问顺序变了，但相等的树仍产生完全相同的 `combine` 序列，契约只要求这个。）
- **`Node.copy()` / `Node.replacingDescendant(_:with:)`** —— 两条公开的整树递归，而且经 `NodeBuilder` 进入时递归发生在 `os_unfair_lock` **持锁期间**。第一轮调用图审计漏掉了它们（它们不在任何引擎里，靠「从引擎出发」的审计走不到）。改成迭代，共用一个 `RebuildFrame`。
- **`Node.Rewriter.rewrite`** —— 同样是公开的整树递归，且不经过 `StackSafeExecutor`。改成迭代不改变任何可重写点：`rewrite` 是 `public final func`，只有 `visit` 是 `open`，访问顺序仍是原来的后序。
- **`Node.description` 的树转储** —— 改成显式栈的先序遍历。它是调试器、日志、断言消息都会碰的入口，最不该按层吃帧。
- **`getUnspecialized`**（remangler） —— 见下文「返回 `nil` 的二义性」。
- **`DemanglingNode.isSimpleType` / `needSpaceBeforeType`** —— 沿 `.type` 包装链的线性下降，改成 `while` 循环。
- **store 侧五条**：`NodeStoreBuilder.internTree`（原 `internRecursively`）、`NodeStore.materializeNode`、`NodeReference.structurallyEquals` 两个重载、`NodeReference.structuralHash`。全部改成迭代。其中 `structurallyEquals(_ other: NodeReference)` 的同 store 短路现在在**每一层**生效，不只根节点。

**`getUnspecialized` 的返回 `nil` 二义性**：这个函数一边下降一边重建节点，所以不能写成纯循环。第一版给它加了栈探针，结果反而更糟——探针失败返回 `nil`，而调用方把 `nil` 一律翻译成 `.invalidNodeStructure`，于是「栈不够」被报成「树畸形」，`.tooComplex` 在这条路径上变成不可达，调用方会判定符号损坏并丢弃，而不是按文档换个大栈重试。改成自带 pending-rebuild 栈的迭代实现之后，没有递归也就没有深度可耗尽，`nil` 重新只有一个含义。

`NodeStoreBuilder` 那条值得单独说：`demangle(_:isType:)` 把 transient demangle 交给 `StackSafeExecutor`，但**返回之后才 intern**，而 intern 跑在调用方自己的线程上。批量索引场景下那就是一条 512KB 的协作线程——恰恰是最深的泛型类型到达的地方。改成迭代之前实测：debug 下 **500 层**崩、release 下 **1200 层**崩。这个形状是 `NodeStoreBuilder.demangle` 本来就有的（不是本次改动引入），但本次把「支持深嵌套」立为目标之后，它就从边缘风险变成了必须堵的口子。

### 五、`Node` 改成迭代式析构

这条谁都没提，但它是支持深树的必要条件：**释放一棵引用类型的树本身就是递归的**——释放根会释放孩子，孩子的 deinit 再释放它的孩子，一层一帧。实测 512KB 线程上释放 620 层的树直接崩。

而且这条**任何引擎侧的护栏都覆盖不到**：释放发生在最后一个引用消失的地方，由运行时执行，不经过本库任何代码。

`Node.deinit` 改成：把孩子摘进一个显式工作队列然后逐个排空。只有在「这是最后一个引用」时才拆解一个节点（`isKnownUniquelyReferenced`），否则它还活着、必须保留孩子。因为每个被唯一引用的节点在释放前孩子已被摘走，它自己的 deinit 就没有可下降的东西了。

### 六、线程池重做

原来是**每次调用新建一条 `Thread` 再 join**，实测每次约 41 µs——对一个典型符号是本体工作量的 5～18 倍，索引一个框架就是好几秒的纯开销。

新的池子有四条承重性质：

- **worker 不退休。** 「空闲超时退休」有一个窗口：超时触发后 worker 要重新抢锁，这期间的提交会把它算作可用、于是不建替补也没人接收信号，任务就此丢失、调用方永久阻塞。保持 worker 存活是消除这个窗口，而不是试图关上它。空闲 worker 的代价是一个内核线程结构；它们的 64MB 栈是没被写过的地址空间。
- **先建线程，再排队，且检查建线程是否成功。** 这条是第二轮 review 抓出来的：`Thread.start()` 没有失败返回值，而每条 worker 预留 64MB 栈，`pthread_create` 是可能失败的。原实现先在锁内 `workerCount += 1`、再到锁外 `start()`，失败时任务留在队列里没人取（同步调用方永久卡在信号量上，异步调用方的 `CheckedContinuation` 既不 resume 也不销毁，连运行时的 leak 诊断都不会触发），而那个幽灵名额还占着，导致之后每次提交都认为「人手够了」不再补线程——**线程池是进程级单例，一次失败永久毒化后续所有 demangle/print/mangle**。现在改用 `pthread_create` 并检查返回码，失败就释放名额。
- **提交可以被拒绝。** 被拒的任务由调用方在自己的线程上跑（`StackBudget` 保证那样不会崩，只是深度上限低一些）。这条是上面所有失败模式「降级而不是挂死」的落点。
- **worker 绝不等待池子。** printer 会为嵌套的 mangled 名字重新进入 demangle，这类从 worker 发出的提交会在有上限的池子上死锁。用线程本地 `pthread_key_t` 标记识别 worker，让这些调用直接内联跑——它们本来就已经在大栈上了。（`pthread_key_create` 的返回值现在也检查：拿不到 key 就整个禁用池子，全部内联跑，而不是让 worker 认不出自己然后死锁。）

**上限与突发额度。** 常规按需增长到 `max(2, activeProcessorCount)`。线程本地标记只挡得住 worker **直接**提交；一个 worker 如果扇出到别的线程（在 `withLargeStack` 批次里用 `concurrentPerform` 或 TaskGroup，索引 dyld cache 最自然的写法），那些提交来自池子认不出的线程，硬上限下外层等内层、内层排在外层后面，就是互锁。所以**阻塞式提交**额外获得一段额度，可以把池子撑到 `max(32, 4 × 常规上限)`——一个即将阻塞的调用方本身就是「有线程被 park 住」的证据，为它增长正是打破环的手段；**异步提交**挂起时不占线程、不可能参与这种环，因此守在常规上限内，一波 500 个 `executeAsync` 撑不大池子。同时阻塞的调用方超过突发上限时仍会排队，这一层残留限制没有消除，只是记录在案。

队列用头指针出队，不用 `removeFirst()`（那是持锁的 O(n) memmove），**并且出队时把槽位清空**——`removeAll` 只在队列恰好排空的那一刻才跑，持续突发下每个已执行完的闭包会一直被数组强引用，而 print / remangle 路径的闭包捕获着整棵 `Node` 树，峰值内存会随累计提交量而不是在途数量增长。每个 work item 包一层 `autoreleasepool`，否则 autorelease 对象的释放点会从「调用结束」漂移到「进程结束」。

### 七、新增批量作用域 API

`StackSafeExecutor.withLargeStack { }`，对应上游 SourceKit 的 `isStackDeep`。批量索引在最外层包一次，里面所有 demangle / print / remangle 直接内联跑，线程往返开销归零。

### 八、结果不再取决于调用线程

第一版的「当前线程栈够就内联跑」用的是 2MB 阈值，这条阈值制造了一个反直觉的结果：**栈越大的线程能力越差**。主线程 8MB 永远过阈值、于是一直内联跑，保留自己那个低得多的上限；而 512KB 的协作线程不过阈值、被搬到 64MB worker 上。实测同一棵 1000 层的树，debug 下 512KB 线程完整输出、8MB 线程返回 `<<too complex>>`，4MB 线程比 512KB 线程还差。`node.print()` 于是不是纯函数：同样的代码放进 `Task` 正常、放在主线程截断。新加的 `withLargeStack` 从主线程调用更是彻底空转——名字承诺的东西一件没做。

现在阈值改成 **worker 自己的栈大小**：只有真正已经有 ≥64MB 可用的线程才内联跑，其余一律搬到 worker。于是契约变成一句能用的话：**无论从哪条线程调用，工作都在至少一个 worker 那么大的栈上跑**（除非池子拒收，那时 `StackBudget` 兜底）。代价是主线程的单次调用多一次线程往返（实测约 6 µs 量级）；批量场景本来就该用 `withLargeStack`，作用域内为零。

`TypeDecoder` 也在这一轮补上了 `StackSafeExecutor`——它是三个引擎里唯一漏掉的，实测 512KB 协作线程上 200 层嵌套就抛 `too complex`，而同一棵树在同一线程上 print / mangle 能到 1000 层。因为 `TypeBuilder` 和它构建的类型都没有 `Sendable` 约束，走的是新增的 `executeWithUncheckedSendability`（调用方全程阻塞，是严格交接，编译器的检查在这里比实际情况更严）。

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
- **非 Darwin 平台**：`StackBudget.forCurrentThread(fallbackDepthLimit:)` 退化为帧计数，取各引擎在本次改动前用的那个数，行为与改动前一致。
- **主线程上的单次调用多一次线程往返**（见第八节）。换来的是「结果与调用线程无关」。
- **`NodeReference.structuralHash` 的编码变了**，现在与 `Node.hash(into:)` 一致（两边都喂 `Node.Contents`）。之前两套手写编码对不上，导致 `structurallyEquals` 文档里承诺的「用外部 demangle 的 `Node` 在 `NodeReference` 字典键里查找」100% 查不到。同时给 `Node` 加了同名的 `structuralHash(into:)`（就是 `hash(into:)` 的别名），让这个用法两边对称。
- **`extendedExistentialTypeShape` 的打印输出变了**：之前读子节点 1/2，而 demangler 建在 0/1，结果把 requirement signature 打在类型位置、类型本身输出 `<null node pointer>`。C++ 上游有同样的 off-by-one，这里**有意与上游分歧**——`<null node pointer>` 对一个展示符号的工具没有任何用处。
- **store 打印路径不再污染 `NodeCache.shared`**：printer 中三处对嵌套 mangled 名字的重新 demangle 原先走公开的 `demangleAsNode`（默认 intern），现在走 `demangleAsNodeTransient`。整个二进制打印一遍不再让全局缓存无界增长。
- **`DemanglingPrinter` / `NodePrinter` 现在可以安全复用**：`printRoot` 会重置 target、fragment 缓存、`specialized ` 前缀标记和深度状态。之前只重置了栈预算，于是第二个符号会把第一个的输出接在前面；store 路径更糟——缓存键是每个 store 从 0 开始的节点索引，跨 store 直接撞车。缓存键现在是整个 `NodeReference`（store 身份 + 索引）。

## 迁移注意事项

- 批量场景请改用 `StackSafeExecutor.withLargeStack { }` 包住整批，而不是依赖逐次调用的自动跳转。
- 直接驱动 `DemanglingPrinter` / `NodePrinter` 的富文本消费方不需要改动：护栏在 `printName` 内部，`printRoot` 也受保护。
- 若消费方自己建线程跑 demangling，建议把 `stackSize` 设为 64MB 并在其上直接调用——`StackSafeExecutor` 会判定栈足够而全程内联，零往返。

## 未解决 / 待评估

### 仍是递归、且是有意保留的

- **`Demangler` 的 `setParentForOpaqueReturnTypeNodesImpl` 与 `demangleBoundGenericArgs`** —— 前者处理 opaque return type（即 `some View`），后者处理绑定泛型，都在常规路径上。`Demangler` 是三个引擎里唯一没有 depth 参数的（主循环不是递归下降，上游也因此没给它深度限制），接护栏要单独引入状态。
- **`demangleSwift3*` 的 16 函数互递归环** —— 只有 `_T` 前缀符号可达，基本绝迹，上游同样无限制。

这两条都在 `demangleAsNode` 内部，而 `demangleAsNode` 走 `StackSafeExecutor`，所以确实跑在 64MB worker 上，实测 demangle 到 4000 层没问题，**现实深度下不会崩**；但它们的失败模式是崩溃而不是报错。想把「预期能撑住的深度」再往上抬之前，得先给它们加护栏。

> 上一版这里还列着 `Node.Rewriter.rewrite` 和 `Node.description`，理由写的是「`open class`，改迭代会改变可重写点」和「都跑在 64MB worker 上」。两条都不成立：`rewrite` 是 `public final func`（只有 `visit` 是 `open`），而它根本没经过 `StackSafeExecutor`，实测 512KB 线程上约 600 层就 SIGBUS。两者现已改成迭代，见上文第四节。

### 其他待评估
- **printer 改成显式栈迭代**（彻底与线程栈解耦）暂未做：64MB 已足够任何真实符号，而 printer 带着 `printCache`、`asPrefixContext` 等状态，迭代化的出错面远大于收益。
- 每层探针的实测代价尚未单独量化（当前数据是端到端的，且端到端是净改善）。若后续发现是热点，可考虑「探针 + 观测到的实际每层开销自适应调整间隔」，而不是回到固定间隔。
