# 0004 - 32-bit 可移植性：Store 越界守卫在 watchOS 上被折叠成无条件 trap

- **Proposal**: 0004
- **Author**: Mx-Iris
- **Status**: Implemented
- **Date**: 2026-08-02
- **Branch**: `feature/node-store`
- **Related**: `Evolutions/0003-review-hardening.md`（同一 PR 的上一轮 review）；
  commit `06a423c`（同文件上一处 32-bit 问题——哈希混合常量——的修复）

## Summary

`NodeStoreBuilder` 的三个缓冲越界守卫写作 `precondition(count < Int(UInt32.max))`。
在 `Int` 为 32 位的平台（watchOS `arm64_32` / `armv7k`，均在 `Package.swift` 声明的
支持范围内），`Int(UInt32.max)` 这个转换本身溢出，且溢出发生在**常量折叠阶段**：
编译器把 `appendNode` 的整个函数体折叠成一句无条件 `assertionFailure`（SIL 实证：
0 个 `cond_br`、0 个 `return`），而构建保持全绿、零诊断。后果是 watchOS 上任何
store 插入的第一个节点即杀进程，波及 `NodeStoreBuilder.intern` / `demangle`、
`NodeReference(interning:)` 等全部公开入口；崩溃信息是标准库的通用文案（指向
`.swiftinterface` 某行），作者写的三条 precondition 消息一条都不会出现。

修法：删掉 `Int(...)` 包装，直接异构比较 `count < UInt32.max`——上游同场景的
标准写法（swift-syntax `AbsoluteSyntaxInfo.forRoot` 守卫 `totalNodes: Int` 塞进
UInt32 索引空间；stdlib `KeyPath` 的越线偏移检查同理）。`Int(UInt32.max)` 这个
反模式在 Swift 官方代码库中零出现。

## Motivation

这是本仓库第三个 32-bit 整数问题，前两个的处理方式都拦不住它：

1. `TypeDecoder` 三处会 trap 的转换（`KnownIssues.md` #1）——main 既有，暂缓；
2. 同文件哈希混合常量溢出（`06a423c` 修复）——那是**字面量溢出**，在 watchOS 上是
   **硬编译错误**，所以当时的验证手段是「交叉编译提取出的函数体」，编过即过；
3. 本条是**转换 trap**——编译完全干净，只有看 SIL、跑 32 位运行时或专门扫描
   这个模式才能发现。上一次的验证手段对这一类天生失明，这正是它存活至今的原因
   （三行守卫自 Phase 1 首个提交就存在，早于 `06a423c` 一周）。

另外，这三个守卫在 32 位平台上本来就是恒真的（`count ≤ Int.max = 2³¹−1 <
UInt32.max`），所以「把常量加宽」是错误修法；正确语义就是异构比较——64 位上做
真实检查，32 位上退化为恒真且这恰好正确。

## Detailed design

- `Sources/Demangling/Store/NodeStoreBuilder.swift` 三处（`appendNode` /
  `internManyChildren` / `internText`）：`Int(UInt32.max)` → 直接与 `UInt32.max`
  异构比较（SE-0104，两侧均不转换，按数学值比较）。`appendNode` 处留有完整注释。
- **防线**（防止该家族再次进入源码）：`DefectRegressionTests.
  librarySourceAvoidsWordSizeDependentIntegerConversions` 扫描 `Sources/` 全部
  Swift 文件，禁止 `Int(UInt32.max)` / `Int(UInt64.max)` / `Int(UInt.max)`
  出现在代码行（注释行豁免）。该测试在修复前失败（恰好命中三行）、修复后通过，
  作为回归测试永久保留。

## Alternatives considered

- `UInt32(exactly:)` + 失败分支：语义等价但更啰嗦，且这里守卫的本意就是
  precondition；异构比较是上游惯用法，保持一致。
- 在 CI 增加 watchOS 构建：对本类缺陷无效（构建本来就是绿的），且仓库当前没有
  CI；源码扫描测试在任何宿主上运行、对该家族全覆盖，成本更低。

## Impact

- 行为变化仅在 watchOS：Store 子系统从「首次插入即崩」变为正常工作。
- 64 位平台语义与代码生成不变（守卫仍是同一比较，SIL 实证修复后 `appendNode`
  恢复正常函数体：5 个 `cond_br`、1 个 `return`，armv7k 相同）。
- 全量测试套件 466 例（含 4.5M 符号语料对拍）通过。

## Migration notes

无。纯内部修复，不涉及任何 API 或输出变化。
