# 全子树 interning（hash-consing）内存优化

日期：2026-07-23（文末「本文落地后的后续变更」记录了此后对同一段代码的三次修改）

概念背景：[Concepts/Interning.md](Concepts/Interning.md)（intern、canonical、hash-consing 是什么、
为什么这么设计）。词条速查见 [Glossary.md](Glossary.md)。

## 一句话结论

批量 demangle 一整个二进制时，内存几乎全部消耗在 `Node` 实例本身，而**符号之间的子树
重复率极高**。把 interning 从「只对叶节点」扩展到「对每一棵子树」，49k 符号语料的解析
驻留从 39.5 MB 降到 12.9 MB，公共 API 无破坏性变更。

## 动机

对整个二进制（如 SwiftUI）做批量 demangle 并保留全部 `Node` 树时，内存占用达到
500–600 MB。实测定位（49,366 个 SwiftUI / SwiftUICore / Foundation / libswiftCore /
Combine 导出符号）：

- 每个 `Node` 实例经 malloc 分配 **48 字节**（16 字节对象头 + 2 字节 `kind` + 对齐 +
  17 字节 `Payload` 枚举 = 41 字节，落入 48 字节的 malloc 档位）；
- 解析后驻留增量 39.5 MB，其中 `Node` 实例占 34.8 MB（**88%**），3 个以上 children 的
  数组缓冲约 3 MB，堆字符串约 0.4 MB；
- 此前只对叶节点做 interning：110 万逻辑节点去重后仍有 76 万实例；
- 把 interning 扩展到全部子树后，76 万实例坍缩到 **20.2 万唯一子树（3.8 倍去重）**，
  且该比率在 5k / 15k / 30k / 49k 语料上稳定（3.4–3.8 倍）并随规模缓慢上升。

结论：全子树 hash-consing 是收益最大、改动最小的优化。

## 范围

- `Sources/Demangling/Node/NodeFactory.swift` — `NodeCache` 新增 interior 节点缓存与
  全树 hash-consing；
- `Sources/Demangling/Main/Demangle/DemangleInterface.swift` — `demangleAsNode` 新增
  `internsSubtrees: Bool = true` 参数，默认对结果树执行 interning 后处理；
- 测试与文档（`NodeCacheTests`、README、AGENTS.md）。

`Node` 的内存布局本身未改动，公共 API 仅新增参数与 `NodeCache.subtreeCount`，
无破坏性变更。

## 关键设计

### 自底向上，用「children 的实例身份」建键

`internTreeUnsafe` 自底向上遍历：先把 children 全部规范化，再拿当前节点的
`(kind, contents, 各 child 的 ObjectIdentifier)` 去查 `Set<SubtreeKey>`：

- 命中 → 丢弃当前节点，返回缓存里的规范实例；
- 未命中 → （若有 child 被换过则重建一次节点）插入并返回。

因为 children 一定先于父节点被规范化，**键的哈希与相等比较都只是 O(children) 的浅
操作**，不需要递归地比整棵子树——这是 hash-consing 的经典技巧，也是本方案性能可行的
前提。

同时保留一条快速路径：若一个节点以「children 身份完全一致」的键命中缓存，说明它的
children 必然已是规范实例，可以直接返回命中结果而不必下探。重复 intern 一棵已经规范
的子树（符号内部的 substitution 复用、跨符号的重复）因此只花 O(children)。

### 叶 / interior 两级存储

- 叶节点沿用原有的 `[LeafKey: Node]` 字典（键是 `kind + contents`），仍在
  `Node.create()` 创建时即时 intern；
- interior 节点存入新的 `Set<SubtreeKey>`，**只**通过树后处理进入缓存——解析过程中
  产生又被丢弃的临时中间节点不会污染缓存。

### 为什么在 demangle 结束后做，而不是创建时做

Demangler 解析过程中会构建大量最终不出现在结果树里的中间节点。若创建时就 intern
interior 节点，这些临时子树会被缓存永久持有。后处理只固化最终树上的节点，缓存内容
恰好等于「活着的规范子树」。

### 不可变契约

Interned 节点被跨树共享，安全性依赖既有契约：`Node` 的原地修改方法全部 `fileprivate`，
`NodeBuilder` 先深拷贝再修改。此前的叶节点 interning 已依赖同一契约，本次只是把适用
范围扩展到 interior 节点。

## 取舍与影响面

- **`===` 语义变化**：`demangleAsNode`（默认参数）返回的树是规范化的——同一个符号
  两次 demangle 返回同一实例，不同符号中结构相等的子树也是同一实例。结构 `==`、打印、
  remangle 的结果均不受影响（已由全量 dyld cache 对齐测试验证：0 失败）。
- **缓存持有**：interned 节点被 `NodeCache.shared` 强持有，直到 `clear()`。批量场景
  本来就要保留全部树，缓存内容与活树重合，无额外负担；一次性 demangle-丢弃的场景可用
  `internsSubtrees: false` 关闭，或事后 `clear()`。
  > 后来 `NodeStore` 走得更彻底：`demangleAsNodeTransient` 全程不碰全局缓存，
  > 见 [NodeStoreArena.md](NodeStoreArena.md)。
- **锁**：后处理对每棵树只加一次锁，但临界区从「若干次叶查询」变成「整棵树遍历」。
  多线程批量解析下锁竞争加剧属于已知取舍；如成为瓶颈，可后续做分片锁或每线程缓存合并。
- **解析耗时**：后处理与解析本身同量级（49k 符号约 +0.5s），换取约 4 倍内存下降。

## 实测收益

49k 符号语料：`Node` 实例内存 34.8 MB → 9.2 MB（3.8 倍）；总驻留增量约 2.5–3 倍下降
（39.5 MB → 12.9 MB）。对 500–600 MB 的全量 SwiftUI 工作负载，预期降至约 150–250 MB；
由于去重率随语料规模上升，实际可能更好。

## 本文落地后的后续变更（与当前代码的差异）

本文描述的是 2026-07-23 那次改动。同一段代码此后被改过三次，读代码时以下面为准：

1. **锁换成了 `Mutex`（2026-07-31，commit `3b5f5f3`）**。原文写的 `NSLock` 已不存在：
   `NodeCache` 的两张表放在同一个 `SwiftStdlibToolbox.Mutex`（底层 `os_unfair_lock`）
   里，因此 `NodeCache` 是普通 `Sendable`。名字里带 `Unsafe` 的那几个入口
   （`internUnsafe`、`internTreeUnsafe`）**现在也加锁**，名字仅为源码兼容保留。
2. **遍历改成了迭代（`StackSafety.md`）**。`internTree` 用显式栈而非递归——它在默认
   `demangleAsNode` 的热路径上，又不经过任何引擎的深度守卫，递归形态没有任何东西
   兜底。
3. **加了按实例身份的 memo（2026-08-02，evolution 0006）**。上文那条「快速路径」只在
   **被查节点自己的 children 已经规范**时才短路；一旦规范化替换了下层任何一个 child
   （树内部有结构重复、或与此前 interned 的结构重叠——第一棵树之后的常态），每个重复
   出现的实例都会探测失败并**重新下探整棵子树，按路径计价**，在加倍 DAG 上是 2^N，
   而且默认 `demangleAsNode` 就能走到。现在遍历期间用
   `[ObjectIdentifier: Node]` 记住每个源实例的规范化结果，成本回到按节点计价。

## 后续可选方向（未实施 / 已另行落地）

- **实例布局压缩（48 → 32 字节）**：需要手工 union 并把 `String` / 双 children 外部化
  为 8 字节指针，加权收益仅约 1.2 倍，复杂度不成比例，**已否决**；
- **arena + 索引式存储**：仿 C++ `NodeFactory` 的 bump allocator（24 字节/节点、无对象
  头、无引用计数）。当时判断需要破坏性重构 `Node` 公共 API 而推迟——**后来以「新增并存
  的存储层、`Node` 路径一字不动」的形态落地了**，见 [NodeStoreArena.md](NodeStoreArena.md)。
