# 术语速查

一句话定义 + 指向详细讲解。**每个概念的完整解释、例子和实测数据都在 `Concepts/` 下的
对应文档里**，这里只负责让你在读文档卡住时快速对上号。

本表假定你已经知道 demangle 是什么、`Node` 长什么样（`kind` + contents + children）。
一律不译的词：**children**、**intern**、**arena**、**DAG**、**memo**。

---

## 共享结构 → [Concepts/SharedStructureAndDAG.md](Concepts/SharedStructureAndDAG.md)

| 词 | 一句话 |
|---|---|
| **DAG**（有向无环图） | 允许一个节点有多个父节点、但没有环的结构。本库的树逻辑上是树，**物理上是 DAG**。 |
| **substitution back-reference** | mangling 格式自带的压缩：同一类型第二次出现时写「参见前面第 N 个」。demangler 直接复用实例——这是共享的第一个来源。 |
| **leaf / interior node** | 没有 children 的 / 有 children 的节点。两者的 intern 时机不同（前者创建时，后者 demangle 结束后）。 |
| **upstream（上游）** | 官方 Swift 编译器的 C++ 实现。契约是逐字节复现它的输出，**包括它的怪毛病**。 |

## 去重 → [Concepts/Interning.md](Concepts/Interning.md)

| 词 | 一句话 |
|---|---|
| **intern（内部化）** | 创建前先查表：已有结构相同的就返回旧的那份。省内存，且判等退化成比指针。 |
| **canonical（规范实例）** | intern 表里选中的那一份。`demangleAsNode` 默认返回的整棵树都是规范化的。 |
| **hash-consing** | 把 intern 扩展到整棵树：自底向上，children 先规范化，父节点的键因此只需比指针，全树 O(节点数)。 |
| **transient tree（临时树）** | `demangleAsNodeTransient` 产出的树：全程不碰全局 `NodeCache`，用完即回收。 |

## arena 存储 → [Concepts/ArenaStorage.md](Concepts/ArenaStorage.md)

| 词 | 一句话 |
|---|---|
| **arena（区域式存储）** | 一块大的连续缓冲，节点平铺进去，用 4 字节**下标**而非 8 字节指针互相引用。 |
| **bump allocator** | arena 的分配方式：把「下一个空位」的偏移往后推，成本接近零；代价是不能单独释放。 |
| **对象头 / malloc 档位 / ARC / CoW** | 用 class 存节点必然要付的四项税，合计让每个节点占 48 字节。arena 把它们整个绕开（12 字节）。 |
| **open addressing（开放寻址）** | 冲突时顺着数组往后找空槽的哈希表。本库的槽里**只存 4 字节下标**，键按需回缓冲区取（intern 表 10 MB → 2 MB）。 |
| **materialize（物化）** | 把 arena 里的紧凑表示重新展开成 `Node` 树。结果是**新实例**，`===` 关联在这条路径上失效。 |
| **freeze / `~Copyable` / `consuming`** | 构建器不可复制（单写者、无锁），`freeze()` 消费它并丢弃 intern 表，换来类型系统保证的不可变 store。 |

## 遍历计价 → [Concepts/TraversalCost.md](Concepts/TraversalCost.md)

| 词 | 一句话 |
|---|---|
| **按路径计价 / 按节点计价** | 在 DAG 上无条件递归，成本是**路径数**（指数级）；记住访问过的实例，成本回落到**节点数**。文档里说「按路径计价」＝这里藏着指数爆炸。 |
| **memo（记忆化）** | 「这个实例我处理过了」的表，键用 `ObjectIdentifier`，作用域是本次遍历。 |
| **short-circuit query（短路查询）** | 只问「有没有 / 第一个是谁」的遍历（`first(of:)`、`contains(_:)`）——可以安全去重。而 `all(of:)` / `preorder()` 是**枚举**，出现次数就是正确答案，刻意不去重。 |

## 栈与崩溃 → [Concepts/RecursionAndStack.md](Concepts/RecursionAndStack.md)

| 词 | 一句话 |
|---|---|
| **栈帧 / 栈溢出** | 每层递归占一段线程栈；压满就被系统杀掉，不是抛异常。 |
| **深度上限** | 三个递归引擎各带一个固定上限（printer 768、remangler 1024、TypeDecoder 1024），超限优雅退化成 `<<too complex>>` / 抛错。 |
| **debug vs release 帧大小** | 未优化构建的栈帧大一个数量级（printer 每层约 11.6 KB），这是本库与上游环境的唯一本质差别。 |
| **trap vs SIGSEGV** | trap 是**可预期的主动中止**（`precondition`、整数转换越界）；SIGSEGV 是失控（多半是栈耗尽）。 |
| **`StackSafeExecutor`** | 调用线程剩余栈 ≥ 2 MB 就地跑，否则搬到 8 MB 栈的常驻 worker；批量场景用 `withLargeStack {}` 包一次。 |

---

## 本库特有的几个说法

| 说法 | 意思 |
|---|---|
| **`Node` 路径 / store 路径** | 前者是传统对象树（`demangleAsNode` + `NodeCache`），后者是 arena（`NodeStoreBuilder` + `NodeReference`）。两条路径并存，打印输出逐字节相同。 |
| **seam（接缝）** | 行为收敛到单点、从而能被一个开关整体切换的地方。本项目有两处：① `Demangler+NodeCreation.swift` 的 `createNode(...)`——demangler 全部节点构造收敛于此，一个开关切换「是否走全局缓存」（**新增构造点必须走它**）；② `DemanglingRuntimePath.forcesLegacyPath`（0008 的可测性 seam）——强制 demangle 入口走 pre-macOS 26 的旧路径，让一台新系统机器把双路径都测全（env `DEMANGLING_FORCE_LEGACY_PATH=1` 可整进程开启）。 |
| **双路径（dual path）** | 0008 确立的结构：被 OS 运行时版本卡住的特性（`.span` 属性、`UTF8Span`、`InlineArray`）按 `#available(macOS 26 系)` 分流，被编译器能力卡住的（`@_lifetime` 直接返回式）按 `#if hasFeature(Lifetimes)` 分流；分叉只允许出现在入口、物化点、存储选型三处，扫描/引擎/intern 逻辑永远单份。两条路径的产出要求逐字节一致（`DualPathParityTests` + CI 双跑）。 |
| **语料（corpus）** | 正确性对拍用的真实符号集合：dyld 共享缓存全量 **4,522,325 个符号**。文档里的「全语料 0 失败」都指这一套。 |
| **对齐测试 / oracle** | 拿本库输出与 Swift runtime / `swift-demangle` 逐字节比对的测试。`Node.description` 之所以不能优化成「共享子树只打印一次」，就是因为要跟 runtime 的转储对拍。 |
| **`<<too complex>>`** | 打印时触到深度上限的标记，表示这里主动放弃了，不是输出错误。 |
