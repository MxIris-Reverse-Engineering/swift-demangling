# 0007 - 短路查询去重 + TypeDecoder 漏扫守卫补齐

- **Proposal**: 0007
- **Author**: Mx-Iris
- **Status**: Implemented
- **Date**: 2026-08-02
- **Branch**: `feature/node-store`
- **Related**: `evolution/0006-interntree-and-demangler-postpass-memo.md`（本条修的是
  0006 横向排查**分类错误**留下的缺口）；`Documentations/KnownIssues.md` N6 / 第 1 条

## Summary

PR #6 第三轮 code-review 后逐条复核，15 条发现里判定为「真实且值得修」的两条：

1. **`first(of:)` / `contains(_:)` 按路径计价**（`Store/DemanglingNode+Sequence.swift`）
   ——公开 API，共享 DAG 上指数级，实测 22 层 18.2 秒且无上界。
2. **`TypeDecoder` 两处漏扫的越界**（`Main/TypeDecoder/TypeDecoder.swift`）——本 PR
   自己修了同款模式的一处，没有横向排查兄弟位置。

其余 13 条的裁决（4 条误报/刻意设计、9 条属实但不修）记录在
`Documentations/KnownIssues.md` 第二部分 N1–N8。

## Motivation

### 一、短路查询：0006 的分类错误

0006 把整库沿子节点下降的遍历分成四类，其中「按出现次数是文档化语义」一类点名
`first(of:)` / `all(of:)` 等公开遍历原语**不动**，理由写的是「`all(of:)` 按出现次数
枚举是文档化的预期语义」。

这个理由对 `all(of:)`、`filter(of:)`、`preorder()` 家族完全成立——它们**枚举**逻辑树，
出现次数就是正确答案。但它被顺手套到了 `first(of:)` 和 `contains(_:)` 上，而这两个是
**短路查询**：只回答「先序第一个是谁」「有没有」，一个共享实例出现多少次对答案毫无影响。

讽刺的是，0006 修 `identifier` 时给出的理由正是「其中运算符组在类型子树上永远扫空、
独自耗尽整个路径数」——而 `identifier` 当时用的就是 `first(of:)`。也就是说 0006
**修掉了 `first(of:)` 的一个调用点，却让 `first(of:)` 本身继续按路径计价**，任何其他
调用方（含下游消费方）踩的是同一个坑。

**实测**（60 层加倍 DAG 的前缀，树中无 `.functionType` 故无法短路）：

| 共享层数 | `contains(.functionType)` | `first(of: .functionType)` | `identifier`（0006 已去重） |
|---|---|---|---|
| 10 | 0.0051s | 0.0049s | 0.0001s |
| 14 | 0.0735s | 0.0712s | 0.0001s |
| 18 | 1.1505s | 1.1434s | 0.0001s |
| 20 | 4.6400s | 4.6121s | 0.0001s |
| 22 | **18.2475s** | **18.2430s** | 0.0001s |

精确每 2 层 ×4。60 层即 2^60，永不返回。**最坏情况恰是最常见的用法**：查询一个树中
不存在的 kind 时无处短路，必须走完整个路径空间。

`main` 同样存在，非本 PR 引入。

### 二、TypeDecoder：修了一处没扫兄弟

本 PR 在 `decodeMangledTypeDecl`（`TypeDecoder.swift:1167` 附近）加了
`guard node.hasChildren`，注释写明理由是「无子节点的 `.type` 可由公开 API 构造
（`Node.createTransient`、`NodeStoreBuilder.intern(kind:)`）」。但同文件的
`decodeTypeSequenceElement` 有一模一样的裸 `node.children[0]`，未同步修复——同一个
畸形节点经 tuple 元素而非 bound-generic 实参到达时，仍然是进程崩溃而非抛
`TypeLookupError`。

相邻还有第二处：`case .tuple` 分支的 `element.children[typeChildIndex]` 无边界检查，
**两条**路径可越界——空的 `.tupleElement`（下标停在 0，无元素）与只含
`.tupleElementName` 的 `.tupleElement`（标签占用 0，下标推进到末尾之后）。

`decodeTypeSequenceElement` 另外缺了所有兄弟解码入口都有的 `depth <= maxDepth` 检查。

**与既有暂缓决策的关系**：`KnownIssues.md` 有一条范围级决策——「下游未使用 TypeDecoder，
故 TypeDecoder 范围内的健壮性问题本轮不修」。严格按它，本条应直接进 KnownIssues。
但本 PR 已经破了这个例（修了 1167 那处），既然修了一处，「确认为真必须横向排查同类」
就要求扫完；留下「修了一半」的状态比两边都修或两边都不修更难解释。

## Detailed design

### 短路查询去重

在 `extension DemanglingNode where Self: Sequence, Self.Element == Self`（`identifier`
所在的同一个扩展）上新增去重版重载，覆盖四个入口：`first(of kind:)`、
`first(of kinds:...)`、`contains(_ kind:)`、`contains(_ kinds:...)`，共用私有辅助
`firstNodeInDedupedPreorder(matching:)`——显式栈 + `Set<PrintCacheIdentity>` 去重，
子节点逆序入栈保持先序，命中即返回。

**为什么挂在这个扩展上**：它比 `Sequence where Element: DemanglingNode` 上的原实现
约束更强（`Element == Self` 强于 `Element: DemanglingNode`），Swift 重载解析选更具约束者，
编译无歧义（已验证）。`Node` 与 `NodeReference` 两个表示共用一份实现，不存在只修一侧的风险。

**正确性**：与 0006 给 `identifier` 的论证同构——重复访问一个共享实例，不可能包含首次
访问没有的东西，故「先序第一个匹配」与「是否存在匹配」的答案严格不变。

**保持不动的**：`all(of:)`、`filter(of:)`、`preorder()` / `inorder()` / `postorder()` /
`levelorder()`。它们枚举逻辑树，出现次数是正确答案（`KnownIssues.md` N6）。

**已知的绕过路径**：显式写 `node.preorder().first(of:)` 会拿到 `Sequence` 上的重载，
重新按路径计价。这是重载解析的必然结果，非缺陷；已在 `AGENTS.md` 与 N6 中标注。

### TypeDecoder 守卫

- `decodeTypeSequenceElement`：入口加 `depth <= Self.maxDepth`；`.type` 解包前加
  `guard node.hasChildren`。
- `case .tuple`：解码元素类型前加 `guard typeChildIndex < element.children.count`。

## Alternatives considered

- **改 `Sequence where Element: DemanglingNode` 上的原实现直接去重**：对任意 Sequence
  而言，去重同样不改变 `first`/`contains` 的答案，所以是安全的；但会给每次调用（含对
  `children` 这类小集合的调用）加一次 `Set` 分配，是净损失。挂在更具约束的扩展上只让
  整树查询付这个成本。
- **给去重版本换个新名字**：不破坏重载解析，但公开 API 多出一组近义方法，且旧名字仍是
  陷阱——调用方不会知道该用哪个。
- **全面加固 TypeDecoder 的近百处 `children[N]`**：超出本批范围，且与 KnownIssues 的
  TypeDecoder 范围暂缓决策冲突。本条只修「本 PR 自己修了一半」的那个模式及其直接相邻的越界。

## Impact

- 行为不变：全量测试套件通过（471 → **475** tests / 24 suites），4,573,306 符号语料
  零 demangle 失败、零节点树失配、零 remangle 失配。
- 性能：仅影响此前会指数爆炸的输入。常规符号上新增一次 `Set` 分配与哈希，语料对拍无可测差异。
- API：无签名变更。`first(of:)` / `contains(_:)` 的**返回值**在所有输入上均不变，只是
  代价从路径数降到节点数。

## Migration notes

无。

## 回归测试（修复前失败、修复后通过，永久保留）

| 测试 | 修复前 |
|---|---|
| `DefectRegressionTests.shortCircuitKindQueriesFinishOnADoublingDag` | 30 秒超时判负 |
| `DefectRegressionTests.shortCircuitKindQueriesFinishOnADoublingDagStore` | 30 秒超时判负 |
| `DefectRegressionTests.typeDecoderRejectsAChildlessTypeInsideATupleElement` | 进程崩溃（`Index 0 out of range for empty Node.Children`） |
| `DefectRegressionTests.typeDecoderRejectsTupleElementsWithoutATypeChild` | 进程崩溃（同上，两种形状各一次） |

前两个同时断言答案不变（先序第一个 `.identifier` 仍是 `"G"`），确保去重没有改变语义。

## 横向排查

- **短路查询**：全库检索 `preorder()` / `postorder()` 等遍历后接 `first` / `contains`
  的写法——`Sources/` 与 `Tests/` 均无，故库内不存在绕过新重载的调用点。库内对整树的
  短路查询也已全部收敛（`identifier`、`findGenericParamsDepth` 在 0006 已改为显式去重
  遍历）。搜到的 `.contains(` 全部是 `DemangleOptions` 这个 `OptionSet` 的成员测试，无关。
- **`.type` 裸解包**：逐一核实 `TypeDecoder.swift` 中全部 7 处 `kind == .type` 解包，
  现均有守卫——129（`hasChildren`）、1009（本条新增）、1167（本 PR 已加）、1243
  （`!children.isEmpty`）、1276（同）、1440（`children.count == 1`），另 1059 / 1110
  两处在 `guard` 内。该模式已全覆盖。
- **未纳入本批**：`TypeDecoder.swift` 中其余近百处 `children[N]` 索引的边界正确性未逐一
  核实，沿用 KnownIssues 的 TypeDecoder 范围暂缓决策；`KnownIssues.md` 第 1 条同轮已把
  会 trap 的整数转换清点从「三处」补全到实测的 8 处。
