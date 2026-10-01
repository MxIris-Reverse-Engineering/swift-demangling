# 0016 - 在 store 上按种类找节点时不碰引用计数

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-10-01
- **最后更新**: 2026-10-01
- **所属愿景**: `Evolutions/README.md` 愿景第 2 条（借用视图把读路径做到零 ARC，0008）
- **关联提案**: [0007](0007-short-circuit-queries-and-typedecoder-sweep.md)（`first(of:)` / `contains(_:)` 的去重遍历）、[0008](0008-span-borrowed-views.md) B2 与 [0010](0010-appendable-shared-node-store.md) 第 3 步（打印走 `UnretainedNodeReference`、入口钉住一次视图）；下游 MachOSwiftSection 提案 `draft-concurrent-definition-printing`（问题在那里暴露）
- **实现分支 / PR**: `perf/unretained-kind-queries`（快进合入 `next`）
- **配套文档**: `AGENTS.md` 的 Traversal 一段

## 摘要

`NodeReference` 是 `{ store: NodeStore, nodeIndex }`，每复制一次都 retain 一次 store。`first(of:)` / `contains(_:)` 的去重遍历（`firstNodeInDedupedPreorder`）每访问一个节点，要压栈一次、取一次 `children`（每个子节点一个 `NodeReference`），再往以 `NodeReference` 为元素的 `Set` 里插一次，全是对同一个 store 对象的原子引用计数。单线程时这些原子操作不互相争抢；下游 RuntimeViewer 用 14 个任务并行打印同一个镜像的定义，所有线程都在给同一个镜像共享的 store 加减引用计数，缓存行在核之间来回搬：SwiftUI 的打印 CPU 时间涨到串行的近 10 倍，墙钟反而比串行慢，热点就在这个遍历里（下游采样：`firstNodeInDedupedPreorder` 之下的样本几乎全来自一个按 conformance 找符号的查询，栈顶是 `swift_retain` / `swift_release`）。打印早就不付这笔钱了：`runPrintWalk` 在入口钉住一次视图，全程走 `UnretainedNodeReference`。本提案让按种类找节点的查询也这样走。

## 方案

- `DemanglingNode` 新增 requirement `firstNodeInDedupedPreorder(matching:) -> Self?`。今天的实现原样作为默认实现（它只用到 `kind`、`children`、`printCacheIdentity`，不需要 `Sequence` 约束）；`first(of:)` / `first(of:...)` / `contains(_:)` / `contains(_:...)` 改为调用这个 requirement。必须是 requirement 而不是 `NodeReference` 上的扩展成员：AGENTS.md 记过三次「按表示优化的扩展成员从泛型上下文调用时从没被派发到」（`print(using:)` → `runPrintWalk`、`hasChildren`）。
- `NodeReference` 的实现：`withExtendedLifetime(store)` + `store.withView` + `withUnsafePointer(to:)`，与 `runPrintWalk` 同一套锚定，在钉住的视图上用原始下标遍历，去重集合存 `UInt32` 下标，只在命中时造一个 `NodeReference` 返回。遍历顺序（先序、子节点从左到右）与去重语义不变，输出不变。
- 不动：`all(of:)`、`filter(of:)`、`preorder()` 一族（按路径枚举，是有意的，KnownIssues N6）；`identifier` 也走去重遍历，但下游采样里不是热点，这次不改，记一笔。
- 测试（`UnretainedKindQueryTests`）：对一组真实符号，在冻结 store 与共享 store 上对每个 `Node.Kind` 问 `first(of:)` 与 `contains(_:)`，答案要与 materialize 出的类树（`Node` 走默认实现）一致，命中的节点与「找不到」都比；0007 的 60 层翻倍 DAG 上的查询要在节点数量级的时间内完成；派发用探针钉住：一个故意让 witness 给出不同答案的最小 conformer，从泛型上下文调用 `first(of:)` / `contains`，必须拿到 witness 的答案。并行收益在下游测：MachOSwiftSection 沙盒里的临时基准（进程内打印 SwiftUI 的全部定义，每个宽度一个新进程），改前改后的墙钟与 CPU 记进决策日志。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-01 | Created as Accepted | 下游 RuntimeViewer 会话报告并行打印比串行慢、并给出采样；在 MachOSwiftSection 的会话里向用户报告根因后，用户选「上游改遍历」（在 swift-demangling 里让 `NodeReference` 的 `first(of:)` / `contains` 改用零引用计数的遍历），并要求先写临时基准、给他看过再跑。 |
| 2026-10-01 | 实现：`firstNodeInDedupedPreorder(matching:)` 升为 `DemanglingNode` 的 requirement，默认实现原样挪到不带约束的扩展里，`NodeReference` 的 witness 放在 `DemanglingNode.swift` 打印路径那一节之后 | 默认实现只用到 `kind`、`children`、`printCacheIdentity`，不需要 `Sequence`；`Node` 与 `UnretainedNodeReference` 照旧用默认实现。派发用探针钉住：一个故意让 witness 给出不同答案的最小 conformer，从泛型上下文调用 `first(of:)` / `contains`，改动前答默认实现的结果，改动后答 witness 的。 |
| 2026-10-01 | 实测：串行快一倍，宽度 4 再快一倍；宽度 14 仍受下游别处的争用限制 | MachOSwiftSection 沙盒里的临时基准（进程内打印 SwiftUI 的 17920 个定义，标记模式、一个共享 printer、`.utility` 有界任务组，每个宽度一个新进程，release，JHs-Mac-Studio-Ultra）。改前：宽度 1 墙钟 37.74 s / CPU 37.77 s；宽度 14 墙钟 329.50 s / CPU 4446 s。改后：宽度 1 墙钟 18.02 s / CPU 18.08 s；宽度 4 墙钟 8.87 s / CPU 26.26 s；宽度 14 墙钟 15.06 s / CPU 165 s。改后在宽度 14 下采样，剩下的争用在下游：`SymbolIndexStore` 每查一个符号都经 `SharedCache` 取一次存储（同一把锁），以及按 conformance 找符号时逐个造 `NodeReference`、retain 同一个 store。本库这边的相关测试（新套件 + DAG、store、共享 store、缺陷回归）全过。 |
| 2026-10-01 | Implemented，编号 0016，快进合入 `next`（不推送、不发版） | 本库全量测试 621 个全过；下游 MachOSwiftSection 用本分支（沙盒里的 `feature/runtime-viewer/find-navigator` 快照）跑全量测试，2168 个全过。合入时机由用户定：「等 MachOSwiftSection 全量测试过了就合入」。下游剩下的争用（按符号逐次经 `SharedCache` 取存储、按 conformance 找符号时逐个造 `NodeReference`）用户选择以后再说，记在 MachOSwiftSection 的 `draft-concurrent-definition-printing` 里。配套文档：`AGENTS.md` 的 Traversal 一段已写明这条 requirement 与 witness，不另写实现说明或指南。新术语：无。 |
