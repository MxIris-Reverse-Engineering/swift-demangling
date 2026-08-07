# arena 存储：为什么 12 字节能打赢 48 字节

> 概念篇。读完你会知道：一个 class 节点的 48 字节都花在哪、为什么改成 struct 也救不了、
> arena 是什么、`NodeStore` 的 12 字节布局怎么来的，以及用 arena 要放弃什么。
> 前置：[Interning.md](Interning.md)。后续：[TraversalCost.md](TraversalCost.md)。

## 1. 先看一个数字

`Node` 里真正的信息只有：一个 `kind`（2 字节就够）、一段文本或一个整数、几个 children
引用。可实际上**每个节点要占 48 字节**。

多出来的部分不是浪费的代码写出来的，而是**用 class 存东西必然要付的税**。这一篇就是
讲怎么把这笔税整个绕开。

## 2. 一个 class 实例到底占多少内存

拆开算：

```
┌────────────────────────────┐
│ 对象头（16 字节）           │  ← 类型指针 8 字节 + 引用计数 8 字节
├────────────────────────────┤
│ kind（2 字节）             │
│ 对齐填充                    │
│ payload 枚举（17 字节）     │  ← 文本/整数/children，加上 1 字节的判别位
└────────────────────────────┘
   实际内容合计 41 字节
        ↓
   malloc 按固定档位分配 → 落进 48 字节的档位
```

四项开销，逐个解释：

**① 对象头（16 字节）** — 每个 Swift class 实例前面都有：一个指向类型元数据的指针
（运行时靠它做动态派发、`as?` 判断），一个引用计数字段。这是 class 的入场费，无法关闭。

**② malloc 档位** — 内存分配器不会精确给你 41 字节。它把内存切成固定档位（16、32、48、
64…），41 字节只能落进 48 字节那档，**7 字节直接浪费**。

**③ ARC（自动引用计数）** — 每次把节点传给函数、存进数组、赋值给变量，运行时都要把
引用计数 +1 / -1。这是**原子操作**，比普通加法贵得多，而且在多线程下会争抢缓存行。
一次 demangle 会做成千上万次这种增减。

**④ 分配次数** — 每个节点一次独立 malloc。分配本身有成本，而且分出来的对象在内存里
是散的——CPU 缓存喜欢连续访问，散落的对象意味着每次跳转都可能是一次缓存未命中。

对照上游 C++ 实现：`Demangle::Node` 是 24 字节的 struct，从一块大缓冲里顺序切出来，
没有对象头、没有引用计数。**差距全部来自「用 class」这个选择本身，不是实现细节。**

## 3. 那把 `Node` 改成 struct 不就行了？

不行，会更糟。

Swift 的 struct 是值类型，但 `children` 还得是个 `[Node]` 数组——**数组的存储仍然在
堆上**，而且每个数组缓冲另有约 32 字节的头部和自己的引用计数（写时复制机制需要它）。
于是：

- 每个节点还是至少一次堆分配（数组的）；
- 引用计数还在（数组缓冲的）；
- 外加一条新麻烦：struct 变大以后，每次传参、赋值都要**整体拷贝**，CPU 反而更差。

**struct 真正的价值不是「不用 class」，而是「布局精确、可以平铺进一块连续缓冲」。**
所以正确形态不是「struct + 数组」，而是——

## 4. arena 是什么

**arena（区域式存储）：开一块大的连续缓冲，所有节点一个挨一个平铺进去，节点之间用
「下标」而不是「指针」互相引用。**

```
传统做法（每个节点一次 malloc，散落在堆上）：

   堆:  [节点A]        [节点C]
              [节点B]           [节点D]      ← 位置随机，互相用 8 字节指针指

arena（一块连续缓冲，顺序追加）：

   nodes: [ A ][ B ][ C ][ D ][ E ]...       ← 下标 0,1,2,3,4，用 4 字节下标互相指
                 ↑
                 「下一个空位」的偏移，分配就是把它往后推
```

那个「把偏移往后推」的分配方式叫 **bump allocator（碰撞指针分配）**：没有空闲链表、
没有搜索、没有对齐计算，分配成本接近零。代价是**不能单独释放某一个节点**——但这正好
符合本库的用法：一个二进制的符号库要么整体留着，要么整体丢掉。

顺带的好处：

- **释放是 O(1)**：整块缓冲一起丢，不必逐个析构，也不必逐个减引用计数；
- **缓存友好**：节点在内存里连续排列，遍历时 CPU 预取器能发挥作用；
- **没有 ARC**：下标是普通整数，传来传去不触发任何原子操作。

## 5. `NodeStore` 的 12 字节节点

```swift
struct CompactNode {                  // size 12, alignment 4
    var kindAndPayloadKind: UInt16    // bit 0-8: kind 序号；bit 9-11: payloadKind；bit 12-15: 保留
    var payloadWord0: UInt32
    var payloadWord1: UInt32
}
```

### 为什么两个字段就够

因为 `Node` 有一条既有的不变量：**contents 和 children 互斥**——一个节点要么带文本/
整数，要么带 children，不会同时有。所以两个 32 位字的含义可以由 `payloadKind` 复用：

| payloadKind | payloadWord0 | payloadWord1 |
|---|---|---|
| `none` | — | — |
| `index` | 整数的低 32 位 | 整数的高 32 位 |
| `text` | 在字符串表里的偏移 | 字节长度 |
| `oneChild` | child 的下标 | — |
| `twoChildren` | child 0 的下标 | child 1 的下标 |
| `manyChildren` | 在 edges 缓冲里的起点 | children 个数 |

### 为什么只内联两个 children

因为实测分布摆在那里（49k 语料）：

```
oneChild      ████████████████████████████████████  ~67%
manyChildren  ████████                              ~16%
twoChildren   ██████                                ~12%
text          ███                                    ~5%
```

**近八成节点只有 0 到 1 个 child。** 把最多两个 children 直接放进 payload、只让 3 个
以上的外溢到另一块缓冲，是花最少的空间覆盖最多的情况。

### kind 只用 9 位

`Node.Kind` 目前有 373 个 case，9 位能表示 512 个，余量 139。存的是这个 kind 在
`allCases` 里的**位置序号**。

⚠️ **这个序号只在单次进程运行内有效，不是序列化格式**——加一个 kind 就会让后面所有序号
偏移。将来要把 store 存盘（Phase 4），必须自带一张稳定的 kind 映射表。

## 6. 三块缓冲

一个 store 就是三个连续数组：

```
nodes:     [ CompactNode #0 ][ #1 ][ #2 ][ #3 ]...       12 字节/个，主 arena
edges:     [ 3 个以上 children 的节点，把 children 下标连成一段放这里 ]   4 字节/个
textBytes: [ S w i f t I n t m a i n f o o ... ]         去重后的 UTF-8 字节
```

拿 `Structure(Swift.Int)` 走一遍：

```
#0  Module      payloadKind = text,        word0 = 0（偏移）, word1 = 5（"Swift" 的长度）
#1  Identifier  payloadKind = text,        word0 = 5,          word1 = 3（"Int"）
#2  Structure   payloadKind = twoChildren, word0 = 0,          word1 = 1     ← 指向 #0 和 #1

textBytes: S w i f t I n t
           └─#0─┘ └#1┘
```

三个节点、36 字节，加上 8 个文本字节。同样的内容用 class 要 144 字节 + 两个堆字符串。

**容量上限**：`nodes` 最多 42.9 亿个节点（`UInt32` 下标空间），`edges` 和 `textBytes`
各最多 4 GB。越界一律 `precondition` 失败，不静默截断。

**下标为什么比指针好**：4 字节 vs 8 字节（这正是本库 12 字节能反超 C++ 24 字节的地方）、
不参与 ARC、整块缓冲可以直接 `memcpy` 或 mmap（这是将来做持久化的基础）。

## 7. intern 表：只存下标的哈希表

arena 里同样做 hash-consing（插入前先查有没有结构相同的，见 [Interning.md](Interning.md)），
所以 builder 需要哈希表。这里有个值得学的细节。

**开放寻址（open addressing）**：哈希冲突时不挂链表，顺着数组往后找下一个空槽。

**槽里只存 4 字节下标，不存键**：要比较键的时候，拿下标回缓冲区把内容取回来比。

为什么这么设计——数字最有说服力：

```
用普通字典（每个键各自持有一份 12 字节节点值 / children 下标数组 / String 副本）
    → 全语料上 intern 表本身占约 10 MB

改成「槽只存下标」的开放寻址表
    → 约 2 MB
```

节点数据在缓冲区里本来就有一份，**没有理由为哈希表再存一份拷贝**。

## 8. freeze：用类型系统保证不可变

```swift
var builder = NodeStoreBuilder()          // ~Copyable：不可复制
let rootIndex = try builder.demangle("$s4main3fooyySi_SitF")
let store = builder.freeze()              // consuming：吃掉 builder
```

三个 Swift 特性各自在干一件事：

- **`~Copyable`（不可复制）** — 这个 builder 不能被复制，因此任何时刻只有一个所有者，
  **天然是单写者**。于是构建全程不需要任何锁。代价是不能跨线程共享：多线程批量场景应该
  每个线程一个 builder（合并 API 还没做）。
- **`consuming func freeze()`** — 这个方法**消费掉** builder：调用之后原来的变量不能再
  用。所以「构建完成后不再修改」不是靠文档约定，而是**编译器强制**的。
- **丢弃 intern 表** — freeze 时把三张哈希表整个扔掉，只留三块数据缓冲。省内存，
  而且冻结后的 store 是深度不可变的，可以安全地 `Sendable` 跨线程共享、读取不加锁。

⚠️ **副作用**：intern 表没了，冻结后的 store **无法再做哈希查找**。这就是为什么会有
`structurallyEquals` 这类线性比较 API——「我手上有一棵外面 demangle 出来的 `Node`，
想在 store 里找到它」只能靠遍历比对。

## 9. materialize（物化）：回到 `Node` 的桥

有些地方还需要真正的 `Node` 对象树：remangle（`Remangler` 刻意保持 `Node` 引擎）、
富文本打印 target 的回调、`TypeBuilder` 的交接点。`materialize()` 把 arena 里的紧凑
表示重新展开成一棵 `Node` 树。

两个必须知道的性质：

**① 物化出来的树是全新的，不进 `NodeCache`：**

```swift
let first  = reference.materialize()
let second = reference.materialize()
first == second    // true  —— 结构相等
first === second   // false —— 但不是同一个实例
```

所以 store 路径上**任何按 `===` / `ObjectIdentifier` 关联状态的下游逻辑都会失效**，
必须改成按结构关联（例如用 remangle 出来的字符串当键）。

**② 物化保留 DAG 共享**：同一个 store 下标在一次物化里只重建一次并复用实例。否则一个
重度共享的符号会被指数展开（SwiftUI 里的 `View.Body` 量级就是几十万节点）。

## 10. 实测收益

234,232 个符号（本机 dyld cache 里的 SwiftUI 语料，debug 构建）：

| 指标 | 实测 |
|---|---|
| 唯一节点 | 619,688 |
| 平铺存储合计 | **8.75 MB**（nodes 7.4 + edges 0.75 + text 0.57） |
| 每唯一节点 | 14.1 字节 |
| 每符号 | 37 字节 |
| 构建耗时 | 25.3 秒（`Node` 路径 28.5 秒，**更快**） |

注意最后一行：arena 路径不但更省内存，构建还**更快**——省下的 malloc 次数和引用计数
操作，超过了多出来的一次 intern 过程。

下游（MachOSwiftSection）迁移后：`NodeCache` 增长归零（此前每个镜像 +1.9 万叶节点 /
+56 万子树），store 本体 7 MB，释放 `Storage` 即整镜像回收。

## 11. 用 arena 要放弃什么

- **下标不带 store 身份**。`NodeStore.NodeIndex` 是个裸值。拿 A store 的下标去问 B
  store，落在范围内就静默读到无关子树，落在范围外还可能因为 edges / text 偏移未经检查
  而 trap。**同时持有多个 builder 时，保证不混用是调用方的责任。**
- **kind 序号不是序列化格式**（见第 5 节）。
- **单写者**：不能跨线程共享 builder。
- **物化不是免费的**，且物化结果不 canonical（见第 9 节）。
- **已知短板**：`TypeDecoder` 的 store 路径目前**不是**零物化的，嵌套 k 层的类型合计
  O(k²)（`KnownIssues.md` 第 5 条）。

## 在本库的哪里

- `Store/CompactNode.swift` — 12 字节布局与位域
- `Store/NodeStore.swift` — 冻结后的不可变存储 + 物化
- `Store/NodeStoreBuilder.swift` — bump 追加、开放寻址 intern 表、`freeze()`
- `Store/NodeReference.swift` — 16 字节值句柄（store 引用 + 下标），行为对齐 `Node`
- `Store/DemanglingNode.swift` — 让 printer / TypeDecoder 同时支持两种表示的只读协议

完整记录：[../NodeStoreArena.md](../NodeStoreArena.md)、提案 `evolution/0001-node-store-arena.md`
