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
