# 遍历的计价：按路径，还是按节点

> 概念篇。读完你会知道：为什么一个只有 48 个节点的符号能让遍历跑 13 万次、什么时候
> 可以加 memo、什么时候加了就是错的，以及新写遍历代码时该问自己什么。
> 前置：[SharedStructureAndDAG.md](SharedStructureAndDAG.md)。

## 1. 一个反直觉的现象

这两行代码，跑在同一棵树上：

```swift
node.identifier              // 0.0001 秒
node.first(of: .identifier)  // 18.2 秒       ← 修复前
```

树只有几十个唯一节点。差了十几万倍。这不是常数因子的问题，是**计价方式**的问题。

## 2. 树的遍历 vs DAG 的遍历

在**真正的树**上，「访问每个节点一次」的遍历是 O(n)，这是常识。这个常识成立的前提是：
从根到任何节点**只有一条路径**。

在 **DAG** 上（本库的树物理上都是 DAG，原因见
[SharedStructureAndDAG.md](SharedStructureAndDAG.md)），一个节点可以被多个父节点指着，
从根到它可能有很多条路径。如果你的遍历长这样：

```swift
func walk(_ node: Node) {
    process(node)
    for child in node.children {
        walk(child)          // ← 无条件下探
    }
}
```

那么被 k 条路径指到的节点，就会被处理 **k 次**。这个遍历的成本不是节点数，是**路径数**。

## 3. 手算一下路径数

看这个「每层都共享」的结构：

```
层 0:            A                 每个节点的两个 children
                / \                都指向下一层的同一个节点
层 1:          B   B               （B 是一个实例，画两次只是为了看清连线）
              / \ / \
层 2:        C   C   C
            / \ / \ / \
层 3:      D   D   D   D
```

数一数：

| 层数 | 唯一节点数 | 从根到最底层的路径数 |
|---|---|---|
| 2 层 | 2 | 2 |
| 4 层 | 4 | 8 |
| 6 层 | 6 | 32 |
| 10 层 | 10 | 512 |
| 20 层 | 20 | 524,288 |
| 22 层 | 22 | **2,097,152** |

节点数是**线性**增长（每层 +1），路径数是**指数**增长（每层 ×2）。

「指数级」具体意味着什么，看实测（一次找不到匹配、因此无法提前退出的查询）：

| 深度 | 耗时 |
|---|---|
| 10 层 | 0.005 秒 |
| 14 层 | 0.074 秒 |
| 18 层 | 1.15 秒 |
| 20 层 | 4.64 秒 |
| 22 层 | **18.2 秒** |

**每加两层，时间乘以 4。** 再加十层就是几个小时。这类结构不需要恶意构造——substitution
back-reference 天然会产生共享，泛型嵌套一深就有。

## 4. 三个真实案例

本项目已经踩过四次，全都是同一个形状：

| 案例 | 现象 | 修复 |
|---|---|---|
| `Node.copy()` / `Node.Rewriter`（evolution 0003） | 一个 **48 个唯一节点**的真实符号，拷贝时展开成 **131,070** 个节点；`Rewriter` 在 58 节点的图上访问 **720,891** 次 | 按实例身份 memo，重建过的子树复用 |
| remangler 的 `deepEquals`（evolution 0005） | 签名里有两份「实例不同但结构相等」的共享泛型子树时，`mangleAsString` 按 2^N 增长 | 记住「这一对已经证明相等」 |
| `NodeCache.internTree` + demangler 后处理（evolution 0006） | 一个 **131 字符**的构造符号就能把默认的 `demangleAsNode` 拖到指数级 | 遍历期间记住每个源实例的处理结果 |
| `first(of:)` / `contains(_:)`（evolution 0007） | 就是第 1 节那个 18.2 秒 | 按实例身份去重的单次遍历 |

**注意最后一个案例的教训**：0006 那轮做过一次横向排查，但把 `first(of:)` 误归进了
「按出现次数是正确语义」那一类，于是漏掉了。**分类错误比漏看更危险**——它会让问题看起来
已经审过了。

## 5. 解法：memo（记忆化）

「这个实例我处理过了，结果是它」——记下来，下次直接返回：

```swift
func walk(_ node: Node) -> Result {
    if let cached = resultByIdentity[ObjectIdentifier(node)] {
        return cached                       // ← 第二条路径走到这里，直接返回
    }
    let result = ...                        // 正常处理，递归 children
    resultByIdentity[ObjectIdentifier(node)] = result
    return result
}
```

加上这一句，成本从**路径数**回落到**节点数**。

三个实现要点：

1. **键用实例身份**（`ObjectIdentifier`），不是结构哈希——结构哈希本身就要走整棵子树，
   等于没省。store 路径上对应的键是节点下标。
2. **作用域是「本次遍历期间」**，遍历结束就丢。跨调用缓存需要考虑失效问题，是另一回事。
3. **成对遍历（比较两棵树）memo 的是「这一对」**，比如 `deepEquals` 记的是
   「(左实例, 右实例) 已证明相等」。

本库带 memo 的遍历：`NodeCache.internTree`、`Node.copy()` / `replacingDescendant`、
`Node.Rewriter.rewrite`、`Node.==` / `hash(into:)`、remangler 的 `deepEquals`、
`NodeStore.materializeNode`、`NodeReference.structurallyEquals` / `structuralHash`。

## 6. 什么时候**不能** memo

memo 会改变「一个节点被处理几次」。如果处理次数本身是语义的一部分，加 memo 就是**改变
行为**，不是优化。

### 情况一：枚举类操作

```swift
node.all(of: .identifier)     // 列出所有 identifier
node.preorder()               // 前序遍历整棵树
```

这些枚举的是**逻辑树**。`Swift.Int` 在符号里出现两次，就应该列两次——**出现次数就是
正确答案**。所以本库刻意让它们保持按路径计价（裁决记录：`KnownIssues.md` N6）。

### 情况二：回调是用户代码

`TypeDecoder` 每解码一个节点就调用一次 `TypeBuilder` 的回调。给它加 memo，回调次数就
从「每次出现一次」变成「每个实例一次」——如果调用方的 builder 是有状态的（比如在计数），
行为就变了。

这是一个**公开契约的变更**，不能混在「无行为变化的性能修复」里做，所以它至今挂在
`KnownIssues.md` 第 6 条上等一个单独的决策。

> 对照：`Node.Rewriter` 当年做过同样的取舍，选择了改语义（`visit` 现在每个唯一实例只
> 跑一次，因此必须是纯函数），并写进了文档和迁移说明（`KnownIssues.md` N7）。**取舍
> 本身可以选，但必须明示。**

### 情况三：输出要跟别人逐字节对拍

`Node.description` 的转储要跟 Swift runtime 的输出逐字节一致，而 runtime 会展开每一次
出现。所以它刻意**不 memo**，改用一个 8MB 的输出预算兜底（超了就截断并注明）。

想看去重版的转储，用 `sharedStructureDescription`。

## 7. 短路查询为什么可以安全去重

`first(of:)`（第一个匹配是谁）和 `contains(_:)`（有没有）能去重，理由要说清楚：

> 重复访问一个已经访问过的实例，**不可能**找出它第一次访问时没找到的东西——它的整棵
> 子树在第一次就完整走过了。

所以「preorder 里的第一个匹配」和「存不存在」这两个答案，在去重前后**完全相同**。
而成本从路径数降到节点数。

⚠️ **注意一个绕过**：

```swift
node.first(of: .identifier)              // ✅ 去重版本，按节点计价
node.preorder().first(of: .identifier)   // ❌ 命中 Sequence 上的重载，退回按路径计价
```

去重版本挂在「直接查询节点」的重载上。显式先要一个 `preorder()` 序列，拿到的就是通用的
`Sequence` 版本了。要去重就直接查节点。

## 8. 新写遍历代码时的自检清单

在这个代码库里加任何一个「沿 children 往下走」的函数，先问三个问题：

1. **这个函数付的是节点数还是路径数？**
   无条件递归 children ⇒ 路径数 ⇒ 在共享结构上是指数级。

2. **出现次数是不是答案的一部分？**
   - 是（枚举、计数、按出现触发回调）⇒ 保持按路径，但要在文档里写明，并考虑加总量上限；
   - 否（查询、判等、重建、规范化）⇒ **必须加 memo**。

3. **同一个模式在别处还有没有？**
   本项目四次事故里有三次是「修了一处，同款还有两处」。确认一个问题为真之后，
   **在整个库里搜同一个形状**，一次修完（这是项目 code-review 规定的动作）。

另外：这类问题**必须带回归测试**。本库的做法是构造一个加倍 DAG（每层共享），断言查询能
在秒级完成——修复前这些测试会 30 秒超时判负。见
`DefectRegressionTests.shortCircuitKindQueriesFinishOnADoublingDag`。

## 在本库的哪里

- `Store/DemanglingNode+Sequence.swift` — 遍历与查询的单一泛型实现（去重版与枚举版
  的分界就在这里）
- `Node/NodeFactory.swift` — `internTree` 的 memo
- `Node/Node+Rewriter.swift`、`Node/Node.swift` — `rewrite` / `copy` 的 memo
- `Main/Remangle/Remangler.swift` — `deepEquals` 的成对 memo
- `Tests/DemanglingTests/DefectRegressionTests.swift` — 加倍 DAG 的回归测试

相关记录：evolution `0003` / `0005` / `0006` / `0007`、[../KnownIssues.md](../KnownIssues.md) N6 / N7 / 第 6 条
