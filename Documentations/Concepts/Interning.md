# intern 与 hash-consing：让相同的东西只存一份

> 概念篇。读完你会知道：intern 是什么、为什么它能把内存降到 1/5、hash-consing 凭什么
> 不会退化成 O(n²)，以及用它要付什么代价。
> 前置：[SharedStructureAndDAG.md](SharedStructureAndDAG.md)。
> 后续：[ArenaStorage.md](ArenaStorage.md)。

## 1. 从一个最小的例子说起

假设你要 demangle 一万个符号，其中大量涉及 `Swift.Int`。朴素做法下，每遇到一次就新建
一个节点：

```swift
let node = Node(kind: .identifier, text: "Int")   // 第 1 次
let node = Node(kind: .identifier, text: "Int")   // 第 2 次
...                                               // 第 8000 次
```

结果：内存里躺着 8000 个内容完全一样的对象，每个 48 字节，合计约 380 KB——**而它们本
可以是同一个对象**。

**intern（内部化 / 驻留）就是：创建前先查表，表里已经有结构相同的，就直接返回旧的那
一份；没有才新建并存进表。**

```swift
let first  = Node.create(kind: .identifier, text: "Int")
let second = Node.create(kind: .identifier, text: "Int")

first == second    // true —— 结构相等（本来就相等）
first === second   // true —— 而且是同一个实例
```

这不是本库发明的东西。Swift 的字符串字面量池、Java 的 `String.intern()`、Lisp 的符号表
都是同一个概念。

## 2. 它换来两样东西

**第一，内存。** 同样的内容只存一份。

**第二，比较变便宜。** 这一点常被忽略，但同样重要：

| | 没有 intern | 有 intern |
|---|---|---|
| 判断两棵子树是否相等 | 递归比较，O(子树大小) | `===` 比一个指针，O(1) |
| 拿子树当字典的 key | 递归哈希，O(子树大小) | 哈希一个地址，O(1) |

一棵有几百个节点的子树，比较成本从「几百次比较」降到「一次指针比较」。

## 3. canonical（规范实例）

intern 表里选中的那一份，叫**规范实例**（canonical instance）。「把某个节点规范化」＝
「把它替换成表里对应的那一份」。

本库的关键契约：

> `demangleAsNode` 默认返回的整棵树都是**规范化**的。
> 所以同一个符号 demangle 两次拿到的是**同一个实例**；不同符号里结构相同的子树，
> 也是同一个实例。

这条契约让下游可以放心用 `===` 做快速判等，也是共享结构的第二个来源
（见 [SharedStructureAndDAG.md](SharedStructureAndDAG.md) 第 3 节）。

## 4. 从「叶节点」到「整棵树」

上面的例子 intern 的是**叶节点**（没有 children 的节点，例如 `Identifier("Int")`）。
这很容易——键就是 `(kind, contents)`，一个字典搞定。

但内存的大头不在叶节点。真正想去重的是**整棵子树**，比如：

```
Structure
├── Module("Swift")
└── Identifier("Int")
```

这个三节点的 `Swift.Int` 子树，在 49k 符号的语料里出现了成千上万次。要把它们收敛成
一份，就需要 **hash-consing**。

### 朴素做法为什么不行

最直觉的做法是：拿「整棵子树的结构」当键。

```
键 = hash(kind, contents, hash(child0 的整棵子树), hash(child1 的整棵子树), ...)
```

问题是这个哈希要**递归走完整棵子树**。对一棵有 n 个节点、高 h 的树，每个节点都这么算
一遍，总成本 O(n × 子树大小)，在深树上直接爆炸。而且哈希冲突时的相等比较同样要递归。

用这种做法，去重省下的内存还不够抵消 CPU 的损失。

### hash-consing 的关键一招

**自底向上处理，并且用「children 的实例身份」当键的一部分。**

因为处理顺序保证 children 一定**先于**父节点被规范化，所以当我们要给父节点建键时，
它的 children 已经是规范实例了。于是：

> 两个父节点的 children **各自是同一个实例**（指针相等）
> ⟺ 两个父节点的 children **各自结构相等**

键里比指针就够了，不必递归。

走一遍 `Structure(Swift.Int)` 的例子：

```
第 1 步：处理 child 0 —— Module("Swift")
        查叶表 →命中 → 换成规范实例 #A

第 2 步：处理 child 1 —— Identifier("Int")
        查叶表 → 命中 → 换成规范实例 #B

第 3 步：处理父节点 —— Structure
        建键 = (kind: .structure, contents: none, children: [地址(#A), 地址(#B)])
        查子树表：
          命中 → 丢掉手里这个节点，返回表里那一份     ← 去重成功
          未命中 → 存进表，返回自己
```

每个节点只花 O(children)（通常是 1 或 2），整棵树一遍走完就是 **O(节点数)**。这就是
hash-consing 能实际用起来的全部原因。

> 名字里的 cons 来自 Lisp 的 `cons`（构造二元组）；hash-consing 就是「构造时先查哈希
> 表」。这是个 1970 年代就有的老技巧。

### 一个必须小心的地方

上面「键里比指针」的推理，**只在被查节点自己的 children 已经规范时成立**。如果某个
child 在下层被替换掉了（结构重复、或与之前 intern 过的结构撞上——这是第一棵树之后的
常态），那么这个节点用**原来的** children 身份去查表就会**探测失败**，于是它会重新
下探整棵子树。

在共享结构上，这个「重新下探」会按**路径数**计价，也就是指数级
（见 [TraversalCost.md](TraversalCost.md)）。所以真实实现里还有一层保险：遍历期间
用一张 `[ObjectIdentifier: Node]` 记住「这个源实例我已经规范化过，结果是它」。

这不是锦上添花——没有它，一个 131 字符的构造符号就能把默认的 `demangleAsNode` 拖到
指数级（evolution 0006 的修复）。

## 5. 时机：为什么 interior 节点要等 demangle 结束

本库分两级处理：

| | intern 时机 | 原因 |
|---|---|---|
| 叶节点 | `Node.create()` 创建时立刻 | 便宜，且创建量大 |
| interior 节点（有 children） | **整棵树 demangle 完成后**的后处理 | 见下 |

原因是：demangler 在解析过程中会构造**大量最终不出现在结果树里的中间节点**（试探、
回溯、临时包装）。如果创建时就 intern 它们，这些垃圾会被缓存**永久持有**——缓存本该
只装「活着的规范子树」。

后处理只固化最终树上的节点，缓存内容因此恰好等于「真正被用到的东西」。

## 6. 代价：用 intern 要接受什么

### 代价一：缓存会一直持有节点

interned 节点被 `NodeCache.shared` **强引用**，直到你调用 `clear()`。

- 批量场景（把整个二进制的符号都留在内存里）：缓存内容和你的活树本来就重合，**没有额外
  负担**；
- 一次性 demangle 然后丢弃：缓存会白白长大。这时用 `demangleAsNode(..., internsSubtrees: false)`
  关掉，或者事后 `clear()`；
- 完全不想碰全局状态（例如你要往 arena 里灌）：用 `demangleAsNodeTransient`，全程
  cache-free。

### 代价二：全局表要加锁

`NodeCache.shared` 是进程级共享状态，内部用一个 `Mutex` 保护。每棵树的后处理会持锁
走完整棵树——多线程批量解析时锁竞争会变明显。这是已知取舍，真成为瓶颈时的出路是分片锁
或每线程缓存后合并。

（想彻底摆脱这个锁，就是 [ArenaStorage.md](ArenaStorage.md) 那条路：每个 builder 自带
私有 intern 表，单写者、全程无锁。）

### 代价三：`===` 的含义变了

启用全子树 interning 后，「两个节点是同一个实例」不再意味着「它们来自同一个位置」。
任何按 `ObjectIdentifier` / `===` 给节点挂状态的代码都要重新审视
（见 [SharedStructureAndDAG.md](SharedStructureAndDAG.md) 坑三）。

### 代价四：不可变契约必须守住

被共享的节点如果能被就地修改，一处修改会影响所有引用它的地方。所以：

- `Node` 的原地修改方法全部是 `fileprivate`；
- 唯一的修改入口 `NodeBuilder` **先拷贝再改**，而且交出去的都是冻结节点。

**这条契约是 interning 能成立的前提**，改动这一带的代码时首先要保住它。

## 7. 实测收益

49k 个真实符号（SwiftUI / SwiftUICore / Foundation / 标准库 / Combine 的导出符号）：

| 指标 | 只 intern 叶节点 | 全子树 hash-consing |
|---|---|---|
| 节点实例数 | 76 万 | **20.2 万**（3.8 倍去重） |
| `Node` 实例内存 | 34.8 MB | **9.2 MB** |
| 解析后总驻留 | 39.5 MB | **12.9 MB** |
| 解析耗时 | 基准 | +0.5 秒 |

去重比率在 5k / 15k / 30k / 49k 语料上稳定在 3.4–3.8 倍，并随规模缓慢上升——**语料越
大越划算**，因为跨符号的重复面更宽。

## 在本库的哪里

- `Node/NodeFactory.swift` — `NodeCache`：两级表（`[LeafKey: Node]` + `Set<SubtreeKey>`），
  `internTree` 是自底向上的迭代遍历，带按实例身份的 memo
- `Node/Node+Init.swift` — `Node.create(...)`：走缓存的公开工厂；
  `Node.createTransient(...)`（SPI）不走缓存
- `Main/Demangle/DemangleInterface.swift` — `demangleAsNode(..., internsSubtrees:)` 开关，
  以及 cache-free 的 `demangleAsNodeTransient`
- `Store/NodeStoreBuilder.swift` — arena 版的同一套技巧（插入即 hash-consing）

完整记录：[../SubtreeInterning.md](../SubtreeInterning.md)
