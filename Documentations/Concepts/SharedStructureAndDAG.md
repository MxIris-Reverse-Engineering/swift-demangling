# 共享结构：为什么这棵「树」其实是图

> 概念篇。读完你会知道：为什么 demangle 出来的东西不能当普通树对待，共享是从哪来的，
> 以及它同时带来了什么好处和什么坑。
> 前置：无。后续：[Interning.md](Interning.md)、[TraversalCost.md](TraversalCost.md)。

## 1. 先说结论

`demangleAsNode` 返回的东西，**你会当它是一棵树，但它物理上是一张图**。

- 逻辑上：它是树。打印、remangle、按 Swift 语法理解它时，都当树看，没问题。
- 物理上：同一个节点实例可能被**多个父节点**指着。内存里没有那么多份。

这两句话不矛盾，但如果你只记住第一句，就会写出跑得指数级慢的代码，或者写出「同一个类型
被当成两个不同的类型」这类 bug。本文只讲清楚这一件事。

## 2. 树、图、DAG 分别是什么

对没接触过这套词的人，三句话：

- **树**：每个节点**只有一个**父节点。从根出发到任何节点的路径**唯一**。
- **图**：节点之间随便连。可能有环（A → B → A）。
- **DAG**（Directed Acyclic Graph，有向无环图）：介于两者之间——**允许一个节点有多个
  父节点，但不允许有环**。

画出来的区别：

```
       树                      DAG                     图（有环）
        A                       A                        A
       / \                     / \                      / \
      B   C                   B   C                    B   C
     /     \                   \ /                      \ /
    D       E                   D                        D
                                                         |
                                                         A   ← 环，本库不允许
```

DAG 里的 `D` 只有一份，`B` 和 `C` 指的是同一个 `D`。**从根到 `D` 有两条路径，但 `D` 只有
一个实例**——这句话是后面所有内容的种子。

本库的树是 DAG：**允许共享，不允许环**（环从公开 API 已不可构造，见第 6 节）。

## 3. 共享从哪来（两个来源）

### 来源一：mangling 格式自带的压缩

Swift 的符号编码里，同一个类型第二次出现时不重复写，而是写一个「参见前面第 N 个」的
反向引用（substitution back-reference）。真实例子：

```
$s4main3fooyyAA1SV_ADtF   →   main.foo(main.S, main.S) -> ()
                    ^^
                    这两个字符就是「参见前面出现过的那个类型」
```

demangler 遇到 `AD` 时**不会重新构造一棵 `main.S` 子树**，而是直接把已经建好的那棵接
上去。于是内存里是这个形状：

```
           Tuple
          /     \
  TupleElement  TupleElement          ← 两个不同的父节点
          \     /
           \   /
        Structure(main.S)             ← 一个实例
         /          \
   Module("main")  Identifier("S")
```

**这不是优化，是格式决定的。** 只要符号里有重复类型，你就会拿到共享结构。

### 来源二：interning（跨符号去重）

第二个来源是本库自己做的：结构相同的子树在全局只保留一份。这样一来共享不只发生在
**一个符号内部**，还发生在**符号之间**——一万个符号里的 `Swift.Int` 是同一个实例。

细节见 [Interning.md](Interning.md)。这里只需要知道：**默认的 `demangleAsNode` 返回的
树已经是高度共享的**。

> 顺带一提，就算你关掉 interning（`internsSubtrees: false`），来源一还在。
> 「共享」不是一个可以关掉的特性。

## 4. 共享带来什么好处

**内存**。实测 49k 个真实符号（SwiftUI / Foundation / 标准库等）：

| | 节点数 |
|---|---|
| 逻辑上的节点（把每次出现都算一遍） | 110 万 |
| 只对叶节点去重后的实例数 | 76 万 |
| 全子树去重后的实例数 | **20.2 万** |

同一批符号，从 110 万降到 20.2 万，**内存直接降到 1/5 左右**。对「把整个二进制的符号
全部 demangle 并留在内存里」这种用法（本库的主要场景），这是决定性的。

顺带还有一个好处：判断两棵子树是否相等，从「递归比较整棵子树」变成「比较一个指针」。

## 5. 共享带来什么坑

### 坑一：遍历会指数级变慢

回到第 2 节那句话：**从根到某个节点可能有多条路径**。如果你写一个「从根往下走，每遇到
一个节点就处理它，再对它的每个 child 递归」的遍历，那么被 k 条路径指到的节点，就会被
处理 k 次。

节点数是线性的，路径数可以是指数的。真实数据：一个只有 **48 个唯一节点**的符号，无脑
遍历会访问 **131,070** 次。

这是本项目最常见的性能事故类型，专门有一篇讲：[TraversalCost.md](TraversalCost.md)。

### 坑二：「按出现次数」的逻辑会算错

```swift
node.all(of: .identifier).count
```

这个返回的是**逻辑树上**的出现次数（`Swift.Int` 出现两次就算两次），不是实例个数。
两者在共享结构上不相等。**先想清楚你要的是哪个**：

- 要「这个符号里出现了几次」→ 出现次数，按路径走是对的；
- 要「涉及多少个不同的东西」→ 实例个数，必须按实例身份去重。

本库刻意让 `all(of:)` / `preorder()` 这类**枚举**操作保持按出现次数计数（那才是它们的
正确语义），而让 `first(of:)` / `contains(_:)` 这类**只问有没有**的查询按实例去重。

### 坑三：身份（identity）不再等于位置

因为实例被共享，「这个节点」和「这个位置上的节点」不是一回事：

```swift
// 两个参数位置下挂的类型节点是同一个实例
firstParameterType === secondParameterType   // true
```

如果你拿 `ObjectIdentifier` 当键存东西（「我给每个参数标个颜色」），两个参数会互相覆盖。
在 store 路径上还有反过来的陷阱：物化出来的树**每次都是新实例**，同一个节点两次物化
`===` 为 false。所以：

> **富文本 target、`TypeBuilder` 这类要给节点挂状态的消费方，必须按结构关联（例如用
> remangle 出来的字符串作键），不能按 `===` / `ObjectIdentifier`。**

细节见 [ArenaStorage.md](ArenaStorage.md) 的「物化」一节。

## 6. 为什么可以保证没有环

有环的话，任何遍历都会死循环。本库的保证来自两点：

1. demangler 只会把**已经建好的**子树接到新节点下面，不可能接一个还没建完的祖先；
2. `NodeBuilder`（唯一能修改树的公开入口）只交出**冻结的、脱离 builder 的**节点，
   所以你没法用公开 API 拼出一个「自己是自己后代」的节点。

不过少数几个公开的判定函数（`isSimpleType`、`needSpaceBeforeType`、`isProtocol`）仍然
带一个 64 步的解包上限——那是纵深防御，防的是「万一有人用别的方式拼出了环」，代价只是
超限时返回保守的 `false`。

## 7. 怎么亲眼看到共享

`node.description` **看不出来**共享——它按上游 Swift runtime 的行为，把每一次出现都
展开打印一遍（这是与 runtime 转储逐字节对拍的契约，不能改）：

```
kind=Structure          ← 出现两次，打印两次
  kind=Module, text="main"
  kind=Identifier, text="S"
kind=Structure          ← 其实是同一个实例
  kind=Module, text="main"
  kind=Identifier, text="S"
```

想看真实形状，用 `node.sharedStructureDescription`（`@_spi(Internals)`）：它把被多次
引用的子树只展开一次，标成 `(shared #N)`，后续出现处只打印 `(see #N)`。排查「为什么这
棵树遍历这么慢」时，这是第一手工具。

命令行侧的对照：`echo '<符号>' | xcrun swift-demangle --expand --tree-only` 输出的就是
展开形式（跟 `description` 一致）。

## 8. 一句话记住

> **节点数是线性的，路径数可能是指数的。凡是「沿着 children 往下走」的代码，都要先问
> 一句：我付的是节点数还是路径数？**

## 在本库的哪里

- 共享的产生：`Demangler`（substitution 回填）、`NodeCache`（interning）
- 观察工具：`Node.description` / `Node.sharedStructureDescription`
- 受影响最深的代码：所有整树遍历，见 [TraversalCost.md](TraversalCost.md)
- 相关裁决：[../KnownIssues.md](../KnownIssues.md) N6（枚举类操作按路径计价是刻意设计）
