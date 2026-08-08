# 0010 - 可增量共享 interning store：取消 freeze 屏障的长生命周期 NodeStore

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-08-08
- **最后更新**: 2026-08-08
- **所属愿景**: 无（隶属 `Evolutions/README.md` 愿景第 2 条「内存形态」主线：0001 → 0008 → 0009 之后，面向动态构建场景的下一步）
- **关联提案**: [0001](0001-node-store-arena.md)（arena 模型与 freeze 语义）、[0008](0008-span-borrowed-views.md)（读路径去 ARC——本提案的性能回归门槛）、[0009](0009-swift-syntax-arena-lessons.md)（容量预估与签发 tag——共享 store 直接复用）
- **实现分支 / PR**: 待定
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

新增公开类型 `SharedNodeStore`：一个**长生命周期、线程安全、可持续 intern** 的共享
arena——`intern(_:)` / `demangle(_:)` 即时返回永久有效的 `NodeReference`，没有
`freeze()` 屏障。它服务的是现有 `NodeStoreBuilder` 一次性 build→freeze 模型接不住的
**增量负载**：下游（MachOSwiftSection / RuntimeViewer）在用户浏览过程中持续发现新
类型名、扩展名、晚到符号，目前只能按「每棵树铸一个私有小 store」规避，实测一次五
镜像索引产生 **14,451 个 `NodeStore` 实例**。本提案落地后这些小 store 全部汇入每
镜像一个的共享 store：固定开销消失、公共子树跨名字去重、名字相等比较从整树遍历降
到同 store index 比较。冻结式 `NodeStoreBuilder` → `freeze()` 工作流保持不变，仍是
批量 sweep 的首选。

## 动机

### 下游的真实负载是增量的，库只提供了一次性的 build→freeze

`NodeStoreBuilder` 是 `~Copyable`，`freeze()` 是 `consuming` 的一次动作
（`Sources/Demangling/Store/NodeStoreBuilder.swift:186`）：冻结之前拿不到可读的
`NodeReference`，冻结之后不能再 intern。这个模型完美匹配「符号表全量 sweep」——
输入集合在开工前已知。但下游第二类负载的输入集合**在浏览过程中才逐步出现**：

- 用户展开一个类型 → 需要它的 `TypeName`（由 `MetadataReader` 的树构造）；
- 索引器解析 conformance / extension / 嵌套关系 → 每一步都产出新的名字树；
- sweep 之外晚到的符号名需要按需 demangle。

这类负载需要「intern 一棵树，**立刻**拿到一个可长期持有的引用，之后还能继续
intern」。库里唯一能做到的入口是 `NodeReference(interning:)`——而它**每次调用铸一个
私有小 store**（`Sources/Demangling/Store/NodeReference.swift:84`，文档明示这是
one-off 工具，不适合批量）。

### 规避的代价已在真实场景量化

MachOSwiftSection（`feature/node-store-migration` 分支）被迫建了三条小 store 流水线：

1. `Sources/MachOSymbols/InternedNodeReferenceCache.swift` —— 名字树按结构哈希去重
   后，每棵唯一树仍经 `NodeReference(interning:)` 铸一个小 store。其文档注释原文
   承认「upstream documents it as the wrong tool for a batch」，并量得 fixture 上
   730 个小 store 只承载 472 棵唯一树；
2. `Sources/SwiftDeclaration/Components/Definitions/TypeDefinition.swift:164` ——
   每个类型的字段树一个 builder→freeze 小 store；
3. `Sources/MachOSymbols/SymbolIndexStore.swift:260`（`lateDemangledNode`）——
   每个晚到名字一个小 store（并发竞态下败者的小 store 直接丢弃）。

RuntimeViewer 索引 Foundation + libswiftCore + AppKit + SwiftUI + SwiftUICore 五个
镜像后的 memory graph（2026-08-08 实测）：**`NodeStore` 实例 14,451 个**（意图形状
是每镜像一个，即 5 个）。三重代价：

- **固定开销 ×14k**：每个小 store 是 1 个类实例 + 3 块缓冲存储；本库文档已有的
  实测（`AGENTS.md` Store 节）：300 个引用、3 个唯一符号，走小 store 是 59,700
  字节私有内存，走共享 arena 是 541 字节——**110 倍**；
- **跨 store 零去重**：hash-consing 只在单个 store 内生效，Foundation / stdlib
  公共子树在每个小 store 里各存一份；
- **相等比较退化**：`NodeReference` 固有 `Hashable` 按 store 身份，跨 store 的名字
  比较只能走整树结构遍历。下游 `TypeName` 为此手写了结构化 `==` / `hash`，其注释
  明确期待「equal names share one store … name equality drops from a full tree
  walk to an index compare」——库侧缺口不补，这个 fast path 永远点不着。

### 为什么是现在

0009 落定后，序列化 / mmap（0001 Phase 4）被维护者明确暂缓（「现阶段都是动态构建
的」，2026-08-08）。动态构建场景下经排查仅剩的两条结构级优化里，本提案是
收益/成本比更高的一条（另一条是分片并行构建，见 Future Directions）。

## 前期调研

- **现状代码怎么走的**：
  - `NodeStoreBuilder.freeze()` 为 `consuming`，冻结时丢弃 intern 槽表，仅三块
    平铺缓冲进入 `NodeStore`（`NodeStoreBuilder.swift:186` 起）；
  - `NodeStore` 为 `public final class`、全 `let` 存储、`Sendable`
    （`NodeStore.swift:12`）；`NodeReference` 16 字节句柄，内部持有 `NodeStore` +
    `NodeIndex`，同 store 相等 = index 相等（O(1)），跨 store 走结构遍历；
  - `NodeReference(interning:)` 每调用一个私有 mini store，文档已警告不适合批量；
  - 0009 已落地：`reserveCapacity(expectedSymbolCount:)`（语料标定常数）、
    `capacityUtilization`、debug 签发 tag（`NodeIndex.storeTag`，跨 store 误用
    debug 期确定性 trap）。
- **结构不变量（本设计的安全性支点）**：arena 按**自底向上**hash-consing——子节点
  先于父节点 intern，interior key 以子节点已规范化为前提按索引比较（0001 设计，
  0009 提案正文复述）。因此**从任意 root 引用出发可达的全部索引 ≤ root 自身的
  索引**。这使「旧视图」天然安全：只要视图覆盖到 root 的索引，整棵子树都在
  视图内。落地时以 debug 断言把该不变量钉进 `intern(kind:children:)`。
- **上游或依赖是否已具备能力**：`SwiftStdlibToolbox.Mutex` 已是本库共享可变状态的
  既定形态（`NodeBuilder` / `NodeCache` 均用它）；无需新依赖。
- **前人怎么做的**（0009 对照审读已存档）：swift-syntax `RawSyntaxArena` 用
  slab 分配保证地址稳定（存活数据永不搬家），`SyntaxDataArena` 用原子指针槽
  双检惰性发布只读层——「写侧加锁、读侧原子发布、已发布数据不可变」正是本设计
  的读写纪律来源。区别：swift-syntax 以指针为引用故必须 slab；本库以索引为引用，
  搬家不改索引，故可以「按倍增长 + 旧缓冲退休保活」保住**连续缓冲**这一读路径
  根基（0009 Alternatives 第 1 条否掉 slab 的理由在读路径上依然成立）。
- **验证过什么**：
  - 每符号 ~110 次瞬态分配、store 本体预留后整遍构建仅 4 次大分配（0009 验收
    数据）——增量场景的分配热点同样在 demangle 侧，intern 临界区本身是微秒级，
    单把 Mutex 串行化 intern 不构成吞吐瓶颈（RV 的增量负载是零星到达，不是
    满速批量）；
  - 已证伪的捷径——**COW 快照式发布**（每次 intern 后 `NodeStore` 快照共享
    builder 缓冲）：快照本身 O(1)，但 builder 下一次 append 触发 COW 全量拷贝，
    「intern 一个名字→读一次」的典型交错下退化为每 intern 一次全缓冲 memcpy，
    O(n²) 字节搬运，14k 唯一名字 × 平均数 MB 缓冲 = 数十 GB 级拷贝。不可行，
    这解释了方案为什么必须走「原地增长 + 退休保活」而不是快照。

## 提议方案

新增 `SharedNodeStore`（`Sources/Demangling/Store/`）：

- **一个 scope 一个实例**（下游按镜像 / 进程建），生命周期内可无限次
  `intern(_:)` / `demangle(_:)`，**即时**返回 `NodeReference`；引用永久有效
  （store 存活期内），可跨线程持有、可作字典键；
- **写侧**：一把 `Mutex` 串行化全部 intern；内部复用 `NodeStoreBuilder` 的全套
  intern 机制（哈希槽表、0009 容量预估、签发 tag），槽表**永不丢弃**（这正是
  持续去重的来源，与 freeze 丢表相反）；
- **读侧**：三块缓冲保持**连续**；增长采用「新缓冲倍增 + memcpy + 原子发布 +
  旧缓冲退休保活」——读者按 walk 粒度钉住一份视图（三个基址 + 属主），旧视图
  因退休保活而永久有效，配合「子索引 ≤ root 索引」不变量，陈旧视图读任何已
  发出的引用都完整且正确。读热路径与冻结 store **逐指令等价**（连续缓冲 +
  索引寻址，无分块间接层）；
- **退休浪费有界**：倍增序列的退休缓冲总和 ≤ 当前缓冲一倍；配合 0009 的
  `reserveCapacity` 预留，常态下增长次数为个位数、浪费趋近于零；
- **去重语义**：结构相等的树 intern 返回相同 index → 相同 `NodeReference` →
  现有 `Hashable`（store 身份 + index）直接正确工作。下游的结构哈希缓存层
  （`InternedNodeReferenceCache`）整体退役为一次 `sharedStore.intern(tree)`。

冻结式 `NodeStoreBuilder` → `freeze()` 完全不动：批量 sweep（输入集合已知）继续
走它——freeze 丢槽表、无锁读、无退休链，仍是该场景的最优形态。

### 非目标

- **不做序列化 / mmap**（0001 Phase 4，维护者已明确暂缓）；本设计不为其设障——
  共享 store 的缓冲随时可按当前长度拷出一份冻结 `NodeStore`；
- **不做并行 intern 优化**：单 Mutex 串行；满速并行批量构建的答案仍是分片
  builder + 终态合并（0009 C.1），不归本提案；
- **不做淘汰 / 收缩**：共享 store 只增不减，与 `NodeCache` 同型；内存回收的
  单位是 store 整体随 scope 释放（下游 SharedCache 的 per-image 驱逐模型正好
  是这个形状）；
- **不改冻结路径**：`NodeStoreBuilder` / `freeze()` / 冻结 `NodeStore` 的行为、
  性能、API 均不变；
- **不替代全局 `NodeCache`**：class `Node` 路径的 interning 语义不动。

## 详细设计

### 公开 API

```swift
/// A long-lived, thread-safe interning arena: `intern`/`demangle` hand out
/// permanently valid `NodeReference`s immediately — no freeze barrier.
/// One instance per scope (per image, per process); memory is reclaimed by
/// releasing the whole store.
public final class SharedNodeStore: Sendable {
    public init()

    /// Pre-sizes buffers and interning tables (proposal 0009 coefficients).
    /// The coefficients are calibrated per *symbol*; for name-tree workloads
    /// they overshoot, which is the safe direction.
    public func reserveCapacity(expectedSymbolCount: Int)

    /// Interns a `Node` tree; structurally equal trees return the same reference.
    public func intern(_ tree: Node) -> NodeReference

    /// Cache-free demangle straight into the arena (transient parse + intern),
    /// mirroring `NodeStoreBuilder.demangle`.
    public func demangle(
        _ mangled: String,
        isType: Bool = false,
        symbolicReferenceResolver: SymbolicReferenceResolver? = nil
    ) throws(DemanglingError) -> NodeReference

    /// Buffer/table utilization for coefficient re-calibration (proposal 0009).
    public var capacityUtilization: NodeStoreBuilder.CapacityUtilization { get }
}
```

`NodeReference` 类型不变、不新增变体——下游既有的属性类型
（`TypeName.node: NodeReference` 等）零改动。

### 内部结构

```
SharedNodeStore
 ├─ writerState: Mutex<WriterState>        // 全部 intern 走这里
 │    └─ WriterState: intern 槽表 + uniqueTexts 表 + 各缓冲 count（复用
 │       NodeStoreBuilder 的机制；不同点：永不 freeze、槽表永不丢弃）
 └─ readableStore: NodeStore               // 引用们持有的那个身份锚
      ├─ viewDescriptor（原子发布）: 三个 (基址, 属主) 视图
      └─ retiredBuffers: 退休缓冲保活链（只在增长时追加）
```

- `NodeReference.store` 指向 `readableStore`——一个 `SharedNodeStore` 只有一个
  `NodeStore` 身份，同 scope 全部引用的 `store ===` 成立，index 比较 fast path
  全量生效；
- 缓冲存储从 `ContiguousArray` 改为**自管理缓冲对象**（`final class`，持
  capacity/count/裸指针，`deinit` 释放）。冻结路径同步切换到同一机制——
  `freeze()` 从「移动数组」变为「移交缓冲所有权」，行为不变、免一次拷贝；
- **增长协议**（写者持锁）：分配新缓冲（倍增）→ memcpy → 将旧缓冲加入退休链
  → release 语义发布新视图描述符。**已发布的元素只写一次、发布后不可变**；
- **读取协议**：walk 入口（printer 的 `UnretainedNodeReference` 锚、
  `structurallyEquals` 等成对遍历、`Sequence` 遍历）以 acquire 语义读一次视图
  描述符并钉住整个 walk；零散单点访问（`kind` / `children[i]`）每次 acquire 读
  描述符。正确性论证：引用跨线程移交本身建立 happens-before，接收方读到的
  视图必然覆盖该引用的 index；即使读到更旧的视图，只要覆盖 root index，
  「子索引 ≤ root 索引」不变量保证整棵子树可达（不变量以 debug 断言钉在
  `intern(kind:children:)`）；
- **0009 tag**：`SharedNodeStore` 持一个签发 tag（沿用 builder 铸 tag 机制），
  debug 下跨 store 误用照常 trap；release 布局照常不变；
- **Atomics 可用性**：视图描述符的原子发布在 macOS 10.15 部署下限内实现
  （`ManagedAtomic` 级别的原语或 `os_unfair_lock` 保护的指针槽——描述符切换
  仅发生在增长时，频率极低，实现取锁也不构成热点；具体拼写落地时定，验收
  以 TSan 与性能门槛说话）。

### 数据流示例（下游迁移后）

```swift
// MachOSwiftSection：每镜像一个共享 store
let imageNameStore = SharedNodeStore()
imageNameStore.reserveCapacity(expectedSymbolCount: estimatedNameCount)

// TypeName 构造（原 InternedNodeReferenceCache.reference(interning:) 全路径）
let typeNameReference = imageNameStore.intern(try MetadataReader.demangleContext(...))

// 晚到符号（原 lateDemangledNode 的 builder-per-name）
let lateReference = try imageNameStore.demangle(lateSymbolName)

// 字段树（原 TypeDefinition 的 per-type builder→freeze）
let fieldTypeReference = imageNameStore.intern(try record.demangledTypeNode(in: machO))
```

三条流水线共用一个 store：名字、字段、晚到符号的公共子树互相去重；
`TypeName` 的 `==` 退回固有 `Hashable`（同 store index 比较）。

## 替代方案考量

1. **COW 快照发布**（每次 intern 后发布共享缓冲的 `NodeStore` 快照）——否。
   典型「intern→读」交错下每次 intern 触发 COW 全量拷贝，O(n²) 字节搬运
   （前期调研有量化）。
2. **分块（slab）缓冲**——否（v1）。地址稳定、无退休浪费，但每次节点访问多一层
   `(chunk, offset)` 间接寻址，命中的是 0008 刚清干净的最热读路径；文本 / 边表
   跨块还需拆段逻辑。0009 Alternatives 第 1 条否 slab 的理由（连续缓冲是本库
   相对 swift-syntax 模型的立身之本）在读侧原样成立。退休保活的浪费上界（≤1×，
   预留后趋近 0）远好于为它引入间接层。若将来实测退休浪费成为问题，slab 是
   已存档的后路。
3. **每次访问加锁**——否。读是热路径，walk 内逐节点取锁的代价不可接受；
   本设计读侧无锁（钉视图后纯指针读）。
4. **不动库，下游把小 store 铸得更粗**（按批次合并名字）——否。名字到达是
   零星的，批次凑不齐；且无论批多粗，跨 store 去重和 index 比较 fast path
   依然缺失——缺口在库的模型里，不在下游的用法里。
5. **freeze-重建纪元**（攒一批 → 重建更大的 store → 全量 re-intern）——否。
   总代价 O(n²) re-intern；且旧纪元引用指向旧 store，要么失效要么继续堆积
   store 实例，问题原样回来。
6. **给 `NodeStoreBuilder` 加非 consuming 的 `snapshot()`**——否。这就是方案 1
   的 API 拼写，同一个 O(n²) 拷贝。

## 影响

### 源码兼容性（source compatibility）

**纯新增**。新公开类型 `SharedNodeStore`；`NodeStore` / `NodeStoreBuilder` /
`NodeReference` 的公开 API 不变。内部存储从 `ContiguousArray` 换为自管理缓冲
属实现细节，对外不可见。`NodeReference(interning:)` 保留不废弃（单棵树的
one-off 场景仍然合法），文档补充指向 `SharedNodeStore` 的批量指引。

### ABI 兼容性（条件项）

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- 本仓库内：`Demangling` 单 target，新增文件于 `Sources/Demangling/Store/`。
- **MachOSwiftSection**（`feature/node-store-migration`）：主要受益方。三条小
  store 流水线（`InternedNodeReferenceCache` 全类、`TypeDefinition` 字段
  builder、`lateDemangledNode`）迁移为每镜像共享 store；迁移属该仓库自己的
  提案范畴，本提案落地后另行通知（已于 2026-08-08 预告其会话）。
- **RuntimeViewer**（`next`）：无需配合改动；验收用它的 memory graph 复测。

### 文档与示例

- `Documentations/NodeStoreArena.md`：新增共享 store 一节（两种构建模型的分工、
  读写协议、退休保活语义）；
- 仓库根 `README.md`：增量场景示例（与批量 sweep 示例并列）；
- `AGENTS.md`：Store 要点补充；
- `Documentations/Glossary.md`：登记「视图钉扎（view pinning）」「退休缓冲
  （retired buffer）」。

## API 演进与废弃策略

- 无被替代的公开 API。`NodeReference(interning:)` 保留（one-off 合法用途），
  仅文档分流；不加 deprecated 标注。
- 无需 semver major。

## 落地步骤

每步可独立构建、独立验收：

1. **缓冲引擎替换**（行为不变）：builder 三块平铺缓冲 + 冻结 `NodeStore` 存储
   从 `ContiguousArray` 迁到自管理缓冲对象；`freeze()` 变为所有权移交。
   门槛：全量测试双配置绿；0008 / 0009 基准套件与迁移前逐项持平（噪声带内）。
2. **不变量断言**：「子索引 ≤ 父索引」debug 断言进 `intern(kind:children:)`，
   全量 corpus（debug 配置）验证零触发。
3. **读侧视图化**：`NodeStore` 读路径经视图描述符取基址（冻结 store 视图恒定，
   等价常量折叠）。门槛同步骤 1。
4. **`SharedNodeStore` 本体**：写锁 + 增长退休协议 + 原子发布 + tag；
   单元测试（结构相等去重、引用跨增长存活、`capacityUtilization`）、
   并发压力测试（并发 intern × 并发 walk，TSan 全绿）、debug tag exit test。
5. **基准与验收数字回填**：新增增量场景基准（N 个唯一名字：`SharedNodeStore`
   vs N 个 mini store，比内存与耗时）；RV 实景复测 memory graph，`NodeStore`
   实例数回填决策日志。
6. **文档批次**：影响节所列四处 + Glossary，与代码同 commit。

**验收标准**：

- 正确性：共享 store 打印输出与 `Node` 路径逐字节一致（既有 parity 机制扩展
  覆盖）；corpus oracle、`DefectRegressionTests` 双配置全绿；TSan 并发套件绿。
- 性能：0008 打印吞吐基准、0009 构建基准与 main 持平（噪声带内）——冻结路径
  不许为共享路径买单。
- 内存：RV 五镜像实景 `NodeStore` 实例数 14,451 → ≤ 10；增量基准的每唯一树
  内存开销相对 mini store 方案下降一个数量级（对照既有 110× 数据点）。

**收尾判断**（写进决策日志，不许沉默跳过）：配套文档——预计需要
`NodeStoreArena.md` 扩节（实现说明性质）；若「walk 钉视图」对 SPI 深度消费方
（MachOSwiftSection 富 target）构成从签名看不出的契约，则补使用指南。新术语——
「视图钉扎」「退休缓冲」入项目术语表。

## Future Directions

- **分片并行构建 + 终态合并**（0009 C.1）：与本提案正交——那是满速批量场景的
  墙钟优化，本提案是增量场景的形态修复；合并语义的 re-intern 路线不变。
- **共享 store 的冻结导出**：`SharedNodeStore` 按当前长度拷出一份冻结
  `NodeStore`——若将来 Phase 4（序列化）解冻，这是增量构建结果落盘的天然接口。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-08 | Created as Draft | 起因：RV 五镜像 memory graph 实测 14,451 个 `NodeStore` 实例（意图形状为 5 个）；排查确认下游三条小 store 流水线均为对「freeze 屏障 + `NodeReference(interning:)` 每调用一 store」这一库侧缺口的规避。序列化方向被维护者暂缓后，本提案为动态构建场景仅剩两条结构级优化中收益/成本比更高的一条。 |
| 2026-08-08 | Draft → Accepted → In Progress | 维护者审核通过（与 0011 同批批准），按落地步骤 1–6 顺序实现。 |
| 2026-08-08 | 步骤 1 落地：缓冲引擎替换 | 三块平铺缓冲从 `ContiguousArray` 迁到自管理 `StoreBuffer`（final class，`deinit` 释放）+ builder 侧 `GrowableStoreBuffer` 门面；`freeze()` 变为所有权移交。读侧越界语义保持（显式 precondition 对齐原数组下标的 release trap）；`withSpans` 的 0008 双路径收敛为单路径（`UnsafeBufferPointer.span` 全运行时可用）。**验收**：506 测试双路径全绿；interning 结果逐字节一致（uniqueNodes=1,267,380、storageBytes=17,863,543 与基线完全相同）；吞吐持平或更优（store-print default 116,827→129,142 sym/s，store-build 43,604→45,098 sym/s，demangle 持平）；0009 预留性质完好且更紧（单进程对测：reserved 冷启动 9.0 MiB < unreserved 11.5 MiB，大分配 4 < 13 次；nodes 预留利用率 73%→96%——精确容量分配替代了 `ContiguousArray` 的 malloc 桶取整）。**两处已记录的行为注脚**：`NodeReference.textUTF8` 从零拷贝切片变为拷贝桥（该 API 自 0008 起即标注「新代码请用借用形式」，字节语义不变）；`CompactNode` 显式声明 `BitwiseCopyable`（`@usableFromInline` 类型不参与自动推断）。 |
