# 0002 - Stack Safety: Bound Recursion by Remaining Stack, Not by Frame Count

- **Proposal**: 0002
- **Author**: Mx-Iris
- **Status**: Implemented
- **Date**: 2026-07-28
- **Branch**: `feature/stack-budget-guard`（自 `feature/node-store` 切出）
- **Related**: `Documentations/StackSafety.md`（实现说明与实测数据）

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

不属于任何引擎、因此从不在护栏范围内的：`NodeCache.internTreeUnsafe`（每次 demangle 都跑）、`NodeStoreBuilder.internTree`、`Node.==` / `hash(into:)`（公开 API）、`NodeStore.materializeNode`、`NodeReference.structurallyEquals` ×2、`NodeReference.structuralHash`。全部改成迭代。

`NodeStoreBuilder` 那条是审计的盲点：`demangle(_:isType:)` 把 transient demangle 交给 `StackSafeExecutor`，intern 却在返回后跑在调用方线程上（批量索引即 512KB 协作线程）。这是该方法本来就有的形状，但在「支持深嵌套」成为目标后必须堵——改动前实测 debug 500 层崩、release 1200 层崩。

### 4. `Node` 迭代式析构

释放引用类型的树本身就是递归的，且发生在最后一个引用消失处、由运行时执行，**任何引擎侧护栏都覆盖不到**。实测 512KB 线程释放 620 层的树直接崩。

`deinit` 改成把孩子摘进显式工作队列逐个排空，仅在 `isKnownUniquelyReferenced` 为真时拆解，共享子树保持完整。

### 5. worker 栈 8MB → 64MB

线程栈是虚拟地址空间预留，只有写到的页才占物理内存，代价是地址空间而非常驻内存。

### 6. 线程池重做

原来每次调用新建 `Thread` 再 join，实测每次约 41 µs。新池子三条承重性质：worker 不退休（消除「空闲超时退休窗口丢任务」）；池子有上限（`activeProcessorCount`）；worker 绝不等待池子（线程本地标记，嵌套调用内联跑，避免有上限的池子死锁）。队列头指针出队；每个 work item 包 `autoreleasepool`。

### 7. `StackSafeExecutor.withLargeStack(_:)`

对应上游 SourceKit 的 `isStackDeep`：批量场景在最外层包一次，内部全部内联，往返开销归零。

## Impact

- `NodePrinter.maxPrintDepth` 标记 deprecated；`Remangler.maxDepth` / `TypeDecoder.maxDepth` 提高到兜底值。
- 行为变化：以前返回 `<<too complex>>` / `.tooComplex` 的深符号现在多数正常输出。
- `Node.==` / `hash(into:)` 遍历顺序变化（哈希值本就不跨进程稳定）。
- 非 Darwin 平台退化为 unlimited，行为与改动前一致。

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

- `Node.Rewriter.visit` 仍是递归。它是 `open class`，改迭代会改变可重写点语义，需单独评估。
- 每层探针的单独代价尚未量化（端到端为净改善）。若成为热点，可考虑「按观测到的实际每层开销自适应调整间隔」，而不是回到固定间隔。
