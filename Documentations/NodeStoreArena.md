# NodeStore：arena 式紧凑节点存储

日期：2026-07-27（Phase 1–3 已落地）

对应提案：`Evolutions/0001-node-store-arena.md`
前置优化：[SubtreeInterning.md](SubtreeInterning.md)（全子树 hash-consing）
概念背景：[Concepts/ArenaStorage.md](Concepts/ArenaStorage.md)（class 的 48 字节都花在哪、arena /
bump allocator / 物化是什么）。词条速查见 [Glossary.md](Glossary.md)。

## 一句话结论

`Node` 是 class，每个节点固定要付「对象头 + malloc 档位 + 引用计数 + 8 字节指针」的
成本，这部分**在 class 形态下已经省无可省**。`NodeStore` 新增一套并存的存储层：节点
平铺进连续缓冲，每个 12 字节、用 4 字节下标互相引用；printer 与 TypeDecoder 泛型化后
可以直接读这块缓冲打印，不必先还原成对象树。**公共 API 零破坏，`Node` 路径行为一字
未变。**

## 动机

`SubtreeInterning.md` 结尾把「arena + 索引式存储」列为被推迟的方向，本次即是它的兑现。

全子树 hash-consing 把 49k 符号语料的解析驻留从 39.5 MB 压到 12.9 MB，但剩下的开销
无法在 class 形态下继续消除：

- `Node` 是 `final class`，每实例 48 字节 —— 其中 16 字节是对象头，41 字节的实际内容
  还要向上取整到 48 字节的 malloc 档位；
- 每个节点一次独立 malloc，每次传递一次引用计数增减；
- 指向 children 的引用是 8 字节指针。

对照 C++ `Demangle::Node`：24 字节/节点 + bump allocator。**差距全部来自 class 这个
形态本身**，不是实现细节。

把 `Node` 改成带 `[Node]` 的 struct 并不能解决问题：children 数组仍然是逐节点的堆分配
（32 字节缓冲头 + CoW 引用计数），再加上大 struct 的拷贝成本，内存和 CPU 双双倒退。
struct 的价值在于**精确布局 + 可平铺进连续缓冲**，所以正确形态是 arena + 索引。

同时，`Node` 是公共 API，下游（MachOSwiftSection、RuntimeViewer）大量依赖，不能就地
重写。因此本方案是**并存**而非替换。

## 范围

新增 `Sources/Demangling/Store/`：

- `CompactNode.swift` — 12 字节的平铺节点表示；
- `NodeStore.swift` — 冻结后的不可变存储；
- `NodeStoreBuilder.swift` — `~Copyable` 构建器，插入即 hash-consing；
- `NodeReference.swift` — 16 字节值句柄 + `ChildrenView`；
- `DemanglingNode.swift` — `Node` 与 `NodeReference` 共同遵循的只读树协议。

改造既有代码：

- `Node/Printer/NodePrinter.swift` — printer 引擎泛型化为 `DemanglingPrinter<Target, SomeNode>`；
- `Main/TypeDecoder/TypeDecoder.swift` — 泛型化为 `TypeDecoderEngine<Builder, SomeNode>`；
- `Main/Demangle/Demangler+NodeCreation.swift` — demangler 的节点构造 seam，支持绕开全局缓存。

**公共 API 零破坏**：`Node`、`NodeBuilder`、`NodeCache`、`demangleAsNode`、
`NodePrinter<Target>`、`TypeDecoder<Builder>`、`TypeBuilder` 的签名与行为全部保持。

## 关键设计

### 12 字节的节点

```swift
struct CompactNode {                  // size 12, alignment 4
    var kindAndPayloadKind: UInt16    // bit 0-8: kind 序号；bit 9-11: payloadKind；bit 12-15: 保留
    var payloadWord0: UInt32
    var payloadWord1: UInt32
}
```

两个 payload 字的含义由 `payloadKind` 决定（`none` / `index` / `text` / `oneChild` /
`twoChildren` / `manyChildren`），沿用 `Node.Payload` 既有的互斥不变量：一个节点要么
带 contents，要么带 children，不会同时有。49k 语料实测分布：`oneChild` ~67%、
`manyChildren` ~16%、`twoChildren` ~12%、`text` ~5%——**近八成节点只有零到一个
child**，所以把最多两个 children 直接内联进 payload、只让 3 个以上的外溢到 edges
缓冲，是很划算的选择。

每个 store 三块连续缓冲：

| 缓冲 | 内容 |
|---|---|
| `nodes` | 主 arena，`CompactNode` 逐个 append（即 bump 分配） |
| `edges` | 3 个以上 children 的节点，其 children 下标连成的区段 |
| `textBytes` | 去重后的 UTF-8 字符串表 |

指向 children 的引用是 4 字节下标而非 8 字节指针——这正是相对 C++ 24 字节实现的
反超点。

容量上限：`nodes` 最多 42.9 亿个节点（`UInt32` 下标空间），`edges` 与 `textBytes` 各
最多 4 GB。三者越界都走 `precondition` 失败，不静默截断。

### 插入即 hash-consing，intern 表不留在成品里

`NodeStoreBuilder` 对每个插入的节点做 hash-consing：结构相等的子树收敛到同一个下标。
因为 children 总是先于父节点被 intern，父节点的键可以直接用**已规范化的 children
下标**比较，无需递归结构哈希——与 `NodeCache.internTreeUnsafe` 是同一套技巧。

intern 表本身是三张开放寻址的槽数组（普通节点 / 3 个以上 children 的节点 / 文本），
**每槽只存 4 字节下标，键按需从平铺缓冲区取回来比较**，不为键单独保存一份拷贝。
早期用字典（键各自持有 12 字节 compact 值、child 下标数组或 `String` 副本）时，intern
表本身在全语料上要占约 10 MB 量级；改为槽数组后降到约 2 MB。

`consuming func freeze()` 消费 builder、丢弃全部 intern 表，只留三块缓冲。这带来两个
结果：

- 「构建完成后不可变」由类型系统保证，不再依赖锁和文档契约；
- 冻结后的 store **无法再做哈希查找**——这解释了为什么 `NodeReference` 需要
  `structurallyEquals` 这类线性比较 API（见下文）。

### 构建流程：cache-free 临时树，而不是直写 arena

提案原稿设想让 demangler 直接写入 arena。实际落地保留了 `Node` 作为中间的「第一代
空间」：

1. `demangleAsNodeTransient` 以 `internsLeaves: false` 解析，产出的临时 `Node` 树完全
   不碰 `NodeCache.shared`；
2. `builder.intern(tree)` 自底向上把可达节点 intern 进 arena —— **去重与垃圾回收是
   同一个 pass**；
3. 临时树失去引用即被 ARC 回收。

之所以没做直写：demangler 的解析逻辑（回填、substitution 复用）建立在引用语义上，改为
索引式直写等于重写 `Main/Demangle/` 下全部五百多处节点构造点（当前 576 处
`createNode(...)` 调用）。而实测表明这一层临时成本可以忽略——234k 符号语料上构建期
常驻增量仅 9.9 MB（≈ 留存 + 约 1 MB 瞬态），且构建耗时反而**快于** interning 的
`Node` 路径。

为此，demangler 的全部节点构造点收敛到 `createNode(...)` 这一个 seam 上。**新增构造点
必须走 `createNode(...)`，不能直接调 `Node.create(...)`**，否则 cache-free 契约会被
悄悄破坏。同理，用户提供的 symbolic reference resolver 需要用
`@_spi(Internals) Node.createTransient(...)` 构造回填节点——否则一启用 symbolic
reference，批量管线的 cache-free 成果当场失效。

### 一套引擎，两种表示

`DemanglingNode` 是 `Node` 和 `NodeReference` 共同遵循的只读树协议。它的要求是：
`kind` / `text` / `index` / `hasIndex` / `children`、一个抽象的 `printCacheIdentity`
（打印时用来标识「同一个共享节点」的键）、一个 `materializedNode`（需要具体 `Node` 的
互操作边界用），外加两个可由默认实现兜底、但表示可以自己给零分配版本的判定
（`isIdentifier(desired:)` / `isSwiftModule`）。成员名刻意与 `Node` 现有 API 一致，
这样泛型引擎的函数体不论特化到哪种表示都是同一份代码。

据此，2000 行以上的 printer 引擎泛型化为 `DemanglingPrinter<Target, SomeNode>`，
`TypeDecoder` 泛型化为 `TypeDecoderEngine<Builder, SomeNode>`，公共
`NodePrinter<Target>` / `TypeDecoder<Builder>` 退化为薄包装。面向使用者的
`print(using:)`（同步与 `async` 两个版本）挂在 `DemanglingNode` 的协议扩展上，
两种表示共用同一份实现。store 路径的打印是**零物化**的：全量 dyld cache 语料 × 3 套
选项，store 打印与 `Node` 打印逐字节零差异。

派生辅助（`isSimpleType`、`needSpaceBeforeType`、`isIdentifier(desired:)`、
`isSwiftModule`、`isKind(of:)`、`children.second` 等）**只保留在协议扩展上**。它们是
扩展成员而非协议要求，泛型引擎内部静态派发恒走扩展版本——在具体类型上再留一份拷贝
不会被引擎调用，只会静默漂移。遍历机制（preorder / inorder / postorder / levelorder、
`first(of:)` / `all(of:)` / `contains`）同理，已收敛为单一泛型实现。

**`Remangler` 刻意保持 `Node` 引擎**。审计确认它的遍历过程中节点构造是承重的：
`getUnspecialized` 剥掉泛型后要把结果回流给 `mangle`，SIL box 布局要构造 wrapper，
两者都共享 substitution 状态——这与 C++ remangler 的设计同构。对这样一个逐字节对齐
关键的组件做「无构造」重设计不划算，因此 `mangleAsString(some DemanglingNode)` 经
`materializedNode` 桥接。remangle 的输出本来就是新分配的 `String`，属于瞬态成本，
与常驻内存目标无关。

### 读路径的零分配细节

`NodeReference.textUTF8` 暴露字符串表字节的零拷贝 `ArraySlice` 视图。printer 的 sugar
检测热路径（判断 Swift module、`Optional` / `Array` / `Dictionary`）此前每次检查都要
构造一个 `String`；升级为协议要求 `isIdentifier(desired:)` / `isSwiftModule` 并由
`NodeReference` 以字节比较见证后，store 路径上这些检查不再分配。非 ASCII 的比较目标
回退到 `String` 比较，以保持 Unicode 规范等价语义。

### 跨表示的相等与哈希

冻结后 intern 表已丢弃，无法哈希查找，于是提供三个显式 API：

- `structurallyEquals(_ node: Node)` —— 零物化的跨表示结构相等；服务「手里有一棵外部
  demangle 出来的 `Node`，要在 `NodeReference` 字典键中找到它」这个场景。
  **注意它比 `Node.==` 严格一档**：文本按**精确 UTF-8 字节**比较，而 `Node.==` 用
  `String` 的规范等价。这是刻意的——字符串表按字节 intern，同一个标识符的 NFC 与 NFD
  两种拼法在 arena 里是两个下标，若在桥接处改用规范等价，跨表示相等会失去传递性；
- `structurallyEquals(_ other: NodeReference)` —— 同 store 直接比下标即得答案
  （hash-consing 使下标相等 ⇔ 结构相等，O(1)），跨 store 才走双树遍历；
- `structuralHash(into:)` —— 与上述结构相等自洽的结构哈希。

**为什么不能直接用固有的 `Hashable`**：`NodeReference.hash(into:)` 组合的是
`ObjectIdentifier(store)` + 下标，是以 store 身份为基底的。跨 store 的结构相等键会被
劈成两个桶。那些「按节点结构做字典键、内部却存 reference」的下游值类型，需要的正是
这个可显式调用的结构哈希构件。

> 顺带澄清一个被反复报出的「缺陷」：`Set<NodeReference>` 是正常去重的——同一个 arena
> 内「下标相同」就是「结构相同」。去重失败说明每个元素来自各自独立的 arena，那是
> `NodeReference(interning:)` 按设计产出的形状，批量场景用错了工具。详见
> `KnownIssues.md` N4。

## 取舍与影响面

- **物化出来的树不是 canonical**。`materialize()` 重建的是一棵全新的、不进 `NodeCache`
  的 `Node` 树。因此 `===` 共享假设在这条路径上**不成立**：同一个 store 下标物化两次
  得到两个不同实例。任何按节点身份（`ObjectIdentifier` / `===`）做关联的消费者，在
  store 路径上必须改为按结构关联（例如用 remangle 后的字符串作键）。
  `NodePrinterTarget.pushTypeReferenceScope` 收到的节点同样受此约束。
  - 物化本身保留 DAG 共享：按下标 memo，同一子树只物化一次并复用实例。否则重度替换
    共享的符号会被指数展开（SwiftUI `View.Body` 量级即几十万节点），且展开树上按身份
    键的打印缓存会全部脱靶。
- **下标只对签发它的 store 有效**。`NodeStore.NodeIndex` 是裸值，不带 store 反向引用。
  **debug 构建**下（提案 [0009](../Evolutions/0009-swift-syntax-arena-lessons.md)），每个
  builder 铸一个随机起点、逐个递增的 `UInt16` 签发 tag 嵌进它铸出的每个下标，
  `reference(at:)` 与 `intern(kind:children:)` 校验之——跨 builder/store 混用在开发期是
  确定性 precondition 失败，最坏的「in-range 静默读到无关子树」形态被优先拦截。
  **release 构建**下 tag 字段整个不存在（布局与行为与 0009 之前完全一致）：落在范围内
  就静默读到无关子树，落在范围外还可能因为 edges / text 偏移未经边界检查而 trap。这是
  开发错误检测，不是安全边界；同时持有多个 builder 时仍需自行保证不混用。
- **kind 序号不是序列化格式**。它取自 `Node.Kind.allCases` 中的位置，仅在单次进程运行
  内稳定。9 位空间共 512 槽，当前 `Node.Kind` 有 373 个 case，余量 139。本项目持续跟进
  Apple 工具链的 `Demangle::Node::Kind`，超出时由 `kindsByStoreOrdinal` 的
  `precondition` 拦截——注意那是**运行时**失败且位于 lazy static 中，只在首次触及
  store 路径时才暴露。Phase 4 的持久化格式必须自带稳定的 kind 映射表。
- **builder 是单写者**。`~Copyable` 保证了这一点，好处是全程无锁，代价是不能跨线程
  共享。多线程批量场景应每线程一个 builder，最后合并——合并 API 尚未实现。
- **已知符号量时先 `reserveCapacity(expectedSymbolCount:)`**（提案
  [0009](../Evolutions/0009-swift-syntax-arena-lessons.md)）。三块缓冲与三张 intern 槽
  数组默认从小容量翻倍增长，整框架构建要付十余次整缓冲拷贝、且每次翻倍瞬间新旧缓冲
  并存；按预估符号量一次预留可消掉这两者。预估系数按 dyld cache 语料实测标定（来源
  与数字见 builder 源码内 `ReservationCoefficients` 的注释），估小了退化为正常增长，
  估大了闲置容量随 store 存续（`freeze()` 有意不做 shrink）。用 `capacityUtilization`
  复核系数是否漂移。
- **`Node` 路径完全不受影响**。默认的 `demangleAsNode` 仍然走 `NodeCache` 的叶 + 全树
  interning，行为、输出、身份语义一字未变。

## 实测收益

Phase 1（49k 符号语料）：唯一节点 201,876，与 `NodeCache` 全树 hash-consing 的计数逐一
吻合（交叉验证了两套 intern 实现的正确性）；平铺存储 3.0 MB（nodes 2.4 + edges 0.43 +
text 0.26）。

Phase 3 验收（本机 dyld cache SwiftUI 语料 234,232 符号，debug 构建）：

| 指标 | 实测 | 目标 |
|---|---|---|
| 唯一节点 | 619,688 | — |
| 平铺存储 | 8.75 MB（nodes 7.4 + edges 0.75 + text 0.57） | — |
| 每唯一节点 | 14.1 字节 | ≤ 16 |
| 每符号 | 37 字节 | ≤ 64 |
| 构建耗时 | 25.3s（`Node` 路径 28.5s） | ≤ 1.2× 基线 |
| 构建期常驻增量 | 9.9 MB | — |

下游（MachOSwiftSection）迁移实测：构建管线换成 transient + intern 之后，`NodeCache`
增长归零（此前每镜像 +1.9 万叶节点 / +56 万子树），store 本体 7 MB / 57.9 万唯一节点，
`Storage` 释放即整镜像回收。

正确性：全量 dyld cache 对齐测试 0 失败；49k 语料 × 3 套打印选项，store 与 `Node` 路径
逐字节零差异。

## 共享 store：SharedNodeStore（0010）

冻结模型（builder → `freeze()`）要求输入集合开工前已知；下游第二类负载——浏览中
不断出现的类型名、conformance 树、晚到符号——在 0010 之前只能按「每棵树铸一个
私有小 store」规避（RV 五镜像实测 14,451 个 `NodeStore` 实例）。`SharedNodeStore`
是这类**增量负载**的形态：长生命周期、线程安全、`intern(_:)` / `demangle(_:)`
即刻返回永久有效的 `NodeReference`，没有 freeze 屏障。

### 两种构建模型的分工

| | 冻结（builder → freeze） | 共享（SharedNodeStore） |
|---|---|---|
| 输入集合 | 开工前已知（全量 sweep） | 随使用逐步出现 |
| intern 槽表 | freeze 时丢弃 | 终生保留（持续去重的来源） |
| 读路径 | 常量视图，零锁零间接 | 每 walk 锁内拷出一次 48 字节描述符 |
| 何时能读 | freeze 之后 | intern 返回即可 |
| 内存回收 | store 整体释放 | store 整体释放（同 scope-cache 驱逐模型） |

### 读写协议

- **写侧**：一把 `Mutex` 串行化全部 intern，内部就是一个永不 freeze 的
  `NodeStoreBuilder`——0009 的容量预估、签发 tag、哈希槽表全部原样生效。
  `demangle` 的 transient 解析在锁外，只有 intern 进临界区。
- **读侧（视图钉扎）**：读者经 `SharedViewState`（单 Mutex 槽）拷出当前
  `BufferView` 描述符；引擎级 walk（打印、结构相等、digest）入口钉一次、全程用
  同一份，零散访问（`kind` / `children[i]`）每次现取。
- **增长（退休保活）**：缓冲写满时分配倍增的新代、memcpy、把**旧代挂进退休链**
  而不是释放——已钉住旧视图的 walk 可能还在读它。空代（count 0）直接释放：
  没有任何已发引用能指进空代。发布新描述符后新读者自然读到新代。
- **陈旧视图为何安全**：①退休保活——旧基址永远有效；②自底向上不变量（子索引
  恒小于父索引，debug 断言钉在 `internInterior`）——只要视图覆盖 root 的索引，
  整棵子树都在视图内；③引用跨线程移交本身建立 happens-before，接收方随后的
  锁内视图读取必然覆盖该引用。
- **引用比本体长寿**：`NodeReference` 持有 `backingStore`（一个共享 store 只有
  一个 `NodeStore` 身份，`store ===` fast path 全量生效），`backingStore` 经
  `SharedViewState` 持有当前代 + 全部退休代。`SharedNodeStore` 本体先释放时，
  写者随之消失，但已发引用照常可读。

### 实测（0010 步骤 5，14,000 唯一名字树 × 2 次请求）

见 0010 提案决策日志的验收数字：与「结构哈希缓存 + 每唯一树一个 mini store」
（下游规避方案的最优形态）相比，单个共享 store 在保留同等去重语义的前提下
消灭了全部 per-store 固定开销与跨 store 零去重问题；corpus 级打印对拍
439,522 符号 × 3 选项集零差异，TSan 全绿。

## 已知短板

- `TypeDecoder` 的 store 路径**不是**零物化的：每走到一个嵌套 decl 就重建一次它的
  context 链，嵌套 k 层合计 O(k²)，深度 48 时比 `Node` 路径慢 11.4 倍。见
  `KnownIssues.md` 第 5 条。

## 后续方向（未实施）

- **Phase 4 — 平铺序列化**：三块缓冲直接二进制序列化 / mmap 加载（接近 memcpy 量级），
  把整个 dyld cache 的解析结果持久化为符号数据库。需先定义稳定的 kind 映射与格式版本号。
- **分片并行 store 与终态合并**：配合每线程一个 builder。合并的所有权/防环语义可参照
  swift-syntax `addChild`，但数据面必须走 re-intern（index 模型没有指针稳定性）——
  裁决记录见 [0009](../Evolutions/0009-swift-syntax-arena-lessons.md) 的 C.1。
- **`NodeReference` 层的 `Node.Rewriter` 等价物**：写时拷贝进新 store。

（原列于此的「`Span` / `UTF8Span` 借用视图」已由提案
[0008](../Evolutions/0008-span-borrowed-views.md) 实施：扫描器字节化、
`withTextUTF8` / `textUTF8Span()` 借用视图、`withSpans` 缓冲借用、打印 walk 的
`UnretainedNodeReference` 去 ARC——细节与实测见该提案的 Decision Log。）
