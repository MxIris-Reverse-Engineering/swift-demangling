# 0006 - 按路径计价的整树遍历：`internTree` 等四处补 memo/去重 + 全库横向排查收口

- **Proposal**: 0006
- **Author**: Mx-Iris
- **Status**: Implemented
- **Date**: 2026-08-02
- **Branch**: `feature/node-store`
- **Related**: `Evolutions/0005-remangler-deepequals-memo.md`（同族上一条，其「横向排查」
  一节点名 `internTree` 是最后的单树遍历缺口——本条兑现）；
  `Evolutions/0003-review-hardening.md`（给重建类遍历补 memo 的那批）

## Summary

四处按**路径数**（2^N）而非节点数计价的整树遍历一批修复（前两处为本条主体，
后两处来自随批的全库横向排查），并对「按路径计价」这一缺陷家族做了一次全库
收口式排查（结果见文末）：

1. **`NodeCache.internTree`**（`Node/NodeFactory.swift`）——九个整树规范化/重建
   遍历中最后一个没有 per-walk identity memo 的。它唯一的捷径 `SubtreeKey` 探测
   以被探测节点**原始**子节点的身份为键，因此只在「自身子节点已是规范实例」时
   命中；一旦下方任何规范化替换过子节点（树内存在结构相等但实例不同的内部节点、
   或与此前 intern 过的结构重叠——批量跑批中第二棵树起的常态），所有共享实例
   探测必 miss，每条路径重下降一遍。
2. **`Demangler.setParentForOpaqueReturnTypeNodesImpl`**（`Main/Demangle/
   Demangler.swift`）——每个普通函数符号 demangle 都要跑的整子树后处理，纯递归
   无 memo。替换反向引用让原始 demangle 输出本身就是 DAG，于是**连
   `internsSubtrees: false` 的纯解析路径都是指数级**。
3. **`Node.findGenericParamsDepth()`**（`Node/Node+Conversions.swift`，横向排查
   发现）——公开值查询，existence 守卫与收集循环都用按路径的 `Sequence` 遍历；
   两者对单个实例都幂等，改为显式去重栈遍历后按节点数计价、答案不变。
4. **`DemanglingNode.identifier`**（`Store/DemanglingNode+Sequence.swift`，横向
   排查发现）——历史实现串三次 `first(of:)` 扫描，其中运算符组在类型子树上
   永远扫空、独自耗尽整个路径数。改为单趟去重先序遍历（`printCacheIdentity`
   作泛型去重键，同时覆盖 `Node` 与 `NodeReference`），每个「先序第一个匹配」
   的答案严格不变——共享实例的重复访问不可能包含首次访问没有的东西。

**暴露面是默认公开主 API**：一个 131 字符的合法符号（remangler 自己产出、
demangler 正常回读），新进程第一次调用默认 `demangleAsNode` 实测 5.5 秒，
每加 2 层嵌套 ×4；约 200 字符即可把 `demangleAsNode` 永久挂死。该库的本职是
批量 demangle 不可信二进制，mangled name 是二进制作者完全可控的字节串——
构造符号混进二进制 = 单符号 DoS，且挂死不抛错，比崩溃更难定位。

## Motivation

- **实测曲线**（修复前，18 层加倍 DAG）：`Node.interned()` 第一次 5.42s /
  第二次 4.91s；默认 `demangleAsNode` 第一次 5.46s / 第二次 5.39s；
  `internsSubtrees: false` 纯解析 1.04s——四列全部精确 4×/2 层。修复后同输入
  全部 0.2–0.6ms，且 `canonical-identical` / `results-identical` 全部保持。
- **为什么第一次 intern 也爆**：加倍 DAG 每层的 generic head 是结构相等但实例
  不同的拷贝，规范化把它折叠到先出现的实例上，`childrenChanged` 随之在**所有**
  祖先上翻真——此后原树共享实例的探测键（原始子节点）与表中键（重建后子节点）
  永不相符。也就是说触发条件不是「结构已在缓存里」，而是「树内存在任何结构
  重复」——interning 的日常输入。
- **与 main 对比**：main 的 `internTreeUnsafe` 是同一算法的递归形式（同样的
  探测、同样没有 memo，外加深度重下降先爆栈的风险）；`setParent...` 后处理
  main 同样纯递归无 memo。两处缺陷都是引入时就有、非本 PR 退化，故不阻塞
  PR 合并，单独成批修复。
- **为什么历次排查都漏了 `internTree`**：0003 那批修的是重建类遍历
  （`copy()` 等），0005 修的是成对相等类（`deepEquals`），它属于第三类
  ——规范化遍历；且探测快路径上方的注释写着 "This also makes re-interning an
  already-canonical subtree O(children)"，这句话对**已规范化**输入为真，
  容易被误读成「已覆盖」。与 0004 的教训同构：逐点修复不带横向排查，
  同类实例就会活下来。

## Detailed design

- `NodeCache.internTree`：加 per-walk `canonicalBySourceIdentity:
  [ObjectIdentifier: Node]`——`canonicalizeWithoutDescending` 先查 memo，
  `SubtreeKey` 探测命中与帧完成两处回填。memo 生命周期限于单次遍历（跨调用
  的去重仍由 subtrees 表承担），空字典字面量不分配，常规路径新增开销可忽略
  （该路径本就为每个内部节点分配 frame）。
- `Demangler.setParentForOpaqueReturnTypeNodesImpl`：签名加
  `rewrittenBySourceIdentity: inout [ObjectIdentifier: Node]`，入口查、
  出口回填；wrapper 每次后处理新建 memo（`getParentId` 按 pass 固定，重写是
  子树的纯函数，memo 不改变任何出现位置的产出）。重复实例只重写一次并复用
  结果，同时让重写后的树保住子树共享——与 0003 确立的 `copy()`/`Rewriter`
  语义一致。递归形式保留（深度问题属 KnownIssues 追踪的另一发现，不在本批）。
- `Node.findGenericParamsDepth()`：`Sequence` 遍历改为显式栈 +
  `Set<ObjectIdentifier>` 去重；`dependentGenericParamCount` 存在性守卫并入同一
  趟（原先是独立的 `first(of:)`，在**没有**该节点的 DAG 上同样耗尽路径数）。
- `DemanglingNode.identifier`：三次 `first(of:)` 合并为单趟去重先序（显式栈，
  子节点逆序入栈保持先序；`Set<PrintCacheIdentity>` 去重）。组间优先级保持
  历史顺序：任意位置的运算符 > 全树第一个 `.identifier` > 第一个
  `.privateDeclName`。`first(of:)` / `all(of:)` 等公开遍历原语**不动**——
  `all(of:)` 按出现次数枚举是文档化的预期语义。
- **回归测试**（修复前失败、修复后通过，永久保留）：
  - `DefectRegressionTests.nodeCacheInterningFinishesOnADoublingDag`——两份
    实例不同的 60 层加倍 DAG 先后 `interned()`，`completesWithinTimeout`
    断言完成（修前 2^60 次子树下降、30 秒超时判负），并断言两份收敛到同一
    规范实例（`===`）。
  - `DefectRegressionTests.demangleAsNodeFinishesOnASubstitutionSharedSymbol`
    ——用库自己的 remangler 从 60 层 DAG 产出合法符号，断言
    `internsSubtrees: false` 与默认 demangle 均完成，且两次默认 demangle
    结果 `===`（规范化语义未动）。
  - `DefectRegressionTests.findGenericParamsDepthFinishesOnADoublingDag`——
    共享 DAG 旁挂一个已知 `dependentGenericParamType`，断言完成且返回字典
    逐值不变（`[0: 0]`）。
  - `DefectRegressionTests.identifierLookupFinishesOnADoublingDag`——断言
    60 层 DAG 上 `identifier` 完成且仍返回先序第一个标识符（`"G"`）。

## Alternatives considered

- **给 `SubtreeKey` 探测加「按结构」的二级回退**：探测 miss 时按结构哈希再查
  一次。等于把 `Node.==` 的整树比较塞进每次探测，改动面大且常规路径变慢；
  per-walk memo 是局部、零语义变化的最小修复。
- **懒分配（256 阈值）memo**：`Node.==` 的做法。此处不必——空字典不分配，
  且凡是会下降的遍历必然至少回填一次；与 `copy()` 的 eager memo 保持一致。

## Impact

- 行为不变：全量测试套件（含 4.5M 符号语料对拍）通过；规范化收敛
  （`===`）与重复 demangle 的实例同一性全部保持。
- 性能：仅影响此前会指数爆炸的输入；常规符号无可测差异（memo 命中即返回，
  demangler 输出的共享实例本来就会重复出现，反而少走了重复探测）。

## Migration notes

无。纯内部修复，不涉及任何 API 或输出变化。

## 横向排查（全库收口）

按「确认为真必须横向排查同类」的规则，随批做了一次全库排查：枚举
`Sources/Demangling` 中所有沿子节点下降的遍历（递归、显式栈、`Sequence` 机制），
逐一归入四类——有 memo / 有常量上界 / 按出现次数是文档化语义（打印、
`description`、`all(of:)` 枚举）/ 解析驱动（受输入长度约束）。结果：

- **随批修复**：`findGenericParamsDepth`、`identifier`（即 Summary 第 3、4 条）。
- **留档暂缓**：TypeDecoder 按出现次数解码（`KnownIssues.md` #6）——修复涉及
  `TypeBuilder` 回调从「每次出现」变「每个实例」的公开契约语义变更（`Rewriter`
  当年同款决策），不适合混进无行为变化的批次，且 TypeDecoder 范围整体处于
  暂缓决策之下。
- **已覆盖确认**：其余 14 处带 memo 的遍历逐一核实 memo 真实覆盖重复访问路径
  （`copy` / `replacingDescendant` / `Rewriter` / `Node.==` / `Node.hash` /
  两侧 `structuralDigest` / 两个 `structurallyEquals` / `deepEquals` /
  `NodeStoreBuilder.internTree` / `materializeNode` / `materialize` /
  `sharedStructureDescription` / `hashForNode`）。一个非缺陷备注：
  `Remangler.hashForNode` 的 memo 是固定容量指针表（512 槽 × 8 探针，随上游），
  表满时退化为重走子树——有界退化，非缺失。
- **边界判定**：`getUnspecialized` / `isSpecialized` 只沿单后继链下降（O(链长)），
  不进多子分支，不属此家族；`demangleBoundGenericArgs` 沿 context 单链，解析
  驱动；`Node.deinit` 按唯一引用释放（`isKnownUniquelyReferenced` 门），天然
  按图计价。
