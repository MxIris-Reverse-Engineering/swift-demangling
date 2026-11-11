# Draft - 打印选项：给 existential 写上 `any`

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-11
- **最后更新**: 2026-11-11
- **关联提案**: 下游 MachOSwiftSection 提案 `existential-any`（interface 与 dump 默认写 `any`，dump 一侧建在本选项之上）
- **实现分支 / PR**: `feature/existential-any`

## 摘要

编译器从 SE-0335 起写 `.swiftinterface` 时给 existential 写上 `any`：除了 `Any` 与 `AnyObject`，`any Swift.Error`、`(any Swift.Error)?`、`any P.Type`、`(any P).Type` 都是这么写的（macOS 27.2 SDK 的 Foundation 接口里有 550 处），Swift 6.4 也没有关掉它的选项。上游 demangler 一律写成 `P`、`P?`、`P.Type`、`P.Protocol`，只有带参数的 `any P<…>` 带关键字。本提案加一个默认关闭的 `DemangleOptions.useExistentialAny`，打开后照编译器的规则写。

## 方案

新增 `DemangleOptions.useExistentialAny`（`1 << 27`），命名照 `useModuleSelectors`，取自 SE-0335 的 upcoming feature `ExistentialAny`。不进任何预设，关闭时输出逐字节不变。打开时（规则取自编译器的 `ExistentialType::get`、`TypePrinter::visitAnyMetatypeType` 与 `isSimpleUnderPrintOptions`）：

- `protocolList`、`protocolListWithClass`、`protocolListWithAnyObject` 前面写 `any `；只有一个 `Any`（空列表）或一个 `AnyObject` 时不写。
- 带 `any` 的 existential 在可选类型里加括号：`(any P)?`、`(any P & Q)!`。`Any?` 不加。
- `existentialMetatype` 一律写 `any`，`Any` 与 `AnyObject` 也写（`any Any.Type`，SDK 里 16 处都是这样）；元类型下的组合加括号，`any (P & Q).Type`——原先的 `P & Q.Type` 读起来像 `.Type` 只属于 `Q`。可选的 existential metatype 加括号：`(any P.Type)?`。
- existential 本身的元类型写 `(any P).Type`，`Any`、`AnyObject` 也写关键字：`(any Any).Type`。
- `constrainedExistential` 本来就写 `any`，不变；它和 existential metatype 里面的 protocol list 不再写第二个 `any`（`any P<…>.Type`、`any P.Type.Type`）。
- 嵌套名字（特化参数里的 mangled name、宏名）的 `nestedNameOptions` 与 `useModuleSelectors` 一样，透传调用方的这个选项。

**片段缓存**：`printCache` 按节点身份缓存打印出的片段，而 `any` 是唯一取决于父节点的写法——同一个 protocol list 在别处带 `any`，在 `any P.Type`、`any P<…>` 里不带。所以这几处（existential metatype 的实例、constrained existential 的 protocol list、extended existential shape 的类型）经 `printExistentialConstraint` 直接印成员，不经 `printName`，缓存里的片段总是带关键字的那个。成员协议仍经 `printName` 打印，富目标照常拿到它们的类型引用作用域。

**测试**：`ExistentialAnyPrintingTests`——32 个形状 × `Node` 与 store 两条打印路径，每个都钉住开关关闭时的旧写法；外加与模块选择器同开、同一个 protocol list 实例在两个位置各自的写法（两种顺序）、裸印的组合里每个协议仍在自己的作用域里。可选类型的用例用 `.interface` 预设：`.default` 不合成 `?`，印出来是 `Swift.Optional<…>`；另有两个 `XSq`（`SugaredOptional` 节点）用例走 `printSugaredOptional` 那条路。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-11 | Created，直接进入 In Progress | 下游 MachOSwiftSection 的 `existential-any` 提案已经用户批准，本选项是它的第一步，方案在那份提案里定下 |
| 2026-11-11 | 选项名 `useExistentialAny` | 编译器写接口文件时没有对应的打印选项，名字取自强制写 `any` 的 upcoming feature `ExistentialAny`，前缀照 `useModuleSelectors` |
| 2026-11-11 | 默认关闭、不进任何预设 | 预设的输出要与官方 demangler 逐字节对齐（corpus oracle）；下游自己决定默认打开 |
| 2026-11-11 | 验证 | 在 JHs-Mac-Studio-Ultra（Xcode 26.6）上跑全量 `swift test`：651 个测试 / 46 个套件，与官方 demangler 逐字节对照的语料测试全过，证明选项关闭时输出不变；新测试第一轮有 5 个可选类型用例的期望写错（`.default` 不合成 `?`），改用 `.interface`、补两个 `XSq` 用例后 `ExistentialAnyPrintingTests` 全过，原始退出码 0。下游 MachOSwiftSection 的全量测试用本分支跑过，见那份提案 |
| 2026-11-11 | `nestedNameOptions` 透传这个选项 | 与 `useModuleSelectors` 同理：一行里有的 existential 带 `any`、有的不带，两种写法都不是 |
