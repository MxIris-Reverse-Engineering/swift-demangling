# 0003 - Review Hardening: 冻结移交的 NodeBuilder 与按图计价的整树遍历

- **Proposal**: 0003
- **Author**: Mx-Iris
- **Status**: Implemented
- **Date**: 2026-07-30
- **Branch**: `feature/node-store`
- **Related**: `Documentations/KnownIssues.md`（本轮关闭其原第 3 条，新增第 3–5 条）

## Summary

PR #6 的 max 级 review 复验确认了一组集中在「整树遍历健壮性」上的问题。本轮修复其中
两个可以在**源头**关闭的问题类，并更正一处与实现矛盾的 API 文档：

1. **环类**：`NodeBuilder` 泄漏活引用 → 环状 `Node` 可构造 → 全库无界遍历死转/OOM。
   修法是收口唯一制造入口，而非给每个遍历加环检测。
2. **DAG 放大类**：interning 与替换回引使节点树实为共享图；无记忆化的整树重建按
   **路径数**计价（指数），本轮全部改为按**节点数**计价（线性）。
3. `TypeDecoder` store 路径入口注释声称「不物化 `Node` 树」，与实现矛盾，更正。

其余复验确认但暂缓的问题（打印缓存回放越过深度上限、2MB 探针窗口、store 路径 O(k²)）
记入 `KnownIssues.md` 第 3–5 条。

## Motivation

review 实测数据（均为纯公开 API 或真实 mangled 字符串触发）：

- `NodeBuilder.build()` 返回内部活实例，`addChild(build())` 两行构出自环；
  `isSpecialized` 在环上纯 CPU 死转（RSS 纹丝不动，内存看门狗抓不到），
  `getUnspecialized` 无上限涨内存（实测 ~60 MiB/s）。
- 一个 65,538 字符的合法往返符号 demangle 出 **48 个唯一节点**，无 memo 的 `copy()`
  展开成 **131,070** 个节点；120 字符的 bound-generic 符号（64 个唯一节点）的
  `description` 是 **366MB** 字符串；58 节点图驱动 `Rewriter.visit` 调用 **720,891** 次。
- 合成的 `Codable` 逐层递归（深树爆栈——库里其他所有整树遍历都已为此迭代化，唯它漏网）
  且按路径展开共享子树（同样的指数放大，还会写进持久化数据）。

## Scope

| 部件 | 变更 |
|---|---|
| `NodeBuilder`（`Node.swift`） | 冻结移交不变量：`node` 返回分离快照、`build()` 返回后与该节点脱钩、`init(_:)` 浅播种、非变异 helper 加 `detached` 防护 |
| `Node.copy()` / `replacingDescendant` | 按源实例身份记忆化，保共享 |
| `Node.Rewriter.rewrite` | 同上；`visit` 升级为「每唯一实例一次」的纯函数契约 |
| `Node.description` | 共享内部子树首现标 `(shared #N)` 展开、复现 `(see #N)` 不展开；叶子豁免 |
| `Node: Codable` | 换为扁平节点表格式（迭代、保共享、环不可表示）；**破坏性格式变更** |
| `TypeDecoder`（注释） | store 路径入口如实描述每 decl 物化与 O(k²)，指向 KnownIssues |
| `KnownIssues.md` | 关闭原第 3 条（环），新增第 3–5 条 |

## 关键设计与取舍

### 1. 环：收口制造入口，而不是加环检测

环的唯一制造途径是 `NodeBuilder` 把它持续变异的实例泄漏给外界（`build()` 与 `node`
都返回活引用）。修复选择让**builder 变异的实例永不外泄**：

- `node` 返回浅快照（新实例、共享 children——节点在 builder 之外不可变，共享安全且 O(1)）；
- `build()` 返回当前实例后立刻换上它的浅快照继续，返回值从此冻结；
- `init(_ node:)` 从深拷贝改为浅播种：builder 只变异根节点的 payload，根级隔离即足够，
  O(1) 且不再有「把共享图塞进 builder 就展开 720k 节点」的坑；
- 非变异 helper 有若干「非法索引时 `return self`」的快路径，统一过 `detached(_:)` 防护。

**取舍一（sever vs trap）**：`build()` 后 builder 保持可用（后续变异落在下一次 `build()`
的结果上），而不是按旧文档「build 后不应再用」升级为 precondition 崩溃。sever 让误用
自动变成正确行为，还顺带让 builder 支持「构建变体序列」的合法模式；trap 只会把静默
错误换成崩溃。旧文档措辞已更新。

**取舍二（不给遍历加环检测）**：`isSpecialized` / `getUnspecialized` / hash / intern
一族保持无环检测——环已不可构造，逐遍历加「在途集合」是打地鼠且拖慢热路径。
`isSimpleType` / `needSpaceBeforeType` 既有的步数上界保留作纵深防御。

### 2. DAG：memo 语义按「实例」而非「路径」

interning（`main` 已默认开启）与替换回引使 demangle 产物是共享图。重建类遍历
（`copy` / `replacingDescendant` / `rewrite`）在共享树上的「每路径一次」语义本就不是
良定义的（同一实例的多次 visit 结果无处可分别存放），「每唯一实例一次」是唯一自洽
语义，也把成本从路径数（指数）降到节点数（线性）。`Rewriter.visit` 由此获得明确的
纯函数契约，已写入文档。

**取舍三（`Sequence` 保持路径语义）**：`preorder()` 等遍历与 `all(of:)` 数的是逻辑树中
的**出现次数**（`(Int, Int)` 里 `all(of: .structure)` 应返回两次），去重会改变正确答案。
共享深图上遍历成本等于路径数，这与上游 C++（同样按替换共享节点、靠深度上限兜底）一致，
属逻辑树的固有属性，不改。

**取舍四（`description` 标记而非截断）**：输出上限用「共享内部子树只展开一次」实现，
而不是武断的行数上限——dump 因此按图大小线性有界，且共享标记对调试 interning 反而
是增量信息。叶子豁免标记（每个重复叶子标记本身就占一行，纯噪声）。无共享的树输出
逐字节不变。

### 3. Codable：扁平节点表

`{"nodes": [postorder 行], "root": 索引}`，children 以表索引引用。三个性质一次拿到：
两趟都是迭代（深树安全）、每唯一节点恰好编码一次（体积按图线性）、解码校验
`childIndex < 自身索引` 使环**不可表示**。解码走普通构造，不过 `NodeCache`
（任意外部输入不得 pin 全局缓存）。

**取舍五（破坏性格式变更，不做旧格式回退解码）**：合成格式在深树上爆栈、在共享树上
指数展开——能安全解码的存量数据本就只有浅而无共享的小树；为它维护一条仍会爆栈的
递归回退路径得不偿失。判断此 API 无实际存量数据（库内外均无使用点），直接切换。

## 影响面

- **`NodeBuilder` 语义**：`node` 每次访问返回不同实例（旧代码若依赖其身份稳定需调整，
  未发现使用点）；`build()` 后 builder 仍可用；`init(_:)` 播种共享子树而非深拷贝
  （根级变异隔离不变）。
- **`description`**：仅共享树新增 `(shared #N)` / `(see #N)` 标记；无共享树逐字节不变。
- **`Codable`**：新旧格式互不兼容。
- **性能**：`copy` / `rewrite` / `replacingDescendant` 在共享图上从指数降为线性；
  `NodeBuilder.init(_:)` 从 O(树) 降为 O(1)。
- 测试：`DefectRegressionTests` 的环测试改写为「不可构造」断言；新增
  `SharedDAGTraversalTests`（9 项：copy/播种/替换/重写的保共享与计价、description
  标记与格式保持、Codable 往返/深链/防环/线性体积）。

## 迁移/升级注意事项

- 依赖 `build()` 返回值与后续 `builder.node` 为同一实例的代码（即旧的活引用行为）
  不再成立——这正是被修复的缺陷本身。
- 用旧版本编码的 `Node` JSON/plist 数据无法用本版本解码，需用旧版本读出后重编码。
- `Rewriter` 子类若在 `visit` 里做按出现次数的计数或位置相关变换，行为改变
  （旧行为在共享树上本就未定义）；改用 `preorder()` 遍历统计出现次数。
