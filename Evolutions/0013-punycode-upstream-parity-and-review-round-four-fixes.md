# 0013 - Punycode 上游对齐，以及 PR #8 review 的修复批次

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-16
- **最后更新**: 2026-08-16
- **所属愿景**: 主要归 `Evolutions/README.md` 愿景第 1 条（正确性与上游对齐，不可让步）；`StackSafeExecutor` 两条归第 3 条（计价纪律与健壮性）
- **关联提案**: [0004](0004-32bit-store-guards.md)（同属「守卫写法本身有问题、构建却全绿」一族）、[0007](0007-short-circuit-queries-and-typedecoder-sweep.md)（同属「横向排查漏了一族」的先例）、[0012](0012-review-round-three-structural-followups.md)（本轮判定为结构性、留给它的四条）
- **实现分支 / PR**: `next` → `main`（PR #8）
- **配套文档**: 裁决结论见 [`Documentations/KnownIssues.md`](../Documentations/KnownIssues.md)

## 摘要

PR #8（`next` → `main`）提交后跑了一轮 `max` 档 code-review，再把它的 15 条发现交给
另一个会话独立复核。复核推翻或修正了 4 条，并指出 review 只说对了 punycode 那条的
一半。本提案记录**据此实际落地的修复**，以及本轮新做出的裁决。

最重要的一条不在 review 的清单里：**punycode 解码路径缺的不是一个守卫，是三个。**

## 动机

### 1. Punycode 解码与上游有三处偏离（愿景第 1 条）

上游把 punycode 解码分成两层：`Punycode::decodePunycode` 产出 code point 序列，
`encodeToUTF8` 再逐个校验并编码。本库把两层合并成一个返回 `String` 的函数，**合并时
两层各自的守卫都漏掉了**：

| 上游检查 | 位置 | 本库合并前的状态 |
|---|---|---|
| 分隔符前 `c > 0x7f` → 拒绝 | `decodePunycode` | 缺 |
| `digit_index`：仅 `a`-`z`(0-25) / `A`-`J`(26-35)，其余 -1 → 拒绝 | `decodePunycode` | **缺上界** |
| `isValidUnicodeScalar(S)` → 拒绝 | `encodeToUTF8` | 缺（改为 `?? UnicodeScalar(".")` 顶替） |

后果是本库**接受工具链拒绝的符号，并为它们编造标识符文本**。顶替字符恰好是 `.`，也
就是打印输出里的结构分隔符，所以 `main....()` 既是错的、又与真实嵌套上下文不可区分。

三处里 review 只点名了第三处。复核用均匀 a-zA-Z 语料重建差分后指出，**2582 例分歧里
2577 例来自第二处（digit 域），只有 5 例来自第三处**——按 review 的方案单修第三处，
差分几乎不变。第一处（分隔符前的非 basic code point）是本轮逐行对照上游源码时补出来
的，两轮 review 都没点名。

三处均为 `main` 既有，非本 PR 引入，且从未被裁决过（`KnownIssues.md` 无 punycode 条
目）。修的理由是愿景第 1 条：**性能与内存的所有收益，都不允许用输出偏差换**——那么
既有的输出偏差同样不能留。

### 2. `TypeDecoder` 窄化收口漏了第 6 处（愿景第 3 条）

`ffd6f87` 把 `TypeDecoder.swift` 里会 trap 的整数窄化改成 `Int(exactly:)` + throw，
commit message 自述为完整横扫。实际改了 5 处，漏掉 `.silBoxTypeWithLayout` 分支里的
`parameterPacks.append((Int(depth), Int(index)))`——它和已改的
`.dependentGenericParamCount` 那处只隔 16 行，在同一个代码块里。

这处从公共 API 完全可达（`Node.create(kind:index:)` 造树 + public
`decodeMangledType(node:)`），release 下同样 trap，`try?` 拦不住，32 位 watchOS 上阈
值是 2^31 而非 2^63。

**它能躲过一整轮 review，是 `KnownIssues.md` 第 1 条自己造成的**：该条把这一族 6 处
列为「已裁决暂缓」，而 review 流程的契约是「已裁决且理由仍成立的发现直接跳过」，于
是整族被整体跳过。这正是该条目 2026-08-02 更正里写下的失败模式原文——「清点不全会
把从未裁决过的崩溃点静默转为『已裁决』」——只不过这次是反过来：**修完不登记，同样
让清单失真**。5 处已修站点当时仍挂着「暂缓」。

### 3. `StackSafeExecutor` 两条（愿景第 3 条）

- `executeWithUncheckedSendability` 关掉了库里唯一一处泛型线程跳转的并发检查，而它给
  出的理由是假的：注释称「`NodePrinterTarget` 实现刻意不受约束，所以打印入口无法对泛
  型 target 使用受检变体」，但 `NodePrinterTarget: Sendable`、`DemanglingNode: Sendable`、
  `DemangleOptions: Sendable`，唯一调用点（`NodePrinter.swift:112`）的闭包只捕获
  `root` 和 `options`。复核实测换成受检 `execute` 后整库编译通过。更值得记的是时间线：
  `NodePrinterTarget: Sendable` 自 initial commit 就在，unchecked 变体 2026-07-29 才
  写——**这条注释从写下那天起就是错的**，不是后来失效的。
- `LargeStackThreadPool` 的两个测试 hook 是无同步的 `var`，而 `spawnWorker()` 在
  `condition.unlock()` **之后**才读它们；该类型其余每个可变属性都只在锁内访问。今天没
  有触发者（测试在 `detachNewThread` 之前设置，`shared` 从不设置），但类型的 Swift 6
  安全性因此落在调用点纪律上，而不是它在别处统一使用的那把锁上；`TimeInterval` 的撕
  裂读在 32 位 armv7k 上是可表示的。

### 4. 文档与代码对不上

- `README.md` 的 rich target 旗舰示例**编译不过**：`count` 已被 `77cf984` 改名为
  `writtenUnitCount`（改名的原因正是字素 `count` 不满足契约），README 没同步。这是
  **PR 内自我回归**——`5cc30c9` 加的示例，`77cf984` 改的名。
- `NodePrintState` 没有显式 `Sendable`。无关联值的枚举在模块内隐式 `Sendable`，但
  **`public` 类型的隐式推导不跨模块导出**，而 `NodePrinterTarget: Sendable`——于是
  「在 target 里存 `context()?.state`」这个被文档化的用法在下游根本无法拼写，库自己
  的测试却全绿（模块内推导生效）。
- `AGENTS.md:55` 与 `README.md` 仍写着 `popTypeReferenceScope()` 保留默认实现，而
  `c5b3258` 已经删掉了它。`CLAUDE.md` 是 `AGENTS.md` 的符号链接，所以 agent 指令也
  是错的。同批只更新了 `NodeStoreArena.md`，属部分更新。
- `NodePrinter.swift:2469` 的公共 API 文档注释里混了一句中文小节名，违反全局
  `CLAUDE.md`「所有代码注释一律英文」，且会出现在 Xcode Quick Help 与生成文档里。

## 设计

### Punycode：三处守卫补齐，语义与上游逐条对齐

数字域两个分支都收成闭区间；分隔符前逐个 scalar 校验 `<= 0x7F`；解码出的 code point
先过 `UInt32(exactly:)`（本库累加器是 `Int`，上游是 `uint32_t`）再过既有的
`isValidUnicodeScalar`，两关都改为抛 `DemanglingError.punycodeParseError`。

`isValidUnicodeScalar` **本来就在文件里**，只是从来只在 encode 路径被调用——修复没有
引入新判据，只是把已有判据接到该接的地方。

减 `0xD800` 之后的 `UnicodeScalar(_:)` 仍保留一个 `guard ... else { throw }`。它在上
一关之后不可达（能通过的值减去 `0xD800` 必落在 `0...0x7F`），写成抛错而非强解包，是
为了让将来任一边界改动不会把它变成进程中止。

**一个上游检查被判定为本库不可达，因此没有移植**：上游 `decodePunycode` 有
`if (n < 0x80) return false`。本库 `n` 初值 128、循环内只做非负累加、且已有溢出守卫，
故 `n >= 0x80` 恒成立。移植它只会增加一行永假分支。

### 其余修复

| 位置 | 改动 |
|---|---|
| `TypeDecoder.swift` `.silBoxTypeWithLayout` | `Int(exactly:)` + 抛 `TypeLookupError`，与邻居同款 |
| `StackSafeExecutor.swift` | 删除 `executeWithUncheckedSendability` 与 `UncheckedSendableBox`，唯一调用点改用受检 `execute` |
| `StackSafeExecutor.swift` | 两个测试 hook 由 `var` 改 `let`，经新增的带默认值 `init` 注入 |
| `NodePrintState.swift` | 显式 `: Sendable`，并在文档注释里写明为什么必须显式 |
| `README.md` / `AGENTS.md` | 示例修正；`popTypeReferenceScope` 的表述改为「同样没有默认实现」，并写出它**不同的**理由（配对要求，不是近似witness） |
| `NodePrinter.swift` | 中文小节名改为英文描述性引用 |

测试 hook 选择改 `let` 而不是「挪进锁」：挪进锁会让模拟失败的 `Thread.sleep` 卡住其
余所有提交方，而该延迟的存在意义恰恰是让多个提交方**同时**停在「已预留、尚未失败」
的状态。`let` 直接消灭竞态，而不是换一种纪律。

## 影响

### 源码兼容性

- **`Punycode` 收紧会拒绝此前被接受的输入。** 这是修复的目的：被拒的正是工具链本来就
  拒绝的符号。全量 corpus oracle（4.5M 符号）在修复后仍逐字节通过——真实符号不受影响。
- `NodePrintState: Sendable` 是**放宽**，不破坏任何现有实现。
- `executeWithUncheckedSendability` 是 internal，删除不影响下游。
- `LargeStackThreadPool` 是 internal；`init` 加了带默认值的参数，`LargeStackThreadPool()`
  仍然可用。

### ABI 兼容性

不适用（纯 SPM 源码分发，未开 library evolution）。

### 下游仓库影响

无需改动。唯一可感知的变化是此前会被接受的畸形 punycode 符号现在抛
`DemanglingError.punycodeParseError`——调用方本就要处理该错误类型。

## 验收

全部修复带复现测试，且**先确认修复前失败**：四个新测试在修复前以预期方式失败（三个
punycode 测试报「an error was expected but none was thrown」共 15 处，`TypeDecoder`
那个报 `.signal(SIGTRAP → 5)`），修复后全部通过。

| 测试 | 覆盖 |
|---|---|
| `DefectRegressionTests.punycodeDigitDomainMatchesUpstream` | 数字域上界；含 `J`/`z` 合法边界与真实阿拉伯语标识符的正向断言 |
| `DefectRegressionTests.punycodeRejectsUnrepresentableScalarsInsteadOfSubstitutingADot` | `?? "."` 顶替；端到端含复核 fuzz surface 的 `$s4main005tlDIvyyF` |
| `DefectRegressionTests.punycodeRejectsNonBasicCodePointsBeforeTheDelimiter` | 分隔符前非 basic code point |
| `DefectRegressionTests.parameterPackDepthAndIndexNearUInt64MaxThrowInsteadOfTrapping` | 第 6 处窄化；exit test |
| `ReadmeExampleTests`（新文件） | README 示例作为**真实代码**编译并运行；`NodePrintState` 的 `Sendable` 用编译期断言钉住 |

`ReadmeExampleTests` 是这批里唯一的结构性防线：示例漂移过两次，而散文对编译器不可
见，输出比对测试也看不见一个「未能 conform」的 target。**改该文件必须同批改
`README.md`。**

**一条排除记录。** 复核给出的两个 fuzz 头号符号里，`$s4main0016dlGBHpvDzAmnbBryyF`
**没有**进测试：实测它在本分支上修复前就已被拒（16 字符 body 之后剩下 `yF`，函数类型解
析先失败），断言它会抛错在修复前后都成立，属于 vacuous——留着等于虚报覆盖。留下的两个
端到端符号都实测确认过「修复前不抛错」。

这条同时是个方法论备注：给独立复核的指令里写了「别信 review 给的复现描述，自己验」，
**这条纪律对复核自己给出的复现描述同样适用**。逐条实测「修复前确实失败」是唯一能挡住
这类虚报的手段。

## 决策日志

- **2026-08-16**：`KnownIssues.md` 第 1 条（TypeDecoder 窄化族）**关闭**。净待修 6 处
  中 5 处由 `ffd6f87` 修复但未登记，第 6 处由本提案修复。条目里仍然有效的裁决（1492 /
  1495 是上游同款死代码）迁入第二部分保留。
- **2026-08-16**：本轮判定**不修**的发现，连同理由，记入 `KnownIssues.md` 第二部分
  N19–N22（`?? .copyable` 兜底、`<each A, B>`、`silBoxTypeWithLayout` 的 `children[2]`、
  跨 store `NodeIndex` 的 debug-only 守卫）。
- **2026-08-16**：`n < 0x80` 未移植，理由记在「设计」一节——本库不可达。
