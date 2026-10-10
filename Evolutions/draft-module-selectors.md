# Draft - 打印选项：用 SE-0491 的模块选择器（`Module::Name`）写限定名

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-10-10
- **最后更新**: 2026-10-10
- **关联提案**: 下游 MachOSwiftSection 提案 `draft-module-selectors`（interface / dump 的同名开关建在本选项之上）
- **实现分支 / PR**: `feature/module-selectors`

## 摘要

[SE-0491](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0491-module-selectors.md)（Swift 6.3 实现）给源码加了 `Module::Name` 写法：名字前面带上它来自的模块，查找就只认这个模块里的声明，不会被同名的类型、成员或局部变量挡住。最典型的坑是模块里有一个和模块同名的类型（`XCTest` 模块里的 `XCTest` 类）：`XCTest.XCTestCase` 会被当成去 `XCTest` 类里找嵌套类型，而 `XCTest::XCTestCase` 不会。提案不改 ABI，mangled name 里没有任何新东西。

Swift 6.4 编译器生成 `.swiftinterface` 时默认就用这种写法（`PrintOptions::UseModuleSelectors`，Xcode 27 SDK 里 Swift / Foundation / AppKit / _Concurrency 的接口全是 `Swift::Int`、`Foundation::Date.Foundation::FormatStyle`）。上游 demangler 没有对应选项，一律写 `Swift.Int`。本提案加一个默认关闭的 `DemangleOptions.useModuleSelectors`，打开后按编译器写接口文件的同一套规则输出，供下游生成与 SDK 接口同形的 interface。

## 方案

新增 `DemangleOptions.useModuleSelectors`（`1 << 26`），不进任何预设，关闭时输出逐字节不变。打开时：

- **模块与它限定的实体之间写 `::`**：`Swift::Int`、`Swift::print(_:separator:terminator:)`。所有实体都适用（类型、函数、属性），因为这正是 `printEntity` 写模块分隔符的那一处。
- **嵌套类型也带上声明它的模块**，与编译器的 `TypePrinter::printQualifiedType` 一致（「无论是否印了父类型都印模块选择器」）：`Swift::Dictionary<Swift::String, Swift::Int>.Swift::Index`。声明模块取最近一层 `extension` 上下文的模块，没有 extension 就取上下文链根上的模块，于是由别的模块的 extension 声明的嵌套类型写成 `Swift::Duration.Foundation::TimeFormatStyle`——关掉 `displayExtensionContexts` 时这个出处原本整个丢失。只对类型声明（`class` / `structure` / `enum` / `protocol` / `otherNominalType` / `typeAlias`）加，成员函数与属性不加。
- **不加的情况**（与编译器的 `shouldPrintModuleSelector` 一致）：上下文链上遇到函数、闭包、匿名上下文等非类型非模块节点（局部类型——模块选择器会跳过局部作用域，加了反而指错）；`dependentMemberType` 里的关联类型（`A.Element`，SE-0491 明文禁止给类型参数的成员类型加模块选择器）。
- **模块可见性规则照旧**：一个模块在原选项下不显示（`qualifyEntities` 关、`displayModuleNames` 关、标准库模块配 `displayStdlibModule` 关、`__C` / `__ObjC` 配 `displayObjCModule` 关、隐藏的当前模块、调试器生成的模块），它的 `::` 也不写；嵌套类型的选择器按它自己的声明模块套同一套规则。
- **硬编码的限定名一起改**：`Builtin.` 前缀（`builtinTypeName` 文本、`Builtin.Borrow<`、`Builtin.FixedArray<`、`Builtin.TheTupleType`）、`protocolListWithAnyObject` 的 `Swift.AnyObject`、逆向约束的 `Swift.Copyable` / `Swift.Escapable`（含兜底的 `Swift.<bit N>`）。编译器在接口文件里写的正是 `Builtin::RawPointer`、`Swift::AnyObject`、`~Swift::Copyable`。
- **富目标（rich target）**：嵌套类型选择器里的模块名和顶层模块名一样，以 `.printModule` 状态写出、落在该类型自己的类型引用作用域里，`SemanticString` 之类的目标照常着色、跳转。
- 打印片段缓存（`printCache`）不受影响：一个类型的选择器只取决于它自己的上下文子树，不依赖父节点。

不做：调试用的 `(extension in Foundation):` 前缀照旧（它与选择器正交，`.default` 下两者同时出现）；`showModuleInDependentMemberType` 下关联类型协议前缀的写法跟着第一条规则变成 `Swift::Sequence`，不再单独处理——这个组合本就只用于生成查找 key，不是源码。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-10 | Created as Draft：加一个使用 module selector 的打印选项 | 用户要求「改一下 swift-demangling，加一个 options 使用 module-selector」，配合 MachOSwiftSection 适配 SE-0491 |
| 2026-10-10 | 嵌套类型每一层都带模块（照编译器），不只在最外层 | 用户选定。与 Xcode 27 SDK 接口逐处一致，并且保留了嵌套类型由哪个模块的 extension 声明的信息；只在最外层虽然更短、也足以解决模块名被同名类型遮住的问题，但对不上 SDK 接口 |
| 2026-10-10 | 选项名 `useModuleSelectors` | 沿用编译器 `PrintOptions::UseModuleSelectors` 的名字，便于对照上游 |
| 2026-10-10 | 默认关闭、不进任何预设 | 上游 demangler 没有这个选项，预设的输出要与官方 demangler 逐字节对齐（corpus oracle） |
| 2026-10-10 | 验证 | `ModuleSelectorPrintingTests`（13 个符号形状 × Node 与 store 两条打印路径，外加富目标的模块写入）在只加选项声明、未接行为时 26 处失败，实现后全过；全量 `swift test` 624 个测试 / 43 个套件通过，原始退出码 0（含与官方 demangler 逐字节对照的语料测试，证明选项关闭时输出不变）。下游 MachOSwiftSection 用 libswiftCore 渲染比对：两边都出现的 107 条嵌套类型路径，逐层模块与 Xcode 27 SDK 的 `Swift.swiftinterface` 一致 |
