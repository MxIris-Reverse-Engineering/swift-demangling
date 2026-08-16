# PR #7 code-review 发现清单（`feature/node-store`）—— 两轮，均已闭环

本文件曾是 **PR #7 一轮 `max` 档 code-review 的完整发现记录**（15 条已验证发现 +
9 条未验证补充发现 + 1 条流程问题，每条带「四问」答案与修法方向）。按本文件的契约——
判定为「不修 / 误报」的条目迁进 [KnownIssues.md](KnownIssues.md)，判定为「修」的条目
修完后移除并在对应演进提案的决策日志里留一行——**第一轮全部条目已于 2026-08-09 处理
完毕**。本文件保留为闭环索引；完整的发现原文见引入本文件的 commit（`15f4b40`）。

**2026-08-13：第二轮（对抗性复核）已闭环，见文末[第二轮](#第二轮对抗性复核2026-08-13)。**
那一轮推翻了第一轮的两条结论、订正了一条数据，并找到一条前五轮全部漏掉的新缺陷。

## 元信息

| 项 | 值 |
|---|---|
| 审查目标 | PR #7 `feature/node-store` @ `9464265` |
| 对比基线 | merge-base `f913742`（已在 `main` 上） |
| 审查日期 | 2026-08-09 |
| 修复落地 | 同日，commit `e3bb13c`（F3/F4）→ `3b47e48`（F2/F1）→ `ef9c1f4`（F5–F10）→ `c432b33`（F11–F13）→ 第 5 步批（F14/F15 + 补充发现） |

## 处置索引

**已修（决策日志行所在提案）**：

| 发现 | 一句话 | 决策日志 |
|---|---|---|
| F1 | 整数陷阱家族第四次露头，清点范围扩到 Demangler/Remangler | 0004；清点全文在 KnownIssues 2026-08-09 更新。**补遗（同日）**：review 会话核实时发现第一轮横向排查按「窄化转换」特征扫、漏了 `demangleSwift3Index` 的纯环绕族（函数内 + 三个调用点共四处，无窄化），已实测确认可 trap 并同批补修；正确排查特征与元教训见 KnownIssues 补遗段 |
| F2 | 0xFF 对齐填充跳过在字节化后死代码（功能回归） | 0008；AlignmentGaps A9 行注记 |
| F3 | 测试 target 缺 `Lifetimes`，借用视图测试零覆盖 | 0008 |
| F4 | 语料验收 `try?` 吞失败；重跑翻出 11 个 stdlib 同拒符号 | 0008 / 0010 / 0011 各一行 |
| F5 | 空代跳过退休登记（维护者裁决方案 A：空代也保活） | 0010 |
| F6 | range 读丢 release 边界陷阱 | 0010 |
| F7 | 内存安全不变量只用 `assert` 守 | 0010 |
| F8 | `reserveCapacity` 精确扩容 + 退休链 = O(k²) | 0010 |
| F9 | 前缀匹配按字素簇比较（回字节域） | 0008；提案「行为差异，明示」补记 |
| F10 | `textUTF8` 索引基静默变 0 基（维护者裁决：改签名 `textUTF8Bytes`） | 0010 |
| F11 | store 侧文本物化没接 seam + 无有效性闸门 | 0008；分流点清单在 SpanBorrowedViews.md |
| F12 | 翻进程级 seam 污染并行套件（改直接入口） | 0008 |
| F13 | benchmark 窗口重叠 + `malloc_logger` 不恢复 | 0008；数字订正行在 0008/0009/0010 |
| F14 | 共享 store 散点读逐节点过锁（walk 级单次解析；原子发布暂不做已留档） | 0010 |
| F15 | 异步 `print` 缺生命周期锚点 | 0010 |

**补充发现（9 条，逐条复现后裁决）**：#1/#3/#6/#7/#9 见 KnownIssues **N9–N13**；
#2（采样器挂死守卫）与 #8（EmbeddedFlavorTests 双配置）已修，决策日志行在 0008；
#5（publish 每 intern 分配）已修，决策日志行在 0010；**#4（`SharedNodeStore` 无
`reference(at:)`，存下来的 `NodeIndex` 无法解析回引用）为真实 API 缺口但无当前消费方，
按提案制留维护者决定——若要补，属新增公开 API，走提案。**

## 流程问题（维护者已裁决：以后再说）

本 PR 覆盖的四份提案（0008 / 0009 / 0010 / 0011）状态轨迹均未经过 `Accepted` 即落地
实现（状态更新与实现同 commit）。**维护者 2026-08-09 裁决：补办与否以后再说**，本节
保留为该开放事项的记录。

## 留给后续的两件事

1. **吞吐空载复测**：F13 修复后的首次干净窗口 benchmark 因机器连续满载存在 ±17%
   跑次方差，吞吐数字只记录未定案（分配账目已定案并订正）。若需评估 F1/F6/F7 新增
   界检查的代价，须另行空载 A/B——见 0008/0009/0010 的 2026-08-09 订正行。
2. **补充发现 #4** 的 API 决定（上文）。

---

# 第二轮：对抗性复核（2026-08-13）

第一轮的结论被送去做独立复核。复核**没有**只是确认既有结论：它推翻了两条、订正了一条
数据、并找到一条第一轮到第五轮全部漏掉的新缺陷。三处修正如下，都带实测证据。

## 修正 1：F1-punycode 的归属判错了

第一轮把 punycode 越界 trap 判为「本 PR 新引入」（`ec3769a` 把 `readScalars(count:)`
换成 `readRange(count:)`，长度前缀从 scalar 数变字节数）。

**实测推翻**：`Punycode.swift` 在 head 与 main 两棵树里**逐字节相同**（`diff` 无输出）。
真正的缺陷在 `decodePunycode` 的内层循环——它在**读** `input[pos]` 前不检查越界，
`pos != endIndex` 那个判断只保护了**前进**。数字串耗尽时 `pos` 停在 `endIndex`，
下一轮迭代越界。lldb 在两棵树上给出同一个崩溃点：

```
Swift runtime failure: String index is out of bounds
frame #3: Punycode.decodePunycode(value="JJJJ") at Punycode.swift:220:25
```

**纯 ASCII 触发串 `$s4main004JJJJyyF`（17 字符）让 head 和 main 同时崩。** 它的字节数
等于 scalar 数，与 byte/scalar 语义毫无关系（`J` 解出的 digit 恒为 35，永远满足
`digit >= t`，循环不会正常退出）。

**后果不只是归属**：按第一轮的修法（改 `Demangler.swift` 的长度语义）**堵不住这个洞**。
修复落在 `decodePunycode` 的读取边界上。

## 修正 2：F9-`stripManglePrefix` 是误报

第一轮据此推断 `stripManglePrefix` 存在字节域/字素域错配。实测两版输出逐字节相同。
详见 [KnownIssues N14](KnownIssues.md)——那里记了推断错在哪（`getManglingPrefixLength`
返回的是字面常量，F9 改的是匹配方式不是计数方式）。

## 修正 3：长度语义变更的裁判数据不对

第一轮记「6 万条语料，Apple 100:0 站 HEAD」。用 1068 条**专门压 byte/scalar 边界**的
非 ASCII 差分语料复测，以 `xcrun swift-demangle` 为裁判：

| | 条数 |
|---|---|
| HEAD 正确 | 194 |
| **MAIN 正确** | **41** |
| 平局 | 578 |

方向仍是 HEAD 更优，但**不是 100:0**。那 41 条形态高度一致：全部 `head=OK, apple=REJ`，
且 41/41 带 punycode 标记——HEAD 在 punycode 路径上有一类系统性**误接受**。另外仅崩 head
的输入 92 条 vs 仅崩 main 的 52 条，本 PR 在非 ASCII 上净增 40 条会崩的输入。

## 新发现 F16：`NodePrinter` 的加法溢出（不可抛错的公开 API）

`demangleIndex()` 先 `require(value != UInt64.max)` 再 `return value + 1`——所以它
**能合法返回 `UInt64.max`**（输入 `18446744073709551614_` 时）。`NodePrinter.swift`
随后有六处 `(… .index ?? 0) + 1` 作用在同一个 `UInt64` 上。

实测三个触发串，**head 和 main 全崩，Apple 全部干净拒绝**：

| 触发串 | 站点 |
|---|---|
| `$s4main1fyyFyycfU18446744073709551614_` | `.explicitClosure` |
| `$s4main1fyyFyycfu18446744073709551614_` | `.implicitClosure` |
| `_$s9localtest5outeryyF11LocalStructL18446744073709551614_V6methodyyF` | `.localDeclName`，**默认选项下触发** |

lldb 确认崩在打印阶段而非解析阶段（`arithmetic overflow` at `NodePrinter.swift:378`）。

**这一条与整数陷阱族的其余成员属于不同的严重度类别**：`print(using:)` 是公开且
**不抛错**的，没有错误通道，所以修法不能是 `require`，只能回绕并**记日志**——静默回绕
会打出一个看起来正常的 `#0`，畸形符号不留任何痕迹。日志经 `DemanglingLogging` 协议
（`@Loggable`）落到 `com.mx-iris.swift-demangling:Diagnostics`，带上是哪一种节点溢出的。

**两道现有防线都看不见它**：源码扫描只读 `Demangler.swift`；行为 exit 测试只调
`demangleAsNode`，从不打印。两处都已扩容。

## 元教训：写对了特征，然后把它实现窄了

第一轮已经诊断出「整数陷阱族反复露头，是因为每次只圈定表面特征」，并在
`DefectRegressionTests` 的文档注释里写下了**正确**的排查特征：

> 任何吃 `conditionalInt()`/`readInt()` 结果的算术

这句话是对的。问题出在**从它构建出来的产物**——那份 `forbiddenSpellings` 列表：

1. 只编码了**递增**方向（`+ 1` / `Int(`），没有任何减法；
2. 只扫**一个文件**（`Demangler.swift`）。

第五轮找到的东西正好落在这两个收窄的交集之外：五处减法（`demangleIndex() - 1` ×3、
`index - 2`、`readScalar().value - '0'` ×2）不是递增形状，F16 不在 `Demangler.swift`。

**教训不是「再补几个字面量」**——黑名单本质上挡不住变量中转和 `$0` 闭包（F16 的
`.map { $0 + 1 }` 就是这么躲过去的）。真正的防线是**行为测试**：本轮把全部触发串做成
了 exit 测试，扫描降级为廉价的辅助。扫描本身也已解除两处收窄，并加了一条「扫到的文件
数必须等于预期」的自检——一个悄悄找不到输入的扫描会永远报「干净」。

## 本轮修复落地

| 条目 | 修法 |
|---|---|
| punycode 越界读 | `decodePunycode` 内层循环读取前加边界 guard；前进处冗余判断删除 |
| F16 printer 溢出 | 六处经 `displayDiscriminator(_:of:)` 收敛，饱和时回绕并记 os_log |
| 六处解析陷阱 | 先定界再算术；三处 builtin size 与两处 pass ID 各抽成一个 helper |
| `$sA$` 死循环 | 恢复上游的 `if (RepeatCount < 0) return nullptr` 语义；同时把边界从 `maxRepeatCount` 放宽到 `Int.max`，还原上游在 `A<N>_` 路径上的行为 |
| 恒真断言 ×2 | 删除（两个入口共享实现，结构上不可能单边失败），不可达分支改 `Issue.record` |
| `RetainCountVerification` 的 `try?` | 读取失败改为退出，不再静默回退内置语料 |
| `malloc_logger` 配对 | 加嵌套深度计数 + 保存槽改 `_Atomic` |
| F14 `print` 遮蔽 | 新增 `runPrintWalk(using:)` 协议**要求**，`print(using:)` 转发过去；`NodeReference` 改为覆写钩子 |
| `GrowableStoreBuffer` | 文档如实化；`append(contentsOf:)` 加非重叠 `precondition` |

**验证**：每条修复红态先失败（未修时 SIGTRAP / 挂死 / 断言不成立），修后全绿；
完整套件 532 tests / 36 suites 通过；83 万条 ASCII 穷举语料 + 32 万条数字边界定向语料
+ 1068 条非 ASCII 差分语料重扫，无残余 trap/hang；打印吞吐无可测变化（中位数 +0.19%，
机器自身波动 9.4%）。

**归属**：本轮全部缺陷在 `main` 上同样存在，无一由本 PR 引入。711 条问题输入在 `main`
上复跑，无一幸免。

---

# 第三轮：交叉复核与防线重构（2026-08-14）

第二轮的 15 条发现被交给另一个会话独立复核（它自建 PR head / main 两份 worktree，用
消费者包逐 case 实测退出码）。那一轮的**四处崩溃全部被独立证实**，同时**推翻了本方的
五条判断**。随后按复核结论落地修复，并重建了防线——重建当天就找出两处前六轮全漏的崩溃。

## 落地的修复

**A 组（`ffd6f87`）：四处从公开 API 可达的进程崩溃 + 一次横向排查**

| 位置 | 缺陷 | 触发 |
|---|---|---|
| `Demangler.swift:315` | `repeatCount + 27` 溢出（上一轮只挡住了窄化，没挡加法） | `$sA9223372036854775807_` |
| `Punycode.swift` 四处 | `&+`/`&*` 回绕致负数组下标 | `$s0022ab_bbZZZZZZZZZZZZZZZZa` |
| `NodePrinter.swift:1514/2188` | `UInt8(index)` 窄化，而 `print(using:)` 不可抛错 | `Node.create(kind: .differentiableFunctionType, index: 300)` |
| `Remangler.swift` 四处 | `UInt32(index)` 窄化，而 `mangleAsString` 是 typed-throws | index > UInt32.max |
| `TypeDecoder.swift` 七处 | 同族窄化（横向排查，review 未点名） | — |

修 punycode 的累加同时消掉了 `delta == -38` 的除零路径：`i` 从此单调不减，`delta` 不再为负。

**B 组（`6b19334`）：九项顺手修**

capacity-0 代的恒真 precondition、`NodeIndex` 依赖构建配置的 `Hashable`、静态
`rawChildIndex` 的边界检查（收敛 N13）、`UnretainedNodeReference` 继承的挂起式
`runPrintWalk`、Swift 3 恒假分支、`peek` 的下界守卫、采样器的重叠窗口、
`textUTF8Span` 的双次 view 解析、以及一条描述错误机制的注释。

## 防线重构：从「枚举坏拼写」换成「枚举输入空间」

第二轮留下一个尖锐事实：新加的禁用写法扫描**对当轮修的四处崩溃一处都看不见**，而那四个
文件里有四个全在它的 `scannedFileNames` 清单里，扫描照样全绿。原因是黑名单只能匹配字面
子串，看不见经变量中转的操作数——而四处缺陷全是这种。

三项改造：

1. **扫描域改为遍历整个 `Sources`。** 原先的手工文件清单，其自检只在**已登记**文件被
   改名时报警，永远发现不了「本该登记却没登记」——`TypeDecoder.swift` 和
   `Extensions.swift` 因此永久不可见。
2. **新增 wrapping 运算符审计扫描。** 全库 12 处 `&+`/`&-`/`&*` 全部合法（hash 混合、
   开放寻址探测、负载因子、刻意与上游对齐的解析回绕），但它们和 punycode 那处出事的写法
   **长得一模一样**。现在每处必须在相邻行写明为什么回绕是正确的，新增的一处不写就红。
   *刻意没有*扩展到窄化转换：全库 136 处，绝大多数安全且乏味，逐个要求注释只会产生被
   橡皮图章盖过去的噪声。
3. **新增两个边界值矩阵**（真正的防线）：
   - `everyKindSurvivesBoundaryIndicesThroughEveryConsumer`：枚举
     `Node.Kind.allCases` × 11 个整数边界 × {`print` ×2 档、`mangleAsString`、
     `canMangle`}，每个节点还额外裸测与包进 `.type`/`.functionType`/`.tuple` 各测一遍
     （第二处可微分性 trap 只在 `.functionType` 里才可达）。**靠 `allCases` 自动枚举，
     以后新增的 kind 当天就被覆盖，没有需要手工登记的清单。**
   - `boundaryNumbersInMangledShapesNeverTrap`：把边界数字代进 10 种真实符号形状，
     **demangle 成功后继续 print + remangle**——本轮四处缺陷有两处就在成功 demangle 的
     下游，止步于「能不能 demangle」的矩阵会对它们报绿。

## 矩阵当场找到的两处新缺陷（前六轮全漏）

**其一：`printAutoDiffSubsetParametersThunk` 的负长度 `prefix`。**
`lastIndex = children.count - 1`，节点无子节点时为 -1，`currentIndex = lastIndex - 4`
即 -5，`children.prefix(-5)` 直接 trap
（`Fatal error: Can't take a prefix of negative length`）。上游只从 demangler 构造的树
进入这个打印器，那种树必然带齐四个尾部子节点；公开构造面没有这个保证。已改为
`currentIndex > 0` 才走 prefix 分支。

**其二：`Remangler` 用 `assert` 校验输入树形状。**
`mangleDependentGenericParamValueMarker` 的三条 `assert` 在 Debug 下 trap、Release 下
消失——而它们消失之后，下面的 `node[_child: 1]` 会越界读。`mangleAsString` 是公开
typed-throws API，契约是把畸形树变成 `ManglingError`，`assert` 是错误的工具。已改为
`guard` + `throw`。

同族横向排查后区分两类：**校验输入树形状**的 assert（`assert(node.text != nil)` 三处、
`assert(enumNode.kind == .enum)` 一处）全部移除——它们下方本来就有完整的 throw 路径或
条件分支，assert 只是额外加了一个 Debug 期的 trap；**校验 remangler 自身内部不变量**的
assert（substitution 合并的 buffer 状态等 11 处）保留不动，那是 assert 的正确用途。

## 元教训：换工具类别，而不是把同一个工具做得更细

前五轮每一次都在同一个工具上加东西——往黑名单加拼写、往文件清单加文件。第二轮的复核
一针见血：这条防线**结构上**看不见「操作数经变量中转」这一整类，加多少条目都不改变这一点。

这一轮换了类别：黑名单枚举的是**已知的坏写法**，只能钉住见过的；矩阵枚举的是**输入空间**，
能找出没见过的。区别当场兑现——矩阵上线第一次运行就抓出两处崩溃，其中一处的机制
（负长度 `prefix`）和前五轮追的整数窄化家族根本不是一回事，任何形式的拼写黑名单都不可能
看见它。

黑名单降级为「已修拼写的回归钉」保留，这是它唯一称职的角色。

---

# 第三轮（`max` 档全量复审，2026-08-16）

## 元信息

| 项 | 值 |
|---|---|
| 审查目标 | PR #7 `feature/node-store` @ `2624d14` |
| 对比基线 | `next` @ `04c959b` |
| 审查日期 | 2026-08-15 |
| 复审 | 同仓库第二个 agent 会话独立复核（自建 head/base 只读 worktree、无执行证据条目自建 release 探针、上游 `swift-demangle` 对拍、git 考古） |
| 结论 | 15 条主发现**无一误报**；复审推翻本轮 1 条重提、订正 2 条新旧定性、加强 1 条 |

## 复审订正的三处（记录以免再犯）

1. **两条的新旧定性反了**：`PhysicalFootprintSampler.swift` 与 `CMallocCounter.c`
   在 `next` 上**不存在**（`git ls-tree` 为空），是 PR 新引入，初审记成了旧账。
2. **`stripManglePrefix` 重提不成立**：见 [KnownIssues N14](KnownIssues.md) 的
   2026-08-16 段。初审只读了 N14 第一段，漏了第二段已对该行为本身做过知情 won't-fix。
3. **一处连带影响点名错**：`NodeStoreTests.storeBackedPrintingDoesNotPopulateTheGlobalCache`
   自带防碰撞设计（唯一模块名探针、不断言 cache count），不受全局缓存被撑大的影响；
   泛化结论仍成立但受害者不是它。量级也偏高：进缓存的只有叶子，实测唯一节点平铺
   8.75 MB，对象化后是几十 MB 而非「几百 MB」。

## 处置索引

**已修（本批）**：

| 发现 | 一句话 | 回归测试 |
|---|---|---|
| 1 | `Remangler.getChildOfType` 用 `assert` 校验输入树后无条件读 `children[0]`；release 下 assert 消失、下标 trap，从公共 `canMangle` 杀掉进程（exit 133） | `DefectRegressionTests.remanglingAChildlessTypeWrapperFailsInsteadOfTrapping` |
| 2 | `printSpecializationPrefix` 的访问计数在 `if` 之外自增，而读 latch 的只有 `if` 内分支；`.default` 下计数照动，`printName` 的缓存写入守卫对该节点及全部祖先失败 | `DefectRegressionTests.aSpecializationNodeDoesNotDisableTheFragmentCache` |
| 3 | 打印深度守卫 `>` 改写成 `<` 少一层（769 而非 770 帧截断），与上游及基线不一致 | `DefectRegressionTests.theDeepestFullyPrintedChainMatchesTheDocumentedBudget`（release-only，见 #4） |
| 4 | `conditionalInt` 环绕累加把溢出数字串当合法值接受；上游对拍证伪「与上游对齐」的辩护 | `DefectRegressionTests.anOverflowingDigitRunIsRejectedRatherThanWrapped`；[KnownIssues #1](KnownIssues.md) 已更新 |
| 5（一半） | `" in "` / `" of "` 分隔词继承外层 nominal 的 scope（归属颠倒） | `NodePrinterScopeTests.contextSeparatorsCarryNoTypeReferenceScope` |
| 6 | `.otherNominalType` 走相同 `printEntity` 调用却不 push scope | `NodePrinterScopeTests.otherNominalTypeGetsTheSameScopeAsOtherNominals` |
| 7 | 验收测试基线用 `internsSubtrees: false` 却仍把全语料叶子钉进 `NodeCache.shared`；改用 `demangleAsNodeTransient`（附带：该套件耗时 471s → 308s） | 无（行为修正，由既有套件覆盖） |
| 8 | `Node.create` / `NodeCache.intern` 的 `text`+`children` 组合静默丢弃 contents，且 intern 键把不同 text 的请求合并成同一实例 | 编译期——不可能的重载已删除，非法组合无法拼写 |
| 9 | 提案总验收里构造上恒真的断言（同族此前已删过两次，独漏这处）；改为 `Issue.record` | 无（断言本身即产物） |
| 10 | 三处文档声称「公共 API 零破坏」，与三处刻意破坏矛盾 | 无（文档）；见 [NodeStoreArena.md](NodeStoreArena.md) 源码兼容性一节 |
| 11 | `PhysicalFootprintSampler` 用 `Thread.start()`（失败静默）+ `stop()` 无限等信号量；四个调用点无 `defer` 配对 | 改用带检查的 `pthread_create`；调用点加 `defer` |
| 12 | `CMallocCounter` 不平衡 `stop()` 的回滚使深度瞬时为负，并发 `start()` 误判嵌套 | `MallocCounterConcurrencyTests`（env-gated）；见下「无法测试的部分」 |
| 13 | `reserveCapacity` 的 2^30 钳制注释不实（trap 只是换了地方） | 无（注释如实化）；真修法进 0012 |
| 小 | 验收测试的墙钟比值断言放在非 `.serialized` 常开套件 | 改为打印提示 |
| 小 | `internTree` 的 per-walk memo 漏了叶子分支 | 无（有界代价，一行） |
| 小 | `hasChildren` 在 `Node` 上走 `!children.isEmpty`，每次调用重建 `Children` 并 retain | `DefectRegressionTests.hasChildrenAgreesWithTheChildCount` |

**转入提案**：条目 5 的另一半（scope 与 printCache 不组合）、通用遍历 API 的视图钉扎、
scope hook 从 kind 清单改为挂机制、`reserveCapacity` 按字节预算封顶、重复代码收敛
（含 N13 的合格关闭）——全部进
[`Evolutions/0012`](../Evolutions/0012-review-round-three-structural-followups.md)。

**转入 KnownIssues**：N14 维持原判并补记（重提不成立）；N13 重开为「限期收敛」（上次
关闭方式不满足其自订标准）；#1 的字符串级可达链已切断，条目降级不关闭。

## 本轮的两个方法论产物

**其一：把修复逐条回退，确认测试真的会红。** 四条修复回退后，四个新测试全部按预测
失败，且失败值与预测一致（缓存那条：131072 次写 = 2^16 × 2，正是按路径计价的数）。
写了测试不等于测住了——只有见过它红，才知道它盯的是什么。`getChildOfType` 那条是反
例：回退后的行为是**进程 trap**，会杀掉测试进程而不是报失败，这恰恰是它必须改成
throw 的理由。

**其二：写测试的过程本身找出了一条新缺陷。** 为 `CMallocCounter` 写并发测试时，测试
在**修复到位的情况下仍然失败**——查明原因不是修复没生效，而是深度计数器有一个更大的
设计缺口：一个多余的 `stop()` 撞上别人正开着的窗口时（depth == 1），会走
`previous_depth == 1` 分支**把别人的 hook 摘掉**，修复前后行为完全相同，因为深度计数
器区分不了「谁的 stop」。关闭它需要窗口所有权（`start()` 发 token、`stop()` 出示），
不是更好的计数器。当前 `ExclusiveMeasurementWindow` 用一把锁串行化所有窗口使其不可
达，属对未来调用方的潜在风险，已记在 `MallocCounterConcurrencyTests` 的文件注释里。

## 无法测试的部分（如实登记）

- **finding 12 的竞态本身**：需要让 `start()` 停在不平衡 `stop()` 的两条指令之间，没有
  这个 seam；采样深度也看不见这么窄的窗口。修复站在构造上（只减正值的 CAS 永不为负），
  不站在复现上。
- **finding 3 的深度边界**：debug 构建约 745 帧就爆栈（KnownIssues #4），768 的边界只能
  在 release 测试构建里跑。测试用 `#if DEBUG` 跳过，`swift test -c release` 时生效。
