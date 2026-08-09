# 文档索引

本目录收录内部专题文档：每篇对应一次实质性的架构演进，或一块独立的子系统。
面向的读者是「不记得本项目任何内部细节」的人，包括几个月后的你自己。

## 先看这个

- [Glossary.md](Glossary.md) — **术语速查**。一句话定义 + 指向详细讲解，读文档卡住时
  用来快速对上号。
- **[Concepts/](Concepts/) — 概念篇**。本库绕不开四块「性能优化背景知识」，没接触过的
  人直接读专题文档会很吃力。每块单独一篇，从零讲起，配真实例子和实测数据：

  | 文档 | 讲什么 | 一句话预告 |
  |---|---|---|
  | [SharedStructureAndDAG.md](Concepts/SharedStructureAndDAG.md) | 共享结构与 DAG | 你以为是树，物理上是图——一半的坑从这里长出来 |
  | [Interning.md](Concepts/Interning.md) | intern 与 hash-consing | 让相同的东西只存一份，内存降到 1/5 |
  | [ArenaStorage.md](Concepts/ArenaStorage.md) | arena 式存储 | 一个 class 节点的 48 字节都花在哪，怎么压到 12 字节 |
  | [TraversalCost.md](Concepts/TraversalCost.md) | 遍历按路径还是按节点计价 | 48 个节点的符号为什么会被访问 13 万次 |
  | [RecursionAndStack.md](Concepts/RecursionAndStack.md) | 递归、线程栈与崩溃 | 主线程 8 MB、协作线程 512 KB，同一段代码换个线程就崩 |

  概念篇讲**通用概念**（读完能迁移到别的项目），下面的专题文档讲**本项目具体怎么做的、
  测出了什么数**。

## 建议阅读顺序

**第一次接触这个库**：先读概念篇的前两篇（[共享结构](Concepts/SharedStructureAndDAG.md)
→ [intern](Concepts/Interning.md)），再看下面的专题。**已经熟悉这些概念**：直接从专题
开始，卡住时回查 [术语速查](Glossary.md)。

1. [SubtreeInterning.md](SubtreeInterning.md) — 内存优化的第一步：把去重做到 class
   形态的极限。
2. [NodeStoreArena.md](NodeStoreArena.md) — 第二步：换存储形态，兑现上一篇结尾列为
   「待将来评估」的 arena 方向。
3. [SpanBorrowedViews.md](SpanBorrowedViews.md) — 第三步：读路径。扫描器字节化、
   借用视图、打印 walk 去 ARC，以及为此引入的双路径门控结构。
4. [StackSafety.md](StackSafety.md) — 与内存方向正交，处理的是递归深度和线程栈。
5. [KnownIssues.md](KnownIssues.md) — 已知问题与 review 裁决记录，随时查。正在处理
   PR #7 的 review 发现时，配套看 [ReviewFindingsPR7.md](ReviewFindingsPR7.md)（未裁决的
   本轮发现清单，闭环后清空）。
6. [MeasurementToolbox.md](MeasurementToolbox.md) — 上面所有实测数字是怎么量出来的；
   自己要跑基准或做验收时先读这篇。

## 专题

| 文档 | 讲什么 | 什么时候读 | 建议先读 |
|---|---|---|---|
| [SubtreeInterning.md](SubtreeInterning.md) | 全子树 interning（hash-consing）。把结构相同的子树收敛成同一个实例，49k 符号语料的解析驻留 39.5 MB → 12.9 MB。 | 想搞清楚 `NodeCache` 为什么存在、`demangleAsNode` 返回的树为什么可以用 `===` 比较时。 | [Interning](Concepts/Interning.md) |
| [NodeStoreArena.md](NodeStoreArena.md) | `NodeStore` arena 式紧凑存储。节点平铺进连续缓冲，每节点 12 字节、无对象头、无引用计数；printer 与 TypeDecoder 泛型化后可零物化直读。 | 做整个二进制的批量索引、或要动 `Store/` 下的代码时。 | [ArenaStorage](Concepts/ArenaStorage.md) |
| [SpanBorrowedViews.md](SpanBorrowedViews.md) | 0008 的实现说明：扫描器改为 `Span<UInt8>` 字节扫描（demangle +21.7%）、免二次校验的文本物化、store 打印 walk 去 ARC（吞吐翻倍，walk 期间 store ARC 恰 1 对）。重点是随之引入的**双轴门控结构**（OS 版本 / 编译器能力）、四条纪律、维护契约，以及「`unowned(unsafe)` 为什么不够」这类只有量了才知道的坑。 | 要动 `Demangler` 扫描器、`Store/` 读路径、或任何 `#available(macOS 26)` / `hasFeature(Lifetimes)` 门控代码时。**新增文本物化点前必读**。 | [ArenaStorage](Concepts/ArenaStorage.md) |
| [StackSafety.md](StackSafety.md) | 栈安全模型：与上游同构的「8MB 大栈 + 固定深度上限」，加上引擎之外全部整树遍历的迭代化（含 `Node` 的迭代式析构）。也记录了曾短暂采用、后因调试器挂死 / 优先级反转 / 工作量不受限而撤回的 `StackBudget` 方案。 | 新增递归、调整深度上限、或排查深符号崩溃时。**动上限前必读**。 | [RecursionAndStack](Concepts/RecursionAndStack.md) |
| [KnownIssues.md](KnownIssues.md) | code-review 的**裁决记录**，两部分：① 已确认真实存在但暂缓修复的 6 条（含复现方式与修法方向）；② 判定为误报或刻意设计的 8 条（N1–N8）。 | 每次 code-review 之前——已裁决且理由仍成立的发现直接跳过，不必重新推导。 | [TraversalCost](Concepts/TraversalCost.md) |
| [MeasurementToolbox.md](MeasurementToolbox.md) | **测量工具箱**：性能/内存结论背后的计量工具（malloc 事件计数 + 大分配阈值、footprint 峰值采样、retain/release interpose 计数）、三级语料、环境开关速查，以及「量错了还不自知」的坑——事件数看不见拷贝成本、同进程第二遍量不到 footprint 尖峰、机器不空闲计时作废（每条都真实踩过）。 | 要给任何改动做性能/内存验收、或复跑历史基准数字时。**跑基准前必读**。 | — |
| [AlignmentGaps.md](AlignmentGaps.md) | 与上游 Swift 编译器 `Demangling` 源码的对齐缺口追踪（基准 `swift-6.3.2-RELEASE`，审计日期 2026-06-20，对照的是 `main`）。 | 跟进上游新增 kind、或排查与官方 demangler 行为不一致时。 | — |
| [ReviewFindingsPR7.md](ReviewFindingsPR7.md) | **临时文件**：PR #7（`feature/node-store`）一轮 `max` 档 review 的 15 条发现，每条带四问答案与修法方向，外加 9 条未验证的补充发现和一份移交清单。开篇的「元模式」一节总结了 6 条发现共有的根因——验证方法对某一类问题结构性失明。 | 接手修 PR #7 的发现时；或想知道「为什么 520 个测试全绿却仍有回归」。**条目闭环后从本文件移除，清空即删档。** | [KnownIssues.md](KnownIssues.md) |

## 其他位置的文档

- **`Evolutions/`** — 演进提案（设计意图 + 决策日志）。上面四篇专题文档是结论，这里是
  过程。状态总表、演进愿景与流程约定见 [`Evolutions/README.md`](../Evolutions/README.md)：

  | 提案 | 一句话 |
  |---|---|
  | `0001-node-store-arena.md` | `NodeStoreArena.md` 的提案原文（Phase 1–4 的分期计划）。 |
  | `0002-stack-safety.md` | `StackSafety.md` 的提案原文，含被撤回的首版方案。 |
  | `0003-review-hardening.md` | PR #6 review 收尾轮：`NodeBuilder` 只交付冻结节点（环从公开 API 不可构造）、整树重建按图计价（保住共享）、`description` 与 Swift runtime 的转储逐字节一致（外加 8MB 输出上限）、移除 `Node: Codable`（序列化就用 mangled string）、让签名近似的 `NodePrinterTarget` 实现变成编译错误。 |
  | `0004-32bit-store-guards.md` | 边界守卫写成 `Int(UInt32.max)` 时，在 watchOS（32 位 `Int`）上会被常量折叠成无条件 trap 而构建全绿；改为异构比较，并加源码扫描测试禁止该写法再进入 `Sources/`。 |
  | `0005-remangler-deepequals-memo.md` | Remangler 替换表的相等比较 `deepEquals` 是四个成对遍历里最后一个没有 memo 的；对两份实例不同但结构相等的共享泛型 DAG，`mangleAsString` 会按路径数（2^N）增长。 |
  | `0006-interntree-and-demangler-postpass-memo.md` | 一批修复四处按路径计价的整树遍历（`NodeCache.internTree`、demangler 的 opaque-return-type 后处理、`findGenericParamsDepth`、`identifier`）——此前一个 131 字符的构造符号就能把默认 `demangleAsNode` 拖到指数级——并附全库横向排查。 |
  | `0007-short-circuit-queries-and-typedecoder-sweep.md` | 补上 0006 横向排查的分类错误：`first(of:)` / `contains(_:)` 是短路查询而非枚举，出现次数不影响答案，却被留在按路径计价上（实测 22 层加倍 DAG 要 18.2 秒，每 2 层 ×4）。同轮补齐 `TypeDecoder` 两处漏扫的越界守卫，并把 PR #6 全部 15 条 review 发现的裁决落到 `KnownIssues.md`。 |
  | `0008-span-borrowed-views.md` | `SpanBorrowedViews.md` 的提案原文（双路径设计、Phase 0 基线与逐阶段验收数字都在其 Decision Log）。 |
  | `0009-swift-syntax-arena-lessons.md` | 对 swift-syntax 最新 arena 实现的对照审读产物：builder 按语料常数预估容量（`reserveCapacity`，增长期 realloc 拷贝 12→4 次全为预留本身、冷启动峰值 footprint 减半）、`NodeIndex` 带 debug 签发 tag（把跨 store 误用从 in-range 静默读错变成 debug 期确定性 trap，release 零成本）；另存档三条记录性结论（合并语义参照、文本直达 arena 的阻塞点、惰性 path 层）。 |
  | `0010-appendable-shared-node-store.md` | 新增 `SharedNodeStore`：长生命周期、线程安全、intern 即发放稳定 `NodeReference` 的共享 arena，取消 freeze 屏障。起因：下游被迫按「每棵树一个小 store」规避，RV 五镜像实测产生 14,451 个 store 实例；实测同负载 store 实例 14,000 → 1。设计详解见 `NodeStoreArena.md` 共享 store 一节。 |
  | `0011-public-transient-demangle-entry.md` | `demangleAsNodeTransient` 撤 `@_spi(Internals)` 转正为 public（一次性 demangle 是下游常态，两仓库五处在用），并以 `TransientRemangleParityTests` 锁死「transient 树与 canonical 树 remangle 输出逐字节一致」——下游生产路径依赖、此前无守卫的隐式契约。 |

- **`AGENTS.md` / `CLAUDE.md`**（仓库根） — 面向编码 agent 的架构速查，信息密度最高、
  最不适合人读；要理解「为什么这样设计」看本目录，要快速查「某个类型的契约是什么」
  看它。
- **`README.md`**（仓库根） — 面向使用者的英文说明与用法示例。
