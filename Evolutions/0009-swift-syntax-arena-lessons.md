# 0009 - 借鉴 swift-syntax arena：builder 容量预估与跨 store 误用防护

- **Proposal**: 0009
- **Author**: Mx-Iris
- **Status**: Draft
- **Date**: 2026-08-07
- **Branch**: TBD（未开工）
- **Related**: `Evolutions/0001-node-store-arena.md`（arena 本体；本条缓解其「取舍与
  影响面」记录的跨 store 混用短板，并为其 Phase 4 / 分片合并路线留下参照）；
  `Evolutions/0008-span-borrowed-views.md`（同源审读的另一半：B2 的 unmanaged 句柄
  模式在本条 Motivation 的对照中获得原厂确证）；
  `Documentations/NodeStoreArena.md`（实现说明，落地时同步更新）

## Summary

对 swift-syntax 最新 main 的 arena 三层实现（`BumpPtrAllocator` / `RawSyntaxArena` /
`SyntaxDataArena`）做了一次对照审读。两边根本取向不同——**它是指针基底、不去重、
支持跨 arena 组合与树编辑；我们是索引基底、插入即 hash-consing、冻结后可序列化**
——所以分配器本体不搬，但两条具体改进随本提案落地，三条记录性结论进 Future：

1. **builder 容量预估**（实施）：`NodeStoreBuilder` 增加按预估符号量一次性
   `reserveCapacity` 的入口，用 0001 已量出的语料常数（14.1 字节/唯一节点、37 字节/
   符号）预留三块缓冲与 intern 槽数组，消掉增长期的 realloc 拷贝与「新旧缓冲并存」
   的内存尖峰；配套容量利用率观测口子，供复核常数。
2. **跨 store 误用的 debug 防护**（实施）：`NodeStore.NodeIndex` 在 debug 构建携带
   签发方的随机 generation tag，`reference(at:)` / `intern(kind:children:)` 校验——
   把 0001 记录的「in-range 外来 index 静默读到无关子树」从未定义行为变成 debug 期
   确定性 trap。release 构建零成本、布局不变。
3. **记录性结论**（不实施，防止后人重走）：合并/组合语义的参照（swift-syntax 指针
   稳定所以组合零改写，我们 index 模型合并必须 re-intern——确认 0001 的取舍）；
   「文本从输入区间直达 arena」的阻塞点；下游要父链/路径上下文时的正确形态
   （`SyntaxDataArena` 同构的惰性 path 层）。

## Motivation

### 对照审读的结论（swift-syntax main，2026-08 抓取）

| 维度 | swift-syntax | 本库 `NodeStore` | 可搬性 |
|---|---|---|---|
| 分配 | `BumpPtrAllocator` slab 式 bump 分配（初始 128B/解析 4096B，每 128 块翻倍，超大分配独立 slab） | `ContiguousArray` append（摊销翻倍拷贝） | **不搬**：slab 地址稳定但不连续，会打破平铺 `UInt32` 索引与 0001 Phase 4 的 mmap 序列化；拷贝成本用容量预估消（本提案 A） |
| 节点引用 | 指针（`UnsafePointer<RawSyntaxData>`）+ unmanaged arena 引用 | `UInt32` 下标 | 不搬形态；**搬防护思路**（本提案 B） |
| 去重 | 无（同一 token 文本可多份，仅文本 intern 有 `contains(address:)` 快路径） | 插入即全量 hash-consing | 不搬：去重是本库的产品本身 |
| 跨 arena 引用 | `addChild` 保活子 arena + debug 原子 `hasParent` 防环断言 + `retainedArenaCount` 观测 | 不支持；外来 index 是未定义行为（0001 明示的短板） | **搬防护件**（本提案 B）；`addChild` 所有权模型留作合并路线的参照（Future） |
| 文本 | `internSourceBuffer` 整源预拷进 arena，token 文本 = 指向拷贝的区间，逐 token 零 intern | `textBytes` 按去重表拷贝 | 方向已被 0008 Phase A（words 存区间）吸收；「直达 arena」的完整形态被 `Node.Contents.text(String)` 中间层挡住（Future 记录阻塞点） |
| 派生数据 | `SyntaxDataArena`：`RawSyntax` 共享无父指针，按树另建惰性 data arena（parent 指针 + 绝对位置，原子指针槽双检惰性物化） | 无父指针（hash-consing 使 store 是 DAG，父不唯一，原理上不可能有） | **同构答案留作 Future**：下游要父链就按 root 建惰性 path 层，绝不往 `CompactNode` 塞 parent |
| 容量策略 | `SyntaxDataArena.slabSize(for:)` 按 `totalNodes` 预估初始 slab；`deinit` 留 debug 打印复核估算 | 三块缓冲从零容量翻倍 | **搬**（本提案 A） |
| 零 ARC 遍历 | 公共 `Syntax` 持强 arena 引用；引擎层 `RawSyntaxArenaRef = Unmanaged`，注释原话 "passing around in this form doesn't cause any ref-counting traffic" | 0008 B2 的设计 | 已被 0008 采纳，此处为原厂确证 |

### 为什么 A 值得做

`NodeStoreBuilder` 的三块 `ContiguousArray` 和三张 intern 槽数组全部从小容量起步。
234k 符号语料的终态是 nodes 7.4 MB / edges 0.75 MB / text 0.57 MB / intern 表约
2 MB——从 4 KB 翻倍到 7.4 MB 要经历约 11 次整体拷贝，且每次翻倍瞬间新旧缓冲并存
（峰值 ≈ 2× 当前大小）。批量索引场景（每镜像一个 builder，dyld cache 逐镜像跑）把
这笔开销乘上镜像数。0001 已经量出了稳定的每符号常数，预估入口几乎是白拿的。

### 为什么 B 值得做

0001 「取舍与影响面」原文：外来 index「落在范围内就静默读到无关子树，落在范围外
还可能因为 edges / text 偏移未经边界检查而 trap」。静默读错是三种失败形态里最坏的
（错误数据流向下游，无现场）。多 builder 并存（每线程一个、或 host 同时索引多个
镜像）正是 0001 路线图鼓励的用法，误用面真实存在。swift-syntax 用「引用自带 arena
身份」从形态上排除了这个问题；我们的 index 是裸值，形态上排除不了，但可以在 debug
构建把它变成签发校验的确定性失败——与 0004 的哲学一致：**宁可 debug 期大声失败，
不要 release 期静默读错**。

## Detailed Design

### A. builder 容量预估

```swift
extension NodeStoreBuilder {
    /// Pre-sizes all internal buffers for an expected number of symbols,
    /// using per-symbol constants measured on the dyld-cache corpus
    /// (evolution 0001, Phase 3: ~2.6 unique nodes / ~37 payload bytes per
    /// symbol). One oversized reservation is cheaper than log2(n) regrowth
    /// copies; an undersized one degrades to today's behavior.
    public mutating func reserveCapacity(expectedSymbolCount: Int)
}
```

- 预估常数取自 0001 Phase 3 实测（234k 符号 → 619,688 唯一节点、8.75 MB 平铺、
  intern 表 ~2 MB），换算成 nodes/edges/textBytes/槽数组各自的每符号系数，写成
  **有名常量并在注释里标注来源语料与日期**——将来常数漂移时能对着复核。
- intern 槽数组的预估要同时满足开放寻址的负载因子（现行 3/4 阈值），预留
  `expectedUniqueNodes / 0.75` 向上取整到 2 的幂。
- **观测口子**（借 `SyntaxDataArena.deinit` 的 debug 打印思路，但做成可查询 API
  而不是打印）：

  ```swift
  /// Capacity-utilization report for re-calibrating the reservation
  /// constants; not a hot-path API.
  public var capacityUtilization: NodeStoreBuilder.CapacityUtilization  // used/reserved per buffer
  ```

- `freeze()` 收尾时对 `nodes` / `edges` / `textBytes` 不做 shrink——mmap 序列化
  （Phase 4）落地前，多余 capacity 只活到 builder 生命周期结束，不值得一次拷贝。

### B. 跨 store 误用的 debug 防护（generation tag）

- builder 构造时铸一个随机 `UInt16` tag（每 builder 唯一即可，不要求全局唯一；
  随机源用系统熵，不走 `Math.random` 类可预测源）；`freeze()` 把 tag 传给
  `NodeStore`。
- debug 构建下 `NodeIndex` 携带签发方 tag：

  ```swift
  public struct NodeIndex: Hashable, Sendable {
      let rawValue: UInt32
      #if DEBUG
      let storeTag: UInt16
      #endif
  }
  ```

  校验点两处：`NodeStore.reference(at:)`（现有 bounds precondition 旁）与
  `NodeStoreBuilder.intern(kind:children:)`（现有 child bounds precondition 旁）——
  tag 不符即 precondition 失败，消息指明「index 来自另一个 builder/store」。
- **release 构建布局与行为完全不变**（字段整个不存在）；debug 下 `NodeIndex` 从
  4 字节变 8 字节，只影响持有 index 的下游容器的 debug 内存，可接受。
- Hashable/Equatable 含 tag（debug）：同 store 同 index 恒相等，不受影响；跨 store
  的相等比较本就该失败得更早，语义只紧不松。
- **明示边界**：这是 debug 期的开发错误检测，不是安全边界——release 下外来
  index 的行为与 0001 记录的现状完全一致。`NodeStore.reference(at:)` 与
  `NodeStoreArena.md` 的文档随本条更新措辞。
- 回归测试：debug 专用测试用例，两个 builder 互换 index，`#expect(processExitsWith:)`
  （Swift Testing exit test）断言触发 precondition；release 配置下测试自动跳过。

### C. 记录性结论（不实施）

写进本提案即为存档，防止后人把「没做」误读成「没想到」：

1. **合并/组合**（0001 路线图「分片并行 store 与终态合并」）：swift-syntax 的
   `addChild` 能零改写组合，靠的是指针稳定——index 模型没有这个性质，合并 =
   把一个 store 的树 re-intern 进另一个（索引全部重映射）。将来做合并时，
   `addChild` 的所有权语义（子 arena 被父保活、防环断言）是 API 设计的参照，
   但数据面必须走 re-intern，没有捷径。
2. **文本直达 arena**：`internSourceBuffer` 的「整源预拷贝、文本零 intern」在
   我们这里的完整形态是 `internText` 直接收输入字节区间——被
   `Node.Contents.text(String)` 中间层挡住（transient 树必然物化 String）。解锁
   它要么 demangler 直写 arena（0001 已否，576 处构造点），要么给 payload 加
   text-ref 变体（新的复杂度）。在 0008 Phase A（words 存区间）+ B3（internText
   去 Array 物化）落地后，剩余收益是每个带文本节点一次 String 物化，是否值得
   动 payload 等 Phase 0 基准数据说话。
3. **惰性 path 层**：`RawSyntax` 无父指针与我们 store 无父指针是同构处境
   （共享/hash-consing 使父不唯一）。swift-syntax 的答案是按树另建
   `SyntaxDataArena`（parent 指针 + 位置信息，原子指针槽双检惰性物化）。下游
   （RuntimeViewer 树 UI、MachOSwiftSection outline）将来要「从某个 root 出发的
   父链/路径上下文」时，正确形态就是按 root 建惰性 path arena——**绝不**往
   12 字节 `CompactNode` 塞 parent（会毁掉去重：同一子树在不同父下不再相等）。

## Source Compatibility

- 新增 API：`reserveCapacity(expectedSymbolCount:)`、`capacityUtilization`（public，
  builder 侧）；均为纯增量。
- `NodeIndex` 的 debug 字段不改 release 布局；`NodeIndex` 目前不参与任何序列化
  （Phase 4 未落地），无持久化兼容问题。debug/release 混用同一进程不可能（同一
  module 单次编译），无跨配置布局风险。
- deployment target、编译器要求均不变（本条不依赖 Span/实验特性，与 0008 正交，
  可独立先行）。

## Impact（库 / 源码分发）

- **源兼容性**：纯增量，既有调用零变化。
- **ABI 兼容性**：不适用（纯 SPM 源码分发）。
- **下游影响**：MachOSwiftSection 的批量索引管线可选采用 `reserveCapacity`（每
  镜像符号数已知，正好是预估入口的形状）；generation tag 对正确使用方不可见，
  对误用方是 debug 期新增的 trap——这是行为收紧，随版本说明明示。

## 验收标准

- **A**：234k 语料构建，对比预估 vs 不预估：realloc 次数（malloc hook 计数）、
  构建耗时、峰值常驻（`peak footprint`）三项，数字回填决策日志；预估路径的
  `capacityUtilization` 各缓冲利用率 ≥ 50%（常数校准合格线）。
- **B**：debug 下跨 builder 误用测试触发 precondition（exit test）；release 下
  行为与现状逐字节一致；全量 corpus 测试在 debug 配置跑通（确认 tag 校验无
  误伤）。
- 既有全部测试（对齐 oracle、`DefectRegressionTests`）双配置全绿。

## Alternatives Considered

1. **搬 `BumpPtrAllocator` slab 分配器**——否。slab 化后地址稳定但不连续：
   平铺 `UInt32` 索引要变 (slab, offset) 二级寻址（每次节点访问多一次间接），
   Phase 4 的「三块缓冲直接 mmap」变成逐 slab 重组。连续缓冲是本库相对
   swift-syntax 模型的立身之本，翻倍拷贝的实付成本用容量预估（A）消到可忽略。
2. **release 也带 generation tag**——否。`NodeIndex` 从 4 字节涨到 8 字节（或
   挤压 `rawValue` 位宽牺牲容量上限），为的是拦一类开发期错误，不成比例；
   swift-syntax 的对应断言（`hasParent`）同样只在 DEBUG/断言构建生效。
3. **`NodeIndex` 改为携带 store 弱引用的自校验句柄**——否。那就是把
   `NodeReference` 复制一遍；`NodeIndex` 的存在意义就是 4 字节裸值（字典键、
   批量数组），加引用等于取消这个类型。
4. **用 `contains(address:)` 式的范围校验代替 tag**——否。外来 index 的危险
   形态恰恰是 in-range（0001 原文），范围校验拦不住它；swift-syntax 的
   `contains` 服务的是文本 intern 快路径，不是误用防护。

## Future Directions

- 合并 API（分片并行 store 的终态合并）：设计时参照 `addChild` 的所有权与防环
  语义，数据面走 re-intern（见 C.1）。
- text-ref payload 变体解锁「文本直达 arena」（见 C.2，等 0008 Phase 0 数据）。
- 按 root 的惰性 path 层（见 C.3，等下游真实需求触发）。

## Decision Log

| 日期 | 决定 | 依据 |
|---|---|---|
| 2026-08-07 | Created as Draft | 起因：对 swift-syntax 最新 main 的 arena 实现（`BumpPtrAllocator` / `RawSyntaxArena` / `SyntaxDataArena`）做对照审读；review 指示把可借鉴项从 0008 拆出独立成案。审读的完整对照表见 Motivation；0008 B2 的 unmanaged 句柄模式在同一次审读中获得原厂确证（`RawSyntaxArenaRef = Unmanaged` + 公共层持强/引擎层零 ARC 的分层）。 |
