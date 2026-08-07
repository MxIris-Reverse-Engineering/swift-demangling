# Evolution 提案

- **项目类型**: 库（源码分发）

本目录是全部演进提案的所在地：一次实质改动一份提案，从调研到落地原地更新，被否的
保留（它是「当初为什么没这么做」的唯一记录）。结论性的专题文档在
[`Documentations/`](../Documentations/README.md)；这里是过程与决策。

## 愿景

这个库的本职从「demangle 一个符号」演进为「把整个二进制 / dyld cache 的符号世界
装进内存、再落到磁盘」。四条主线，排名有先后——第 1 条是其余一切的前提：

1. **正确性与上游对齐（持续，不可让步）**。输出与 Swift 官方 demangler 逐字节对齐
   （全量 dyld cache corpus oracle），`Node.Kind` 跟进 Apple 工具链演进（缺口追踪
   在 `Documentations/AlignmentGaps.md`）。每一条优化提案的验收标准里都有「产出逐字节零差异」
   ——性能与内存的所有收益，都不允许用输出偏差换。
2. **内存形态：从对象树到符号数据库（0001 → 0008 → 0009 → Phase 4）**。已走过的
   路：class 树（48 字节/节点、逐节点 malloc）→ 全子树 interning（驻留 ÷3，0001 的
   前置）→ arena 平铺（12 字节/节点、`UInt32` 互指，0001）。正在走的路：借用视图
   （读路径零 ARC、扫描器字节化，0008）与 builder 加固（0009）。终点：三块连续
   缓冲直接二进制序列化 / mmap 加载（0001 Phase 4）——解析一次 dyld cache，此后
   所有进程 mmap 共享同一份符号数据库，加载接近 memcpy 量级。分片并行构建与终态
   合并（0009 C.1 留有设计参照）是同一终点的横向扩展。
3. **计价纪律与健壮性（0002–0007 确立，此后是回归约束）**。两条来之不易的纪律：
   **遍历按节点数计价，不按路径数**——interning 与替换反向引用使一切树都是 DAG，
   无 memo 的遍历对合法输入就是指数级（一个 131 字符的构造符号曾把默认入口拖到
   挂死）；**递归要么收敛到深度计数的入口、要么迭代化**——深符号在 512 KB 协作
   线程栈上爆栈是真实事故形态。这条线的产出不是某个修复，而是纪律本身 + 永久
   回归测试（`DefectRegressionTests`、corpus oracle、call-graph 审计流程）；新代码
   违反纪律应当在 review 与测试两层被拦下。
4. **API 演进：稳定的公共面，渐进吸收新语言能力**。公共 API 的不变量：String 入口、
   `Node` / `NodeReference` 双表示同一套引擎、闭包式借用是永远存在的基线。新语言
   特性（`Span` 家族、lifetime 标注、borrow accessors、`UniqueArray`、`Iterable` /
   `Ref`）按 0008 确立的双轴门控吸收：OS 版本用 `#available` 双路径，编译器能力用
   `hasFeature` 条件编译，实验期 API 一律圈在 `@_spi(Internals)`——工具链到位时
   换门控条件，不换架构。

## 提案总表

| # | 标题 | 状态 |
|---|---|---|
| [0001](0001-node-store-arena.md) | NodeStore: Arena-Based Compact Node Storage | Implemented（Phase 1–3；Phase 4 平铺序列化推迟） |
| [0002](0002-stack-safety.md) | Stack Safety: Bound Recursion by Remaining Stack, Not by Frame Count | Implemented（2026-07-29 修订：`StackBudget` 撤回，回到固定深度上限 + 8MB 大栈） |
| [0003](0003-review-hardening.md) | Review Hardening: 冻结移交的 NodeBuilder 与按图计价的整树遍历 | Implemented |
| [0004](0004-32bit-store-guards.md) | 32-bit 可移植性：Store 越界守卫在 watchOS 上被折叠成无条件 trap | Implemented |
| [0005](0005-remangler-deepequals-memo.md) | Remangler 替换表相等比较补 proven-pair memo | Implemented |
| [0006](0006-interntree-and-demangler-postpass-memo.md) | 按路径计价的整树遍历：`internTree` 等四处补 memo/去重 + 横向排查收口 | Implemented |
| [0007](0007-short-circuit-queries-and-typedecoder-sweep.md) | 短路查询去重 + TypeDecoder 漏扫守卫补齐 | Implemented |
| [0008](0008-span-borrowed-views.md) | Span 借用视图：扫描器 UTF-8 字节化与 store 读路径去 ARC（双路径） | In Progress |
| [0009](0009-swift-syntax-arena-lessons.md) | 借鉴 swift-syntax arena：builder 容量预估与跨 store 误用防护 | Draft |

## 流程

- **状态机**：`Draft` → `In Review` → `Accepted` → `In Progress` → `Implemented`；
  另有 `Rejected` / `Deferred` / `Withdrawn`。实现代码在提案进入 `Accepted` 之前
  不得开始。
- **一次改动 = 一份提案文件**：不拆 design / plan / report 多份文档；随实现推进
  原地更新状态与内容，重大转向记入文内决策日志（如 0002 的修订）。
- **提案与代码同批次提交**：状态更新与实现代码进同一个 commit / PR。
- **编号与命名**：`NNNN-kebab-case-slug.md`，编号连续；新提案落地时同步更新本表
  与 [`Documentations/README.md`](../Documentations/README.md) 的提案索引。
