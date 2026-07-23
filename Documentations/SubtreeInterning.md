# 全子树 Interning（Hash-Consing）内存优化

日期：2026-07-23

## 动机

在对整个二进制（如 SwiftUI）做批量 demangle 并保留全部 `Node` 树时，内存占用达到 500–600 MB。实测定位（49,366 个 SwiftUI / SwiftUICore / Foundation / libswiftCore / Combine 导出符号）：

- 每个 `Node` 实例经 malloc 分配 **48 字节**（16 字节对象头 + 2 字节 `kind` + 对齐 + 17 字节 `Payload` 枚举 = 41 字节，落入 48 字节 malloc 桶）；
- 解析后驻留增量 39.5 MB，其中 Node 实例占 34.8 MB（**88%**），`manyChildren` 数组缓冲约 3 MB，堆字符串约 0.4 MB；
- 此前仅对叶节点做 interning：110 万逻辑节点去重后仍有 76 万实例；
- 把 interning 扩展到全部子树后，76 万实例坍缩到 **20.2 万唯一子树（3.8 倍去重）**，且该比率在 5k/15k/30k/49k 语料上稳定（3.4–3.8 倍）并随规模缓慢上升。

结论：内存几乎全部消耗在 Node 实例本身，而符号间的子树重复率极高，全子树 hash-consing 是收益最大、改动最小的优化。

## 范围

- `Sources/Demangling/Node/NodeFactory.swift` — `NodeCache` 新增 interior 节点缓存与全树 hash-consing；
- `Sources/Demangling/Main/Demangle/DemangleInterface.swift` — `demangleAsNode` 新增 `internsSubtrees: Bool = true` 参数，默认对结果树执行 interning 后处理；
- 测试与文档（`NodeCacheTests`、README、AGENTS.md）。

`Node` 布局本身未改动，公共 API 仅新增参数与 `NodeCache.subtreeCount`，无破坏性变更。

## 关键设计

### 自底向上 + 按身份（identity）建键

`internTreeUnsafe` 自底向上遍历：先把孩子全部规范化（canonicalize），再对当前节点按 `(kind, contents, 各孩子的 ObjectIdentifier)` 查询 `Set<SubtreeKey>`：

- 命中 → 丢弃当前节点，返回缓存中的规范实例；
- 未命中 → （若有孩子被替换则重建一次）插入并返回。

由于孩子先于父节点规范化，**键的哈希与相等比较都是 O(children) 的浅操作**，不需要递归结构哈希——这是经典 hash-consing 技巧，也是本方案性能可行的关键。

同时保留一个快速路径：若一个节点以"孩子身份完全一致"的键命中缓存，说明其孩子必然已是规范实例，可直接返回命中结果而无需下探——重复 intern 已规范的子树（符号内替换复用、跨符号重复）代价仅 O(children)。

### 叶 / interior 两级存储

- 叶节点沿用原有 `LeafKey: [LeafKey: Node]` 字典，仍在 `Node.create()` 创建时即时 intern；
- interior 节点存入新的 `Set<SubtreeKey>`，**只**通过树后处理进入缓存——解析过程中产生又被丢弃的临时中间节点不会污染缓存。

### 为什么在 demangle 结束后做，而不是创建时做

Demangler 解析过程中会构建大量最终不出现在结果树里的中间节点；若创建时就 intern interior 节点，这些临时子树会被缓存永久持有。后处理只固化最终树的节点，缓存内容恰好等于"活着的规范子树"。

### 不可变契约

Interned 节点跨树共享，安全性依赖既有契约：`Node` 的原地修改方法全部 `fileprivate`，`NodeBuilder` 先深拷贝再修改。此前的叶节点 interning 已依赖同一契约，本次只是把适用范围扩展到 interior 节点。

## 取舍与影响面

- **`===` 语义变化**：`demangleAsNode`（默认参数）返回的树是规范化的——相同符号两次 demangle 返回同一实例，不同符号中结构相等的子树也是同一实例。结构 `==`、打印、remangle 结果均不受影响（已由全量 dyld cache 对齐测试验证：0 失败）。
- **缓存持有**：interned 节点被 `NodeCache.shared` 强持有，直到 `clear()`。批量场景本来就要保留全部树，缓存内容与活树重合，无额外负担；一次性 demangle-丢弃 的场景可用 `internsSubtrees: false` 关闭，或事后 `clear()`。
- **锁**：后处理对每棵树只加一次 `NSLock`（沿用既有 `intern(_:)`），但临界区从"若干次叶查询"变为"整棵树遍历"。多线程批量解析下锁竞争加剧属于已知取舍；如成为瓶颈，可后续做分片锁或每线程缓存合并。
- **解析耗时**：后处理与解析本身同量级（49k 符号约 +0.5s），换取约 4 倍内存下降。

## 预期收益

以 49k 符号语料实测：Node 实例内存 34.8 MB → 9.2 MB（3.8 倍）；总驻留增量约 2.5–3 倍下降。对 500–600 MB 的全量 SwiftUI 工作负载，预期降至约 150–250 MB；由于去重率随语料规模上升，实际可能更好。

## 后续可选方向（未实施）

- **实例布局压缩（48 → 32 字节）**：需要手工 union 并把 `String` / 双孩子外部化为 8 字节指针，加权收益仅约 1.2 倍，复杂度不成比例，已否决；
- **Arena + 索引式存储**：仿 C++ `NodeFactory` bump allocator（24 字节/节点、无对象头、无引用计数），可在本方案之上再取得约 2 倍收益，但需要以值类型 + 索引重构 `Node` 公共 API，属破坏性重构，留待将来单独评估。
