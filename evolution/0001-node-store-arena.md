# 0001 - NodeStore: Arena-Based Compact Node Storage

- **Proposal**: 0001
- **Author**: Mx-Iris
- **Status**: In Progress
- **Date**: 2026-07-23
- **Last Updated**: 2026-07-24
- **Branch**: `feature/node-store`
- **Related**: `Documentations/SubtreeInterning.md`（前置优化：全子树 hash-consing，已合入 main `5788472`）

## Summary

为批量 demangle 场景引入一个与现有 `Node` 类**并存**的紧凑存储层 `NodeStore`：所有节点平铺存放在连续缓冲（arena）中，节点间用 4 字节索引互指，每节点 12 字节、无对象头、无引用计数、无逐节点堆分配。公共 API 通过轻量值类型句柄 `NodeReference`（store 引用 + `UInt32` 索引）访问，架构对标 swift-syntax 的 SyntaxArena + 值类型句柄模式。分四个可独立交付的阶段渐进迁移，全程不破坏现有 `Node` API。

## Motivation

内存基线（详见 `Documentations/SubtreeInterning.md` 的实测）：

- `Node` 是 `final class`，每实例 48 字节（16 字节对象头 + 2 字节 kind + 对齐 + 17 字节 `Payload` 枚举 = 41 字节，落入 48 字节 malloc 桶），逐节点独立 malloc + 引用计数；
- 全子树 hash-consing（proposal 前置工作）已把 49k 符号语料的解析驻留从 39.5 MB 降到 12.9 MB（存活实例 76 万 → 20.2 万）；
- 对照 C++ `Demangle::Node`：24 字节/节点 + bump allocator。class 形态的剩余差距来自对象头（16B）、malloc 分桶取整（41→48）与逐节点分配/引用计数，**在保持 class 的前提下无法消除**；
- 全量 SwiftUI 场景（含 dyld cache local symbols）当前预计仍需 150–250 MB，目标降到 30–80 MB，并为「把整个 dyld cache 的解析结果持久化为符号数据库」铺路。

单纯把 `Node` 改为带 `[Node]` 的 struct 不可行：children 数组仍是逐节点堆分配（32 字节缓冲头 + CoW 引用计数），加上大 struct 拷贝，内存与 CPU 双双倒退。struct 的真正价值在于**精确布局 + 可平铺进连续缓冲**，因此正确形态是 arena + 索引。

## Detailed Design

### 存储布局

```swift
@frozen struct CompactNode {          // size 12, alignment 4, 无对象头
    var kindAndPayloadKind: UInt16    // bit 0-8: kind（~300 种，9 位）
                                      // bit 9-11: payloadKind（6 种，3 位）
                                      // bit 12-15: 保留
    var payloadA: UInt32
    var payloadB: UInt32
}
```

`payloadA/payloadB` 按 `payloadKind` 解释（沿用现有 `Payload` 的互斥不变量：contents 与 children 不共存）：

| payloadKind | payloadA | payloadB | 覆盖比例（49k 语料实测） |
|---|---|---|---|
| `none` | — | — | 与 leaf 部分重叠 |
| `index` | `UInt64` 低 32 位 | 高 32 位 | 少量 |
| `text` | 字符串表 offset | 字节长度 | ~5% |
| `oneChild` | 孩子索引 | — | ~67% |
| `twoChildren` | 孩子 0 索引 | 孩子 1 索引 | ~12% |
| `manyChildren` | edges 缓冲起点 | 孩子数量 | ~16% |

配套缓冲（每个 store 一套）：

- `nodes: ContiguousArray<CompactNode>` — 主 arena，`append` 即 bump 分配；
- `edges: ContiguousArray<UInt32>` — 仅 3+ 孩子节点使用的孩子索引连续区段；
- `textBytes: ContiguousArray<UInt8>` — 字符串表，全部 identifier 的 UTF-8 字节连续存放并去重；
- intern 哈希表 — 把已实现的 hash-consing 从 `ObjectIdentifier` 键迁移为索引键：`(kindAndPayloadKind, payloadA, payloadB)` 经孩子索引规范化后即天然唯一，键就是 12 字节本身。

容量边界：`UInt32` 索引上限 42.9 亿节点、字符串表 4 GB——对单个 store（哪怕整个 dyld cache）远够；越界走 `precondition` 失败而非静默截断。

预算核算（49k 语料，20.2 万唯一子树）：`201k × 12B ≈ 2.4 MB` 节点 + edges ~0.3 MB + 字符串表 ~0.5 MB + intern 表 ~2 MB ≈ **5–6 MB**（现状 12.9 MB）。相对 C++ 的反超点：孩子引用用 4 字节索引而非 8 字节指针。

### 类型与 API 面

```swift
/// 冻结后的不可变符号库。构建完成即 Sendable，读路径零锁。
public final class NodeStore: Sendable {
    public func demangleAsReference(_ mangled: String) throws(DemanglingError) -> NodeReference   // Phase 3
    public func reference(of node: Node) -> NodeReference                                          // 导入现有树（intern 拷贝）
}

/// 轻量句柄：store 引用 + 索引，16 字节值类型。
public struct NodeReference: Hashable, Sendable {
    public var kind: Node.Kind { get }
    public var text: Substring? { get }          // 借用字符串表，零拷贝
    public var index: UInt64? { get }
    public var children: ChildrenView { get }     // RandomAccessCollection<NodeReference>
    public func materialize() -> Node             // 物化为现有 Node 树（互操作出口）
    public func print(using options: DemangleOptions) -> String
}
```

- 构建期使用 `NodeStoreBuilder`（`~Copyable`）：单写者约束由编译器保证，`consuming func freeze() -> NodeStore` 完成冻结——把现在靠 `NSLock` + 文档契约维持的「构建后不可变」升级为类型系统保证；
- `Hashable`/`==` 基于 (store identity, index)：因为 store 内全量 hash-consed，索引相等 ⇔ 结构相等，比较从 O(树) 降为 O(1)；
- 读路径后续用 `Span` / `UTF8Span`（Swift 6.2）暴露孩子区段与文本的借用视图，零分配零拷贝。

### 构建流程（两代空间）

1. Demangler 把节点写入**每符号复用的 scratch arena**（容量保留、每符号 `removeAll(keepingCapacity: true)`）——解析中产生的临时节点零成本丢弃，等价于 C++ 每符号销毁 `NodeFactory`；
2. 解析成功后，从根出发把可达节点自底向上 intern 拷贝进持久 store——**去重与垃圾回收是同一个 pass**，键规范化逻辑与已合入的 `internTreeUnsafe` 完全同构；
3. scratch 重置，处理下一符号。

并行策略：每线程一个 scratch arena；持久 store 的 intern 写入初期沿用单锁（与现状一致），若成为瓶颈再演进为分片锁或每线程局部 store + 终态合并。

### 渐进式迁移分期

每个阶段独立可交付、测试全绿、`Node` API 始终不动：

- **Phase 1 — 存储层与互操作**：`CompactNode` / `NodeStoreBuilder` / `NodeStore` / `NodeReference`；`reference(of:)` 导入现有 `Node` 树，`materialize()` 导出。打印/remangle 暂走物化慢路径。验收：任意树 导入→导出 与原树 `==`；导入两棵结构相等的树得到同一索引。
- **Phase 2 — 零物化读路径**：将 `NodePrinter` / `Remangler` / `TypeDecoder` 的树访问抽象为协议（kind/text/index/children 四个只读需求），`Node` 与 `NodeReference` 双双 conform；打印与 remangle 直接从 store 读，不再物化。验收：全量 dyld cache 对齐测试在 `NodeReference` 路径下 0 失败。
- **Phase 3 — 解析直写 arena**：`Demangler` 的节点构造抽象为存储策略（默认策略维持现有 `Node` 行为不变；store 策略直写 scratch arena），提供批量入口 `NodeStore.demangleAsReference(_:)`。此阶段起，批量场景完全绕开 class 分配。验收：内存达标（49k 语料 ≤6 MB）、吞吐不劣于现状 1.2 倍。
- **Phase 4（可选）— 平铺序列化**：store 的几个缓冲直接二进制序列化/反序列化（接近 memcpy 量级），支持 mmap 加载——符号数据库能力，为 RuntimeViewer 类工具缓存整个 dyld cache 的解析结果。

### 与现有 NodeCache 的关系

store 自带索引级 intern，store 路径不经过全局 `NodeCache`；批量用户迁移到 store 后，`NodeCache` 仅服务于一次性/精细操作场景，其增长压力自然消失。两者语义一致（结构相等 ⇔ 规范实例/索引相等）。

## Source Compatibility

纯增量 API，无破坏性变更。`Node`、`NodeBuilder`、`NodeCache`、`demangleAsNode` 行为全部保持。Phase 2 的协议抽象对 `NodePrinter`/`Remangler` 是内部重构，公共签名不变。

## Performance Goals（验收标准）

| 指标 | 目标 |
|---|---|
| 每节点存储 | ≤ 16 字节（设计值 12） |
| 49k 语料总驻留 | ≤ 6 MB（现状 12.9 MB，hash-consing 前 39.5 MB） |
| 全量 SwiftUI 场景 | ≤ 100 MB（现状预计 150–250 MB） |
| 解析吞吐 | 不劣于现状的 1.2 倍 |

基准方法沿用既有测量工程（NodeMemBench：`class_getInstanceSize` / `malloc_size` / `phys_footprint` 三角验证），增加 store 变体对照。

## Alternatives Considered

- **`ManagedBuffer` 尾分配 class 节点**（孩子内联到实例尾部，单次分配）：仍保留 16 字节对象头与引用计数，加权后 ~32–48 字节，被 arena 全面支配，否决；
- **压缩 class 布局到 32 字节桶**：需手工 union 并外部化 `String`/双孩子，加权收益仅 ~1.2 倍，复杂度不成比例，否决（详见 SubtreeInterning 文档）；
- **直接把 `Node` 重写为 struct 句柄**（swift-syntax 式整体替换）：终态最优但破坏全部公共 API 与下游（MachOSwiftSection / RuntimeViewer），不符合渐进要求；本方案 Phase 3 完成后如需要可再评估。

## Future Directions

- mmap 符号数据库格式版本化（magic + version + 缓冲布局描述）；
- 分片并行 store 与终态合并；
- `InlineArray`（SE-0453）在 scratch arena 孩子暂存区的应用；
- `NodeReference` 层面的 `Node.Rewriter` 等价物（写时拷贝进新 store）。

## Decision Log

| Date | Decision | Notes |
|---|---|---|
| 2026-07-23 | Created as Draft | 基于 48B class 下限与 C++ 24B 对比分析，确定 arena + 索引句柄方向；分四阶段渐进迁移，不破坏现有 `Node` API |
| 2026-07-23 | Status → In Progress，Phase 1 落地 | 用户确认迭代方向，在 worktree `feature/symbol-store` 实施。`CompactNode`（实测 size/stride = 12）、`NodeStoreBuilder`（`~Copyable` + `consuming freeze()`）、`NodeStore`、`NodeReference` + `ChildrenView` 完成，含 `intern(_ node:)` 导入与 `materialize()` 导出互操作、桥接式 `demangle(_:)`（经 `internsSubtrees: false` 的临时 `Node` 树） |
| 2026-07-23 | Phase 1 实测达标 | 49k 语料：唯一节点 201,876（与 `NodeCache` 全树 hash-consing 计数逐一吻合，交叉验证正确性）；平铺存储 3.0 MB（nodes 2.4 + edges 0.43 + text 0.26），优于 ≤6 MB 目标；打印抽样 2000 条零差异；构建 0.87s，不劣于 class 路径。**新发现**：构建期高水位 ~16 MB，由 intern 表（`[CompactNode: UInt32]` 等，~10 MB 量级）与桥接路径的临时 class 节点构成，且已冻结后 dirty pages 不随 `malloc_zone_pressure_relief` 回落；两轮连建仅 +6 MB，确认内存复用、无累积。结论：①「49k ≤6 MB」按保留存储口径已达成，进程口径需 Phase 3（直写 arena，消除临时树）+ intern 表瘦身（改为指向 nodes 缓冲的 open-addressing 索引表，去掉独立 key 存储）；②桥接路径会向全局 `NodeCache` 写入叶节点（实测 11k 条），Phase 3 前的批量用户建议构建后 `NodeCache.shared.clear()` |
| 2026-07-23 | Phase 2（打印）落地：零物化 store 打印 | 引入 `DemanglingNode` 只读协议（`kind`/`text`/`index`/`hasIndex`/`children` + `printCacheIdentity` 抽象缓存身份；`isSimpleType`/`needSpaceBeforeType`/`isIdentifier`/`isSwiftModule`/`print` 作为协议扩展从原语派生），`Node` 与 `NodeReference` 双双 conform。把 2179 行的 printer 引擎泛型化为 `DemanglingPrinter<Target, SomeNode>`（发现 printer 是纯只读消费者，全程不构造节点，泛型化干净），保留公共 `NodePrinter<Target>` 薄包装转发到 `DemanglingPrinter<Target, Node>`——**公共 API 零破坏**。`NodeReference.print` 直接走 `DemanglingPrinter<_, NodeReference>`，不再 `materialize()`。**关键正确性点**：`NodeReference.text` 必须镜像 `Node.text` 对 `.dependentGenericParamType` 的泛型名合成（printer line 199 依赖之）；`NodePrintContext.node` 是具体 `Node?`，store 路径以 `name as? Node`（NodeReference → nil）优雅降级，`String` target 无视 context 故无影响。**验证**：49k 语料 × 3 套选项（default/simplified/synthesizeSugar）store 打印与 Node 打印逐字节零差异；全量 dyld cache 对齐测试 + TypeDecoder 测试全绿 |
| 2026-07-23 | 事故与恢复 | 外部工具删除了 `.claude/worktrees/` 目录，Phase 2 的未提交改动随磁盘丢失（三个 commit 因在 git 对象库中而安全）。因 printer 改造为确定性脚本化流程（perl + 精确 Edit），已从会话记录逐字复现全部 Phase 2 变更，重建 worktree 后重跑构建/测试验证一致 |
| 2026-07-23 | Phase 2 跟进：materialize 保共享 + 派生属性单一来源 | ① `materializeNode` 增加按索引 memo：store 是 hash-consed 的 DAG，同一子树索引只物化一次并复用实例——此前朴素递归会把重度替换共享的符号指数展开成树（printCache 注释中 SwiftUI `View.Body` 量级即几十万节点），且展开树上按 `ObjectIdentifier` 键的打印缓存全部脱靶；新增测试 `materializePreservesSubtreeSharing` 断言共享位置 `===`。② 删除 `Node` 上与 `DemanglingNode` 扩展重复的 `isSimpleType`/`needSpaceBeforeType`/`isIdentifier(desired:)`/`isSwiftModule`：这些是协议扩展成员（非 requirement），泛型引擎内静态派发恒走扩展版本，两份拷贝存在静默漂移风险；收敛为单一实现后对外仍是 public API（具体 `Node` 调用解析到协议扩展），行为与逐字节输出不变，全量测试绿 |
| 2026-07-24 | 仓库形态调整 | `feature/symbol-store` 迁入独立 worktree `swift-demangling-symbol-store`（同级显式路径，避开曾被外部工具误删的 `.claude/worktrees/`），主检出切回 `main` 供 MachOSwiftSection 等路径依赖使用。合并 main 的 `7fcb0f1`（`NodePrinterTarget` type-reference scope hooks）：泛型引擎以 `name as? Node` 桥接，store 路径传 nil——当前 store 打印仅 String target，无实际降级；富 target 抽象随 swift-section 迁移再设计 |
| 2026-07-24 | Phase 2 收尾：遍历 + TypeDecoder + remangle 桥 + builder 构造 API + @_spi | ① 遍历机制（preorder/inorder/postorder/levelorder、`first(of:)`/`all(of:)`/`contains`/`filter(of:)`、`identifier`）整体泛型化为单一实现，`NodeReference` conform `Sequence`（preorder 默认），parity 测试断言两种表示遍历序逐一相同。② `TypeDecoderEngine<Builder, SomeNode>` + 公共 `TypeDecoder<Builder>` facade（新增 `NodeReference` 入口）；**`TypeBuilder` 协议零改动**——五个交接点经新协议 requirement `materializedNode`（`Node` 返回 self 零成本）物化小子树。③ **Remangler 决策：保持 Node 引擎**。审计确认 remangling 遍历中节点构造是承重的（`getUnspecialized` 剥泛型后回流 `mangle`、SIL box 布局 wrapper，均共享 substitution 状态，与 C++ NodeFactory 设计同构）；对逐字节对齐关键组件做无构造重设计不值。`mangleAsString(some DemanglingNode)` 经 `materializedNode` 桥接（remangle 输出本就是新 String，瞬态成本，与常驻内存目标无关）。`printCacheIdentity` 改名计划放弃（未出现第二个消费者）。④ builder 新增 `intern(kind:)`/`(kind:text:)`/`(kind:index:)`/`(kind:children:)` 直接构造 API，与树 intern 共享 hash-consing（测试断言同一索引）。⑤ `DemanglingPrinter` 与 `StackSafeExecutor` 以 `@_spi(Internals)` 导出（与 MachOSwiftSection 既有 SPI 组名一致），客户端视角验证：带 SPI import 可见、不带不可见 |
| 2026-07-24 | Phase 3 落地：cache-free 批量 demangle + intern 表瘦身 | ① `Demangler` 构造 seam：全部 ~594 个构造点收敛到 `createNode(...)` 实例方法，`internsLeaves: false`（内部入口 `demangleAsNodeTransient`，builder 桥接改用之）完全绕开 `NodeCache.shared`——无叶节点泄漏、无全局锁竞争、临时树丢弃后零残留；公共入口默认行为不变。测试用叶身份断言 cache-free（并发 suite 不会 flake）。② intern 表瘦身：三张字典（键各自持有 12B compact/子索引数组/String 副本）换成 open-addressing 槽数组（4B/槽，键按需从缓冲区取回比较），FNV-1a 文本哈希 + 乘法混合节点哈希。③ **验收（本机 dyld cache SwiftUI 语料 234,232 符号，debug 构建）**：唯一节点 619,688，平铺存储 8.75 MB（14.1 B/节点 ≤16 目标，37 B/符号；nodes 7.4 + edges 0.75 + text 0.57）；store 构建 25.3s vs interning Node 路径 28.5s——**快于基线**（预算允许慢 1.2×）；构建期 phys_footprint 增量 9.9 MB ≈ 留存 + ~1 MB 瞬态（旧方案在 1/5 语料上高水位即 ~16 MB）。验收测试按单位口径断言（≤16 B/唯一节点、≤64 B/符号、耗时 <2× 基线）常驻于测试套件。备注：提案原稿的 `NodeStore.demangleAsReference` 定名为 builder 侧 `demangle(_:)`——冻结后的 store 不可变，解析入口天然属于 builder |
| 2026-07-24 | Phase 3 跟进（读路径 perf）：零拷贝文本 | `NodeReference.textUTF8` 暴露字符串表字节的零拷贝 `ArraySlice` 视图；`isIdentifier(desired:)`/`isSwiftModule` 升为 `DemanglingNode` requirement（带派生默认实现），`NodeReference` 以字节比较见证——printer 的 sugar 检测热路径（Swift module + Optional/Array/Dictionary）在 store 路径不再每检查构造一次 String；非 ASCII needle 回退 String 比较保持 Unicode 规范等价语义。`UTF8Span` 借用视图仍列为 Future Direction |
| 2026-07-24 | 命名调整：`SymbolStore` → `NodeStore` | 库的领域概念是 `Node`（demangle 产物树节点），API 体系中并无 "Symbol" 抽象——该词仅是输入 mangled string 的口语说法。全部类型随之更名：`SymbolStore` → `NodeStore`、`SymbolStoreBuilder` → `NodeStoreBuilder`（`NodeStore.NodeIndex` 不变），与 `Node`/`NodeReference`/`CompactNode`/`NodeCache` 命名系对齐。曾考虑 `NodeFactory`（C++ 编译器中 `NodeFactory` 正是 demangle 的 slab arena 分配器，有官方先例）但放弃：本项目 `NodeFactory` 已被无参 singleton 节点集合占用（名同义异），且 C++ 版是短命裸分配器，与可 `freeze()` 的持久 hash-consing 容器语义不符——frozen 只读容器叫 Factory 会误导熟悉官方源码的读者。文件同步更名（含本提案 `0001-symbol-store-arena.md` → `0001-node-store-arena.md`）；分支同步更名 `feature/symbol-store` → `feature/node-store`（本地 + origin：先核对远端 tip 一致、无关联 PR，推新名后删除旧远端分支）；MachOSwiftSection 侧 `SymbolStoreMigrationPlan.md` → `NodeStoreMigrationPlan.md` 同步更新（其自有类型 `SymbolIndexStore` 不在改名范围）；decision log 历史记录保留原状 |
| 2026-07-24 | 下游迁移配套：跨表示相等 + transient demangle SPI | 为 MachOSwiftSection 的 `SymbolIndexStore` → NodeStore 迁移（其 `Documentations/Internal/NodeStoreMigrationPlan.md`）新增：① `NodeReference.structurallyEquals(_ node: Node)`——零物化跨表示结构相等（语义对齐 `Node.==`：kind + contents + children 递归；text 先字节比较、Unicode 规范等价回退 String ==），服务「外部 canonical `Node` 在 `NodeReference` 字典键中查找」场景（frozen store 的 intern 表已随 `freeze()` 丢弃，不能哈希查找；name 预桶内线性结构比较足够），附 3 个单元测试；② `demangleAsNodeTransient` 以 `@_spi(Internals) public` 导出——下游批量索引在瞬态树上跑分类逻辑后 `builder.intern`，全程 cache-free（文档注明返回树非 canonical）；③ `isKind(of:)`（原 `Node` 扩展）与 `children.second`（原 `Node.Children` 具体成员）上收为 `DemanglingNode`/`DemanglingNodeChildren` 协议扩展单一实现，删除具体副本；④ `NodeReference: CustomStringConvertible`（物化桥的 debug 树 dump）。迁移侧实测（SwiftUI image）：构建管线换 transient+intern 后 `NodeCache` 增长归零（此前 +1.9 万叶/+56 万子树），`Storage` 释放即整镜像回收，store 本体 7 MB / 57.9 万唯一节点 |
