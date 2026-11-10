# Draft - Demangler 与 Remangler 改为 `~Copyable`：「不整份复制」由编译器保证

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-10
- **最后更新**: 2026-11-10
- **所属愿景**: `Evolutions/README.md` 愿景第 3 条（计价纪律：违反纪律的代码要被拦下，这里由编译器拦）与第 4 条（渐进吸收新语言能力）
- **关联提案**: [0018](0018-demangler-self-copy.md)（本提案把它靠约定维持的「不复制」变成编译器保证）
- **实现分支 / PR**: `refactor/noncopyable-demangler-and-remangler`（worktree `.worktrees/swift-demangling-NoncopyableDemanglerAndRemangler`）

## 摘要

0018 修掉的问题是：`try require(pop())` 里 `require` 不是 `mutating`，编译器只好先把整个 `Demangler` 复制一份当接收者，随后的 `pop()` 再把节点栈连同每个节点的引用计数复制一遍。这个问题现在只靠一条约定挡着：凡是拿 `pop()` 当参数的辅助方法一律标 `mutating`。约定写在 `AGENTS.md` 的 Conventions 里，没有编译器检查，新写的辅助方法漏标一个，复制就悄悄回来。

本提案把 `Demangler` 和 `Remangler` 改为 `~Copyable`。不可复制的值，编译器不会再隐式复制：要么不复制，要么报错。探针确认，不可复制的接收者要等参数求值完才开始借用，所以 `createNode(kind:child: try require(pop()))` 这类写法改完照常编译、一次也不复制，`require` 和四个组合 `createNode` 还能改回非 `mutating`。

这是纯内部改动：两个类型都是 internal，公开 API 与 SPI 不变，输出逐字节不变。下游 MachOSwiftSection 的代码没有引用它们，补丁版落在它现有的 `"0.7.3" ..< "0.8.0"` 依赖区间内。

## 方案

1. **`Demangler` 声明为 `~Copyable, ~Escapable`**（`Demangler.swift`）。两个 `require` 与 `Demangler+NodeCreation.swift` 里的四个组合 `createNode` 去掉 `mutating`。解释「为什么标 `mutating`」的两段注释换成一段说明：接收者不可复制，借用在参数求值之后才开始，`pop()` 先跑完，既不复制也不冲突。**已完成。**
2. **`Remangler` 声明为 `~Copyable`**（`Remangler.swift`）。它现在没有 0018 那种复制：非 `mutating` 辅助方法的参数里没有改 `self` 的调用。改它是为了预防，以后有人写出同样的调用，编译器同样会拦下。没有调用方的 `Remangler.require` 顺手删掉。**已完成。**
3. **按编译器报错逐处调整**。真实类型还没试编过，预期会有零星报错，比如闭包捕获、对 `self` 的整体使用。改法以不改语义为限；如果哪处必须显式 `copy` 或重构才能编过，记进决策日志。**实际一个报错也没有，见决策日志。**
4. **回归测试锁住 `~Copyable`**。去掉 `~Copyable` 照样能编译，输出也不变，只有性能悄悄退回去，任何输出比对测试都抓不到。所以加一条测试确认两个类型不可复制，失败信息写明不能去掉的原因。判别手段实现时再定：优先用编译期重载决议，不行再退回源码扫描（仿照 `librarySourceAvoidsWordSizeDependentIntegerConversions`）。**已完成**：`DefectRegressionTests.demanglerAndRemanglerStayNoncopyable`，用的是重载决议。
5. **文档**。`AGENTS.md` Conventions 里「接 `pop()` 的辅助方法要 `mutating`」一条，改成「`Demangler` / `Remangler` 是 `~Copyable`，不要去掉」，并写明理由；Key Types 里两个类型的描述各补一句。0018 是落地后的决策快照，不改。
6. **验证**：
   - **全量测试**：`DEVELOPER_DIR` 指向 Xcode 27，包含全语料对齐 oracle（逐符号比对树、remangle 结果和两种打印）。另用 Xcode 26.6（Swift 6.3）编译一遍，因为 MachOSwiftSection 要求的工具链下限就是 6.3。
   - **release 性能**：0.7.3 起，这些复制在 release 下已经被优化器去掉，预期持平。按 0018 的口径，用 MachOSwiftSection 的基准程序做改前改后对比：只建索引与打印 interface 的 instructions retired，以及并行时的 CPU 时间。按 `Documentations/MeasurementToolbox.md` 的要求在空闲机器上量。
   - **debug**：现在约 120 处 `createNode(kind:…)` 的参数里带 `pop()` 这类改 `self` 的调用。在 `-Onone` 下，每处都会先复制一份 `Demangler`，再连带复制节点栈，改完应该归零。量一次默认 `swift test` 改前改后的耗时，只记进决策日志，不设门槛。

没有询问就采用的假设：

- `require` 等改回非 `mutating`，而不是保留 `mutating`。标 `mutating` 只是为了规避复制，`~Copyable` 下这个理由已经不存在，留着反而误导读者。报错位置不受影响，因为借用同样在参数求值之后才开始。
- 打印器（`DemanglingPrinter`）不在范围内。它经 `@_spi(Internals)` 暴露给 MachOSwiftSection，改成 `~Copyable` 会影响下游，要另外评估。
- 随下一个补丁版发布。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-10 | 创建为精简提案，状态 Draft | 0018 的「不整份复制」只靠约定维持；探针证实改为 `~Copyable` 后照常编译、零复制；确认对 MachOSwiftSection 无影响后，用户选择两个类型都改，先写精简提案 |
| 2026-11-10 | 探针结论：`~Copyable` 下接收者借用推迟到参数求值之后 | 仓库外的独立 Swift 文件模拟两个引擎的写法，只编译成 `-Onone` SIL，在 Swift 6.3.3（Xcode 26.6）与 6.4.2（Xcode 27.3 beta）上结果相同。照现状声明的版本在 `createNode(kind:child: try require(pop()))` 处复制整个结构两次，两次都在 `pop()` 之前；`~Copyable` 版本一次也不复制，`pop()` 的修改访问结束后才开始对 `self` 的读借用。闭包里调非 `mutating` 方法、`?? require(pop())` 的自动闭包、`for name in nameStack` 循环体里调 `mutating` 方法，都能编译且不复制结构。Remangler 的写法里，带普通参数的非 `mutating` 调用照现状在 `-Onone` 下每次都给整个结构 retain/release 一次，`~Copyable` 下没有。编译器依据：SILGen 对不可复制类型的 guaranteed 参数（含 `self`）走 `DelayedArgument::BorrowedLValue`，借用推迟到其余参数求值之后（`lib/SILGen/SILGenApply.cpp`，`tryEmitBorrowedMoveOnly`） |
| 2026-11-10 | 确认不影响 MachOSwiftSection | 它的 Sources 与 Tests 里提到 `Demangler` / `Remangler` 的 8 处都是注释；其中 10 个测试文件 `@testable import Demangling`，也都没碰这两个类型；它用的 SPI（`createTransient`、`StackSafeExecutor`、`DemanglingPrinter`、`LargeStackTaskExecutor`、`materializedNode`）不变；工具链下限 6.3 在探针覆盖范围内；依赖区间 `"0.7.3" ..< "0.8.0"` 能直接接住补丁版 |
| 2026-11-10 | 用户批准，开始实现，状态 Accepted | 方案第 1、2、4、5 条各是一个能单独构建通过的落地步骤，第 3 条是贯穿前两步的改法约束，第 6 条是收尾验证；不再另拆 |
| 2026-11-10 | 第 1 步完成，状态 In Progress：`Demangler` 加上 `~Copyable` 后，库与测试一次编过，第 3 条预期的报错一个也没有 | Xcode 27.2 下零错误零警告：闭包捕获、`??` 自动闭包、循环体里的 `mutating` 调用都和探针一样直接成立。快速套件（上游 manglings、`DemangleSwiftProjectDerivedTests`、`DualPathParityTests`、`DefectRegressionTests`、`AppleAlignmentTests` 等 9 个套件 400 个测试）全部通过，8 个已知问题与基线相同；全语料 oracle 留到第 6 条统一跑 |
| 2026-11-10 | 第 2 步完成：`Remangler` 加上 `~Copyable`、删掉没有调用方的 `require`，同样一次编过 | 不需要任何调整；快速套件加上 `NodeStoreTests`、`SharedNodeStoreTests`（14 个套件 442 个测试）全部通过，8 个已知问题不变。第 3 条至此确认不需要：两个类型都没有一处要显式 `copy` 或重构 |
| 2026-11-10 | 第 4 条完成：回归测试用编译期重载决议判别，不扫源码 | 两个同名重载，一个要求 `Copyable`、一个不要求，都放开 `Escapable`；可复制的类型两个都匹配、选更具体的前者，不可复制的只能匹配后者。测试先拿三个已知类型对照：`Node.Children`（可复制）、`Span<UInt8>`（可复制但不可逃逸，正是去掉 `~Copyable` 后 `Demangler` 的样子）、`NodeStoreBuilder`（不可复制）；对照成立，就等于证明了去掉 `~Copyable` 时测试会失败，因此不再另做一遍去掉再恢复的演示。比源码扫描好在不依赖声明的写法，换行或改名都不会让它失效 |
