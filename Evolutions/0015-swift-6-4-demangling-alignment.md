# 0015 - 对齐 Swift 6.4 的 lib/Demangling：新 kind、accessor 改名与 oracle 换基准

- **状态**: Implemented
- **创建日期**: 2026-09-16
- **最后更新**: 2026-09-16

## 摘要

上游 `swift-6.3.2-RELEASE` 到 `swift-6.4.0-RELEASE` 之间 `lib/Demangling` 的全部改动逐项移植进来：
新增 node kind `ImplNonisolatedNonsendingIsolation`（impl 函数类型的 `N` 隔离标记，打印
`@caller_isolated`）；`Read2Accessor` / `Modify2Accessor` 按 SE-0474 改名为
`YieldingBorrowAccessor` / `YieldingMutateAccessor`（mangling 字符 `y` / `x` 不变，打印文本改为
`yielding_borrow` / `yielding_mutate`）；参数特化新增 `E`（EscapingClosureProp = 12）；泛型
requirement 新增 `j` / `J`（关联类型上的 inverse requirement）；`Tn` / `TN` 的 subject 允许是泛型
参数；attached macro 的 remangle 改为可变子节点数；TypeDecoder 的 impl 函数隔离位改成三值枚举并
支持 `Builtin.Borrow`。同批把语料 oracle 的基准从 Apple Swift 6.3.3（Xcode 26.6）切到 Apple
Swift 6.4（Xcode 27.0），并把 `Documentations/AlignmentGaps.md` 的基准改为 6.4.0。

## 方案

**动机来源**：MachOSwiftSection 会话做 6.4 适配调研，把 demangling 部分交到本仓库；上游改动清单
以 `git diff swift-6.3.2-RELEASE swift-6.4.0-RELEASE -- include/swift/Demangling lib/Demangling
docs/ABI/Mangling.rst` 的内容比对为准，另补上对方漏掉的 `TypeDecoder.h`（184 行）。

**Ground truth 是 Apple 工具链，不是开源源码**（AlignmentGaps 的既有结论）。本机
`Xcode-27.0.app` 是 Apple Swift 6.4（`swiftlang-6.4.0.34.1`）：上游 `test/Demangle/Inputs/manglings.txt`
新增的 12 条符号在它的 `swift-demangle` 上逐条与上游期望一致；`Xcode.app`（26.6，Apple Swift 6.3.3）
对 `BW` / `E` / `Rj` / `N` / 泛型 subject 的 `Tn` 一律拒绝，node dump 仍写 `Read2Accessor`。

**改动清单**（与上游一一对应）：

| 上游 | 本仓库 |
|---|---|
| `DemangleNodes.def` 新增 `ImplNonisolatedNonsendingIsolation` | `Node.Kind.implNonisolatedNonsendingIsolation` + `NodeFactory` 单例 |
| `Read2Accessor` → `YieldingBorrowAccessor`、`Modify2Accessor` → `YieldingMutateAccessor` | 改名；旧名保留为 `@available(*, deprecated, renamed:)` 静态别名；`Codable` 解码接受旧 rawValue |
| `demangleImplFunctionType` 在 `A` 之后 `nextIf('N')` | 同位置同顺序 |
| `demangleFuncSpecParam` 新 case `E`；`demangleFunctionSpecialization` 与 `ClosureProp` 同分支 | `FunctionSigSpecializationParamKind.escapingClosureProp = 12`，描述 "Escaping Closure Propagated"，两处分支合并 |
| `demangleGenericRequirement` 新 case `j`（Inverse, Assoc）/ `J`（Inverse, CompoundAssoc） | 同 |
| `popAssociatedConformanceWitnessAccessorSubject`：先 pop Type，是泛型参数就用它，否则推回去走 assoc-type-path | 同名方法 + `isGenericParamType` |
| NodePrinter：`@caller_isolated`、`yielding_borrow` / `yielding_mutate`、"Escaping Closure Propagated" | 同 |
| Remangler：`N`、`E`、`mangleAttachedMacro` 可变子节点（前 n-1 个、`fM`+字符、最后一个） | 同 |
| `TypeDecoder.h`：`ImplFunctionIsolation` 三值枚举替换 erased 位；`createBuiltinBorrowType` | `ImplFunctionTypeFlags` 内部改存枚举，保留 `hasErasedIsolation()` 与旧 init 不破坏调用方；`TypeBuilder.createBuiltinBorrowType(referent:)` 为协议要求、无默认实现（下游要求：不要静默成功的假 metadata） |
| `Words[MaxNumWords]` 保存 / 恢复（嵌套 demangle 的 use-after-free） | 不适用：本仓库的 resolver 是纯闭包，拿不到 Demangler；Demangler 是每次调用新建的 `~Escapable` 结构体 |
| `TypeDecoder.h` 值泛型加固（`allowValue` / `decodeMangledGenericArgument` / `isValueGenericParameter`） | **推迟**，登记为 AlignmentGaps 新条目 |

**测试**：`DemangleSwiftProjectDerivedTests` 更新 2 条期望并加入上游新增的 12 条打印期望；
`AppleAlignmentTests` 新增 6.4 一节，对每条新符号做 demangle → remangle 往返、node kind 断言，
以及 3 子节点 peer macro 的 remangle 往返（上游 4542ea9904f 修的形状，Apple 6.4 的 printer
对它会崩溃，所以只验证 remangle）；`TypeDecoderTests` 覆盖 `@caller_isolated` flags 与
`Builtin.Borrow`；旧 kind 别名与 `Codable` 兼容各一条。

**语料 oracle**：`CDemangleTree.cpp` 加载 `libswiftDemangle.dylib` 时先认 `DEVELOPER_DIR`，再回退
现有路径。跑法：`DEVELOPER_DIR=/Applications/Xcode-27.0.app/Contents/Developer swift test`，
整个构建随之用 6.4 编译器。验收：全量 dyld cache oracle 在本机 26.6 cache 上零 mismatch。

**假设**：落到 `next`；提案与代码同一批提交；`_T` 旧 mangling 的 `XB` 分支误调用 package 入口
`demangleType()` 的旁枝发现不在本批，登记到 AlignmentGaps。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-16 | Created as Draft | MachOSwiftSection 会话转来 6.4.0 demangling 改动清单；本仓库逐项核对后给出方案 |
| 2026-09-16 | Accepted：轻量档，改名保留弃用别名 | 改名是上游命名，`Node.Kind` 跟进 Apple 工具链是愿景第 1 条；别名 + `Codable` 兼容让下游零改动。唯一源码破坏点是自定义 `TypeBuilder` 实现者要补 `createBuiltinBorrowType` |
| 2026-09-16 | Accepted：oracle 认 `DEVELOPER_DIR` | 标准 Xcode 环境变量，构建与 oracle 用同一套工具链，可预测 |
| 2026-09-16 | Accepted：值泛型加固推迟 | 它改变 TypeDecoder 对整数节点的接受集，与 6.4 新 kind 无关，值得单独审 |
| 2026-09-16 | In Progress | 开始实现 |
| 2026-09-16 | Implemented | 全套 615 条单测全绿；语料 oracle（Xcode 27.0 dylib）在本机 26.6 cache 上 4,530,817 符号 0 失败 / 0 mismatch，27.0 cache 的结果记在 AlignmentGaps「验收」一节。配套文档：不另写 guide / implementation note——本批没有 API 签名之外的契约，落地记录在 `AlignmentGaps.md` 的「6.3.2 → 6.4.0 增量」一节。术语：`yielding borrow` / `yielding mutate` / `@caller_isolated` 是 Swift 语言术语（SE-0474、SE-0461），不进项目术语表 |
