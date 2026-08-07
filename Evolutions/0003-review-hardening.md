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
| `Node.description` | 保持逐次展开（与 Swift runtime dump 逐字节一致），改用 8MB 输出上限兜底病态 DAG |
| `Node.sharedStructureDescription` | 新增 `@_spi(Internals)` 视图：共享内部子树首现标 `(shared #N)` 展开、复现 `(see #N)` 不展开；叶子豁免 |
| `Node: Codable` | **整体移除**（连带 `Node.Children` 的 conformance）；序列化改走 remangle 出的 mangled string |
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

**取舍四（`description` 字节上限，标记视图另开入口）**：本条曾按「共享内部子树只展开
一次」实现输出上限，理由是 dump 因此按图大小线性有界。该实现已推翻——它漏看了
`description` 的格式是一份**对外契约**：语料一致性测试（`DemanglingTestingSupport/
DemanglingTests.swift`）拿它和 Swift runtime 的 node dump 逐字节比对，而 runtime 是
逐次展开的。实测代价是 4,522,325 个符号里 **1,433,597 条不匹配（31.7%）**，整个测试
套件变红。

现在的取舍是把两件事解耦：

- `description` 恢复逐次展开，病态 DAG 用 **8MB 输出字节上限**兜底，超限即停并追加
  `... (truncated: …)`。上限只影响病态输入的尾部，不改变任何正常符号的一个字节。
- 标记视图移到 `@_spi(Internals) Node.sharedStructureDescription`，调试 interning 时
  仍然可用，且仍按图大小线性有界。

上限取 8MB 的依据：全量 dyld shared cache 语料（4,522,325 个符号）逐次展开的**最大
dump 是 496,018 字节**，超过 1MB 的符号 0 个，超过 100KB 的 652 个（0.014%）——真实
符号离上限有 16 倍余量，实践中永不触发。而它确实挡得住病态图：depth 40 的共享对图
（2^40 ≈ 10^12 条路径）0.17 秒停在 8,388,716 字节，同一张图的
`sharedStructureDescription` 是 5,389 字节。DFS 待办栈只按树形（每层每分支一项）增长，
爆炸的只有输出，所以对输出计费就够了。

### 3. Codable：整体移除

本条一度实现为扁平节点表（`{"nodes": [postorder 行], "root": 索引}`，children 以表
索引引用），以同时拿到迭代编解码、按图线性的体积、以及环不可表示。该方案也已推翻——
**`Node` 不再是 `Codable`**，`Node+Codable.swift` 删除，`Node.Children` 的
conformance 连带移除（它直接持有 `Node`，`Node` 不可编码后无法合成）。
`Node.Contents` 与 `Node.Kind` 的 conformance 保留：它们不含 `Node`，各自独立可用。

**取舍五（不自造节点编码，序列化就用 mangled string）**：这个 API 从一开始就是多余的
——一个 mangled symbol **本身就是**这棵树的序列化形式，而且在每一条上都更好：体积远小于
任何节点表编码；格式由 Swift ABI 定义，跨版本稳定，不像自造格式那样需要版本号和迁移
路径；round trip 天然保共享（重新 demangle 会重建 interning，不会按路径展开）；而且它
是工具链其余部分（编译器、runtime、LLDB、符号化管线）本来就在说的语言。存下
`try mangleAsString(node)`，读回时 `try demangleAsNode(_:)`，仅此而已。

顺带解决了扁平格式遗留的两个问题：它与合成格式互不兼容却没有版本标记，将来再改一次
仍会重演；以及在 `Node` 这样一个公共类型上，任何自造编码都会变成需要长期维护的兼容
包袱。注意 remangler 输出 `_$s` 前缀而常见输入是 `$s`，demangler 两种都接受，round trip
仍然闭合（`stripManglePrefix` 可用于规范化比较）；极少数节点树无法 remangle，`canMangle`
可以先判定。

## 影响面

- **`NodeBuilder` 语义**：`node` 每次访问返回不同实例（旧代码若依赖其身份稳定需调整，
  未发现使用点）；`build()` 后 builder 仍可用；`init(_:)` 播种共享子树而非深拷贝
  （根级变异隔离不变）。
- **`description`**：格式与 Swift runtime dump 保持逐字节一致（语料 4,522,325 个符号
  零不匹配）；仅当单次 dump 超过 8MB 时截断并标注，真实语料中无一触发。标记视图需改用
  `@_spi(Internals) sharedStructureDescription`。
- **`Codable`**：`Node` 与 `Node.Children` 不再 `Codable`（相对 main 与相对上一轮的
  扁平格式都是破坏性变更）。序列化改用 `mangleAsString` / `demangleAsNode`。
- **性能**：`copy` / `rewrite` / `replacingDescendant` 在共享图上从指数降为线性；
  `NodeBuilder.init(_:)` 从 O(树) 降为 O(1)。
- 测试：`DefectRegressionTests` 的环测试改写为「不可构造」断言；新增
  `SharedDAGTraversalTests`（10 项：copy/播种/替换/重写的保共享与计价、
  `sharedStructureDescription` 标记、`description` 在 2^40 路径图上的字节上限、
  无共享树两视图一致、remangle 序列化往返与保共享）。

## 迁移/升级注意事项

- 依赖 `build()` 返回值与后续 `builder.node` 为同一实例的代码（即旧的活引用行为）
  不再成立——这正是被修复的缺陷本身。
- 用旧版本编码的 `Node` JSON/plist 数据无法用本版本解码——`Node` 已不再 `Codable`。
  需用旧版本读出，改存 `try mangleAsString(node)` 的字符串；读回时
  `try demangleAsNode(_:)`。
- 自定义 `NodePrinterTarget` 必须显式实现 `write(_:context:)` 与
  `pushTypeReferenceScope(_:)`（两者都不再有默认实现）。照旧签名
  （`NodePrintContext?` / `Node?`）写的实现现在是编译错误而不是静默失效——把参数
  改成 `@autoclosure () -> …` 即可；只输出纯文本的 target 照 `String` 的
  conformance 转发一行了事。
- `Rewriter` 子类若在 `visit` 里做按出现次数的计数或位置相关变换，行为改变
  （旧行为在共享树上本就未定义）；改用 `preorder()` 遍历统计出现次数。
