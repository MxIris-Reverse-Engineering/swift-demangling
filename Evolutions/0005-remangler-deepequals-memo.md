# 0005 - Remangler 替换表相等比较补 proven-pair memo（修复共享 DAG 上的指数级重整编）

- **Proposal**: 0005
- **Author**: Mx-Iris
- **Status**: Implemented
- **Date**: 2026-08-02
- **Branch**: `feature/node-store`
- **Related**: `Evolutions/0003-review-hardening.md`（同一 PR 上一轮 review 给整树遍历
  加 memo 的那批，本条正是那批漏掉的一处）；`Evolutions/0004-32bit-store-guards.md`
  （同一轮复审的上一条修复）

## Summary

`Remangler.SubstitutionEntry.deepEquals`（替换表哈希命中后的结构相等比较）是库内
四个「成对结构相等遍历」中唯一没有 visited-pair memo 的：`Node.==` 与
`NodeReference.structurallyEquals` 的两个重载都带懒创建的 proven-pair memo，它没有。
后果是比较两棵**结构相等但实例不同**的共享 DAG 时按**路径数**而非节点数下降——
一个签名里放两份分别构建的 `G<T, T>` 嵌套 DAG，`mangleAsString` 对共享深度 N 呈
2^N 增长（实测每加 2 层耗时 ×4：16 层 0.024s、20 层 0.38s、22 层 1.55s，输出
只有 155 字符；`===` 共享的对照组在任何深度都是 0.0001s 级）。

修法：把 `Node.==` 的懒 memo 块（256 对阈值后才分配，`ObjectIdentifier` 对做键）
原样移植进 `deepEquals`。常规替换探测远在阈值之内、零分配零开销；修后 60 层
（2^60 路径）毫秒级完成，且输出与 `===` 共享对照逐字节一致（替换匹配语义不变）。

## Motivation

- **触发条件**：树中存在结构相等但实例不同的 nominal 类型子树。替换机制只覆盖
  nominal / bound-generic / protocol conformance 一族（`mangleAnyNominalType` 等），
  **不覆盖 tuple、function type 等结构型**——所以构造触发要用嵌套 bound generic；
  结构型的重复 DAG 根本进不了 `deepEquals`（它们在 mangled 输出里本来就按语法
  逐次展开）。
- **暴露面**：默认 `demangleAsNode`（开子树 interning）产出全规范化树，相等必
  `===`，`deepEquals` 的身份快路径直接短路——**默认 demangle→remangle 管线免疫**。
  暴露的是手工建树（`Node.create` / `NodeBuilder` 不 intern 内部节点）、
  `demangleAsNodeTransient` 输出、两次 `NodeReference.materialize()` 结果的组合
  这几条消费者路径。
- **与 main 对比**：main 上这里是纯递归——没有 memo、没有 `===` 快路径，同样
  指数级，深树还会先爆栈。本 PR 已将它迭代化并加了 `===` 快路径（净改进），
  给三个兄弟遍历补 memo 时漏掉了这一个（`Evolutions/0003` 的 memo 名单里没有它，
  也没有说明豁免理由——因为不是豁免，是遗漏）。
- **横向排查**：四个成对遍历（`Node+Hashable.swift:122`、`NodeReference.swift`
  两处、本处）已全部带 memo，本条是最后一个。同为「遍历成本按路径计」家族的
  单树遍历缺口还剩 `NodeCache.internTree`（缺 identity memo，`Node.interned()`
  可触发同量级增长），作为独立发现另行追踪，不在本批范围。

## Detailed design

- `Sources/Demangling/Main/Remangle/Remangler.swift` `SubstitutionEntry.deepEquals`：
  work-list 循环内加与 `Node.==` 逐字一致的懒 memo——处理对数超过 256 才分配
  `Set<VisitedPair>`；已证明相等的实例对直接跳过（任何不匹配在第一次就中止了
  整个遍历，重复对必然重复相同的子树比较）。
- **回归测试**（修复前失败、修复后通过，永久保留）：
  `DefectRegressionTests.remanglerSubstitutionLookupFinishesOnDistinctCopiesOfASharedDag`
  ——用公开 API 构造两份实例不同的 60 层 `G<T, T>` 加倍 DAG 放进同一签名，
  经 `completesWithinTimeout` 断言完成（修前 2^60 对、30 秒超时判负），并断言
  输出与 `===` 共享对照逐字节相同（替换必须仍然**匹配上**，不只是不卡死）。
  60 层是该形状在 remangler 384 深度上限内的最大值。

## Alternatives considered

- **无阈值的 eager memo**：`SubstitutionEntry.==` 在每次哈希命中时被调，浅比较
  占绝对多数，eager 分配会把一次指针比较变成一次堆分配；懒阈值与 `Node.==`
  保持一致，也让两处实现可以互相对照维护。
- **给 `SubstitutionEntry` 缓存子树规范形**：等价于把 interning 塞进 remangler，
  改动面大且引入跨 mangling 会话的共享状态；memo 是局部、无状态的最小修复。

## Impact

- 行为不变：全量测试套件 467 例（含 4.5M 符号语料对拍）通过；victim 与 control
  输出逐字节一致证明替换匹配语义未动。
- 性能：仅影响此前会指数爆炸的输入（修前 22 层 1.55s → 修后毫秒级）；常规
  路径在 256 对阈值内零新增分配。

## Migration notes

无。纯内部修复，不涉及任何 API 或输出变化。
