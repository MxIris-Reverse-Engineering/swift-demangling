# 0002 - Stack Safety: Bound Recursion by Remaining Stack, Not by Frame Count

- **Proposal**: 0002
- **Author**: Mx-Iris
- **Status**: Implemented, then **revised 2026-07-29**（`StackBudget` 机制撤回，回到与上游同构的「8MB 大栈 + 实测校准的固定深度上限」；见文末「2026-07-29 修订」）
- **Date**: 2026-07-28
- **Branch**: `feature/stack-budget-guard`（自 `feature/node-store` 切出）
- **Related**: `Documentations/StackSafety.md`（**最终形态**的实现说明与实测数据）

> **阅读提示**：Summary 至 Alternatives Considered 是 2026-07-28 首版方案的历史记录，其中 `StackBudget`、64MB worker、64MB 内联判据、`TypeDecoder` 包装四项已于次日撤回；保留的部分与撤回理由见文末「2026-07-29 修订」。

## Summary

把三个递归引擎（`DemanglingPrinter` / `Remangler` / `TypeDecoderEngine`）的护栏从**固定帧数上限**换成**剩余栈字节探针**，把 worker 线程栈从 8MB 提到 64MB，并把所有护栏覆盖不到的全树递归改成迭代。目标是：合法的深嵌套泛型能完整输出，且任何构建配置、任何线程栈大小下都不崩。

## Motivation

### 症状

SwiftUI 中返回 `some View` 的声明，其底层具体类型嵌套极深，且完全合法。实测（嵌套 Optional 符号）：

| | release | debug |
|---|---|---|
| `print` | 384 层返回 `<<too complex>>` | **375 层 SIGBUS** |
| `mangleAsString` | 256 层返回 `.tooComplex` | **150 层 SIGBUS** |

release 下被上限挡掉时线程栈还剩几十兆；debug 下上限还没触发栈就耗尽了。**同一个常数在两种配置下分别过严和过松。**

### 根因

帧数是栈字节的代理量，而「一帧多少字节」在三个维度上都不是常量：构建配置（debug 比 release 大一个数量级）、泛型特化（`DemanglingPrinter` 对 `Node` 和 `NodeReference` 各特化一份，帧大小不同）、线程栈大小（主线程 8MB vs 协作线程 512KB）。

调大常数无解：调大到容纳合法深符号则 debug 崩，调小到 debug 安全则 release 拒绝更多合法符号。

### 上游参照

`swift/lib/Demangling/` 没有任何栈相关代码；全仓 `pthread_get_stackaddr_np` 只有一处封装且与 demangling 无关。上游靠「固定帧数上限 + 调用方在任务边界一次性换大栈线程」（SourceKit 的 `isStackDeep`、IRGen 的 `pthread_attr_setstacksize(8MB)`、`ModuleInterfaceBuilder` 的 `RunSafelyOnThread`）。

上游的 remangler 有和本仓完全相同的无保护递归（`hashForNode` ↔ `entryForNode`、`deepEquals`），它能活下来正是因为调用方保证了大栈。作为库我们无法把决策上推到调用方的任务边界，需要自己的答案。

## Detailed Design

### 1. `StackBudget`（`Utils/StackBudget.swift`）

入口按当前线程栈边界算 floor（栈底 + 预留量），递归时比较栈指针。

- **每层都探。** 曾试过按「预留量 / 假定每层开销」推导采样间隔，不安全：假定值一旦不成立，两次探针之间就能跨过整个预留区。猜帧大小正是要摆脱的错误。
- **读取隔离在 `@inline(never)` 辅助函数**，避免给热路径递归函数的序言塞进 stack-protector。
- **非粘性**：深路径触发后退栈，浅层兄弟节点正常输出，与原语义一致，且避免标记刷屏。
- **保留极大帧数兜底**（`absoluteDepthLimit = 1_000_000`）防节点图成环。
- 预留量 `min(1MB, max(栈大小 / 8, 32KB))`，小栈上按比例缩。

### 2. 递归审计

动手前用调用图 + Tarjan 强连通分量做了审计，并**把候选收敛点从图里删掉再找一次**，剩下的环即护栏盲区：

| 引擎 | 收敛点 | 删后剩余环 |
|---|---|---|
| `DemanglingPrinter` | `printName` | 1（`findSugar`） |
| `Remangler` | `mangle` + `mangleAnyNominalType` | **6** |
| `TypeDecoderEngine` | `decodeMangledType` | 4 |

Remangler 那 6 条的处理：`hashForNode` ↔ `entryForNode` 与 `deepEquals` 改迭代；`isSpecialized` 改循环（本就是尾递归）；`getUnspecialized` 加独立深度上限；`mangleGenericArgs` 与 7 个 protocol conformance 函数补护栏检查。

### 3. 引擎之外的全树递归

不属于任何引擎、因此从不在护栏范围内的：`NodeCache.internTreeUnsafe`（每次 demangle 都跑）、`NodeStoreBuilder.internTree`、`Node.==` / `hash(into:)`（公开 API）、`Node.copy()` / `replacingDescendant(_:with:)`（公开，且经 `NodeBuilder` 进入时在持锁期间递归）、`Node.Rewriter.rewrite`、`Node.description` 的树转储、`NodeStore.materializeNode`、`NodeReference.structurallyEquals` ×2、`NodeReference.structuralHash`、`getUnspecialized`、`DemanglingNode.isSimpleType` / `needSpaceBeforeType`。全部改成迭代。

`NodeStoreBuilder` 那条是审计的盲点：`demangle(_:isType:)` 把 transient demangle 交给 `StackSafeExecutor`，intern 却在返回后跑在调用方线程上（批量索引即 512KB 协作线程）。这是该方法本来就有的形状，但在「支持深嵌套」成为目标后必须堵——改动前实测 debug 500 层崩、release 1200 层崩。

### 4. `Node` 迭代式析构

释放引用类型的树本身就是递归的，且发生在最后一个引用消失处、由运行时执行，**任何引擎侧护栏都覆盖不到**。实测 512KB 线程释放 620 层的树直接崩。

`deinit` 改成把孩子摘进显式工作队列逐个排空，仅在 `isKnownUniquelyReferenced` 为真时拆解，共享子树保持完整。

### 5. worker 栈 8MB → 64MB

线程栈是虚拟地址空间预留，只有写到的页才占物理内存，代价是地址空间而非常驻内存。

### 6. 线程池重做

原来每次调用新建 `Thread` 再 join，实测每次约 41 µs。新池子四条承重性质：

1. **worker 不退休** —— 消除「空闲超时退休窗口丢任务」。
2. **先建线程再排队，且检查建线程是否成功** —— 用 `pthread_create`（有返回码）而不是 `Thread.start()`（无返回码）。原来的顺序在 `pthread_create` 失败时会留下永久占名额的幽灵 worker，任务无人认领、调用方永久阻塞，而且因为名额已占，之后所有提交都不再补线程——进程级单例被一次失败永久毒化。
3. **提交可以被拒绝** —— 被拒的任务由调用方自己跑，`StackBudget` 兜底。这是所有失败模式「降级而不是挂死」的落点。
4. **worker 绝不等待池子** —— 线程本地 `pthread_key_t` 标记（`pthread_key_create` 的返回值同样检查；拿不到 key 就整体禁用池子），嵌套调用内联跑。

上限：常规增长到 `max(2, activeProcessorCount)`；**阻塞式**提交额外获得到 `max(32, 4 ×)` 的额度，用于打破「worker 扇出到别的线程、内外互等」的环（异步提交挂起时不占线程，不可能参与这种环，守在常规上限内）。队列头指针出队，**出队时清空槽位**（否则持续突发下已执行完的闭包全部存活，而它们捕获着整棵 `Node` 树）；每个 work item 包 `autoreleasepool`。

### 7. `StackSafeExecutor.withLargeStack(_:)`

对应上游 SourceKit 的 `isStackDeep`：批量场景在最外层包一次，内部全部内联，往返开销归零。

### 8. 内联判据改成 worker 栈大小

原来的判据是「当前线程剩余栈 ≥ 2MB 就内联跑」。这让主线程的 8MB 永远内联、保留自己那个低得多的深度上限，而 512KB 协作线程反而被搬到 64MB worker 上——**栈越大能力越差**，同一棵 1000 层的树在 debug 下从 `Task` 里完整输出、从主线程返回 `<<too complex>>`；新加的 `withLargeStack` 从主线程调用完全空转。判据改成 worker 自己的栈大小后，契约是「无论从哪条线程调用，都在至少一个 worker 那么大的栈上跑」。代价是主线程单次调用多一次往返（约 6 µs 量级）。

`TypeDecoder` 的公开入口这一轮补上了 `StackSafeExecutor`（此前是三个引擎里唯一漏掉的，512KB 线程上 200 层就报 `too complex`）。因为 `TypeBuilder` 与其构建的类型都无 `Sendable` 约束，走新增的 `executeWithUncheckedSendability`：调用方全程阻塞，是严格交接。

## Impact

- `NodePrinter.maxPrintDepth` 标记 deprecated；`TypeDecoder.maxDepth` 提高到兜底值；`Remangler.maxDepth` 已无引用，删除。
- 行为变化：以前返回 `<<too complex>>` / `.tooComplex` 的深符号现在多数正常输出。
- `Node.==` / `hash(into:)` 遍历顺序变化（哈希值本就不跨进程稳定）。
- 非 Darwin 平台退化为帧计数（取各引擎改动前用的那个数），行为与改动前一致。
- 主线程单次调用多一次线程往返，换来「结果与调用线程无关」。
- `NodeReference.structuralHash` 编码改为与 `Node.hash(into:)` 一致；`Node` 增加同名别名 `structuralHash(into:)`。
- `extendedExistentialTypeShape` 的打印修正子节点索引（有意与上游的 off-by-one 分歧）。
- store 打印路径不再通过公开 `demangleAsNode` 污染 `NodeCache.shared`。
- `DemanglingPrinter` / `NodePrinter` 可安全复用：`printRoot` 重置全部逐次状态；store 路径的 fragment 缓存键改为整个 `NodeReference`。

## Results

深度能力（debug）：`print` 从「384 层放弃、375 层崩」变为 **3000 层正常输出且不崩**。

线程往返（release，512KB 线程）：`demangleAsNode` 46.73 → 12.48 µs（−73%）、`print` 43.10 → 8.49 µs（−80%）、`mangleAsString` 53.89 → 17.73 µs（−67%）。`withLargeStack` 作用域内往返开销为零（6.43 µs/次 vs 主线程内联基线 6.58 µs/次）。

正确性：dyld 共享缓存全量语料 **4,522,325** 个真实符号，demangle 失败 / node tree 不一致 / remangle 不一致 均为 0。

## Alternatives Considered

**保持固定帧数、只调大常数。** 不可行，见 Motivation：两个方向互斥。

**只把 worker 栈调大、不改护栏。** 深度能力上不去（护栏才是限制），且 debug 崩溃依旧。

**「栈指针预算 + 失败后换大栈线程重跑」**（另一分支 `perf/stack-safe-executor-reuse` 的方案）。它把栈探针当作「要不要换线程」的判据，要求每条递归路径都有收敛点——而审计表明该前提在 remangler 上有 6 处不成立，实测 release 下 700 层嵌套即崩溃（同输入 main 到 4000 层仍干净返回）。本提案把探针改为「深度上限」的判据，探针漏覆盖时只是保守地早报错，不再是崩溃与否的分界。

**把 printer 改成显式栈迭代**（彻底与线程栈解耦）。收益边际：64MB 已足够任何真实符号，而 printer 带着 `printCache`、`asPrefixContext` 等状态，迭代化出错面远大于收益。留待将来单独评估。

## Future Work

- `Demangler` 的 `setParentForOpaqueReturnTypeNodesImpl` / `demangleBoundGenericArgs` 与 `demangleSwift3*` 环仍是递归。它们在 `demangleAsNode` 内部、因而跑在 worker 上，现实深度下不崩，但失败模式是崩溃而非报错。`Demangler` 是唯一没有 depth 参数的引擎，接护栏要单独引入状态。
- **`TypeBuilder` 在 store 路径上的身份记忆化**：`NodeReference.materializedNode` 每次访问都重建一棵全新的非 interned 树，所以按 `ObjectIdentifier` 记忆化的 builder 会把同一个 decl 重复创建；`decodeMangledTypeDecl` 每层 context 也各 materialize 一次。已在 `DemanglingNode.materializedNode` 的文档里写明「必须按结构做键，不能按身份」，与 printer 的 scope hook 同一条规则。要真正消除需要在引擎里加一层按 store 索引的 materialize 记忆表，本轮未做。
- 同时阻塞的调用方超过突发上限时仍会排队，理论上仍可构造出扇出互锁。已记录在 `StackSafeExecutor` 的类型文档里。
- `NodePrinterTarget.pushTypeReferenceScope` 的 `@autoclosure` 签名是一次**静默**的源码破坏：按旧的 `Node?` 签名实现的富文本 target 编译零警告、文本输出完全正确，但所有 scope 事件静默丢失（协议自带的空默认实现顶上）。Swift 没有诊断近似匹配见证者的机制，已在协议文档里用 `- Important:` 标注。下游 `SemanticString` 需要确认签名已更新。
- 每层探针的单独代价尚未量化（端到端为净改善）。若成为热点，可考虑「按观测到的实际每层开销自适应调整间隔」，而不是回到固定间隔。

## 2026-07-29 修订：撤回 `StackBudget`，回到与上游同构的模型

对首版实现的第二轮满强度 review 确认了五条不可接受的代价，且均为「透明跳线程 + 按栈不按深度」这一形态的固有属性，逐条打补丁不收敛：

1. **LLDB `po` 挂死**：64MB 内联判据让主线程也无条件跳 worker，而调试器表达式求值默认只放行当前线程；
2. **优先级反转**：主线程（USER_INTERACTIVE）在不传递优先级的 `DispatchSemaphore` 上等 USER_INITIATED worker；
3. **`TypeBuilder` 回调换线程**：同步外观下把用户代码移到后台，`@MainActor` 隔离的 builder 在 Swift 6 下崩溃；
4. **栈上限不约束工作量**：移除 remangler 深度上限后，构造符号（约 64KB 的 `Sg` 串）的拒绝代价为 Θ(D_max·N) ≈ 9.5 分钟 CPU，公开入口 `mangleAsString` / `canMangle` 即可触发；
5. **地址空间**：worker 永不退休 + 上限 `max(32, 4×核数)` = 数十条 64MB 栈（watchOS arm64_32 全进程 4GB）。

同日的上游源码调查（`/Volumes/SwiftProjects/swift-project`）证实上游模型就是「8MB 线程 + release 校准的固定常数」：IRGen 注释原话 "Increase the thread stack size on macosx to 8MB … This matches the main thread"；clang 对自家 parser 的机制也是「剩余 < 256KB 就换 8MB 栈」，门槛远低于 64MB。据此裁决（用户决策）：**只保留 main 已有的栈保护形态，常数按 debug 帧实测重定**。

**撤回**：`StackBudget` 类型与每层探针、64MB worker 栈与 64MB 内联判据、`TypeDecoder` 的执行器包装、`NodePrinter.maxPrintDepth` 的 deprecated 标记。

**保留**（首版顺带做出的正确修复）：全部迭代化改写（`hashForNode`、`internTree`、`copy` / `replacingDescendant`、`Rewriter.rewrite`、`description` 转储、`getUnspecialized`、store 侧五条、`deinit` 迭代析构）、线程池（`pthread_create` 检查、槽位清空、autoreleasepool）、printer 复用重置、`withLargeStack`、store 打印不触 `NodeCache` 等。

**新定**：深度上限按 debug、8MB 线程实测崩溃边界取约 30% 余量——printer 768→**512**（实测 725 过 / 745 崩）、remangler 1024→**384**（深度 565 过 / 605 崩；`hashForNode` 迭代化后上限第一次真正可达）、TypeDecoder 1024→**160**（约深度 250 崩）。执行器恢复 2MB 门槛 / 8MB worker；`trySubmit` 的幽灵预约竞态修复（并发提交 + 创建失败可永久挂死调用方，测试可复现）；两个 `printRoot` 私有化、以静态 `print(_:using:)` 为唯一公开打印入口（#12，下游已迁移）。4,522,325 符号语料在新常数下零失配。

最终形态的完整描述见 `Documentations/StackSafety.md`（已重写）。
