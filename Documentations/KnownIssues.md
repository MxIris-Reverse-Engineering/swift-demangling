# 已知问题追踪（Known Issues）

本文件是 code-review 流程的**裁决记录**，分两部分。每次 review 先对照本文件，已裁决
且理由仍成立的发现直接跳过，不再重走「四问」；若新证据推翻了当初的理由，则更新本文件
并重新裁决。

概念背景：`Concepts/` 下的五篇（[遍历计价](Concepts/TraversalCost.md)、
[栈与崩溃](Concepts/RecursionAndStack.md) 与本文关系最紧）。词条速查见 [Glossary.md](Glossary.md)。

- **第一部分（下方 1–6 条）**：已确认真实存在、但经维护者决定**暂缓修复**的问题。
  每条记录：现象与根因、复现方式、影响面评估、暂缓理由。修复任何一条后请把该条目移除
  并在对应演进文档中记录修复。
- **第二部分（文末「误报与非缺陷」）**：经查证**判定为误报或刻意设计**的 review 发现。
  记录发现内容、裁决结论、理由与裁决日期，目的是让同一个发现不必被反复重新推导。

- **记录日期**：2026-07-30（PR #6 review 期间逐条用复现测试确认）。
- **暂缓决策**：下游消费方（MachOSwiftSection 等）当前未使用 `TypeDecoder` 的任何接口，
  故 TypeDecoder 范围内的健壮性问题本轮不修（维护者 2026-07-29 决定）。
- **2026-07-30 更新**：原第 3 条（调用方构造的环状 `Node`）已修复并移除——`NodeBuilder`
  现在对外只交付冻结节点，环从公开 API 不可构造（见 `Evolutions/0003-review-hardening.md`）。
  同轮新增第 3–5 条（打印缓存回放越过深度上限、2MB 探针窗口、TypeDecoder store 路径 O(k²)）。
- **2026-08-02 更新**：evolution 0006 的横向排查（按路径计价的整树遍历）新增第 6 条
  （TypeDecoder 在共享 DAG 上按出现次数解码）。
- **2026-08-02 更新（PR #6 第三轮 review 复核，evolution 0007）**：
  - 第 1 条的清点由「三处」补全为实测的 **8 处**（漏列 796 / 809 / 1451 / 1454）。
  - 第 4 条按回退后的上限（768）重写，量级扩大并新增「测试覆盖缺口」表。
  - 新增**第二部分「误报与非缺陷」**（N1–N8），收录本轮判定为误报或刻意设计的发现。
  - **TypeDecoder 范围的暂缓决策本轮有两处例外**：`decodeTypeSequenceElement` 的
    `.type` 裸解包与 `case .tuple` 的元素下标越界已修复（evolution 0007）——理由是本 PR
    自己已修同款模式的一处（`decodeMangledTypeDecl`），「修一半」的状态不可留。其余
    TypeDecoder 健壮性问题仍在暂缓范围内。
- **2026-08-07 更新（文档与代码对账）**：本文件与其余专题文档逐条核对当前代码
  （`feature/node-store` @ `f913742`），修正了三处已失效的表述——第 1 条的行号（代码
  移动后已全部偏移）、第 2 条引用的 `maxDepth = 160`（2026-08-02 已回退为 1024）、
  第 3 条引用的 `maxPrintDepth = 512`（同上，现为 768）。第二部分 N3 的残留待办
  （`DemanglingPrinter.init(options:)` 降为 internal）经查证已在 `5cc30c9` 完成。
  **裁决结论本身没有变化**，只是把过期的数字对上。
- **2026-08-14 更新（PR #7 第三轮：交叉复核 + 防线重构）**：本轮把第二轮的 15 条发现
  交给另一个会话独立复核，对方推翻了其中 5 条判断（详见
  [ReviewFindingsPR7.md 第三轮](ReviewFindingsPR7.md)）。本文件的变动：
  - N13 **已收敛**（静态 `rawChildIndex` 补回边界检查），并澄清「限期收敛」的时序。
  - N15 的 `precondition` 被发现在 capacity-0 的初始代上恒真，已修；同时订正该条目
    引用的 use-after-free 机制描述（ARC 上不成立）。
  - N5 重申一次，理由不变。
  - 新增 N16、N17 两条误报裁决。
  另外，本轮新加的边界值矩阵测试当场找出**两处前六轮全部漏掉的崩溃**，均已修复，
  记录在 ReviewFindingsPR7.md，不进本文件。
- **2026-08-09 注记（PR #7 review）**：本轮 15 条发现的完整记录与四问答案在
  [ReviewFindingsPR7.md](ReviewFindingsPR7.md)——裁决为「不修 / 误报」的条目才迁进
  本文件，已修复的条目从那里移除。
- **2026-08-09 更新（清点范围扩大并已修复，PR #7 review F1）**：review 指出第 1 条的
  清点范围只有 `TypeDecoder.swift`，`Demangler.swift` 从未被清点过——正是 2026-08-02
  更正所警告的「清点不全会把从未裁决过的崩溃点静默转为『已裁决』」，只不过这次漏的是
  整个文件。本轮把清点范围扩到 `Demangler.swift` / `Remangler.swift` / `NodePrinter.swift`
  并全库重扫（`Int(` 的非 `exactly`、非 ASCII 常量算术形式逐处过目），**找到的全部即修**，
  与 TypeDecoder 的暂缓裁决不同——demangle 入口是吃不可信输入的第一线：
  - `Demangler.swift` 六处：`demangleIndex` 的 `value + 1` 环绕、`demangleMultiSubstitutions`
    的 `Int(natural)` 窄化（连带 `Int(repeatCount + 27)` 化简）、依赖泛型参数 depth/index
    两处「先窄化后检查」、`demangleGenericSignature` 的 `count = index + 1` 环绕、
    Swift 3 路径 `nameStack` 下标的「`Int()` 先于界检查」——全部改为无符号域内
    `require` 界检查后再窄化/自增，超界抛 `DemanglingError`；
  - `Remangler.swift` 一处：substitution 哈希的 `Int(index)` 对调用方组装的超大
    payload 会 trap，改 `Int(truncatingIfNeeded:)`（哈希语义不变）；
  - `NodePrinter.swift` 重扫零发现。
- **2026-08-09 补遗（第一轮扫漏的 Swift 3 环绕族，review 会话核实时发现并实测确认）**：
  `Demangler.swift` 实为**十处**——上面六处之外，`demangleSwift3Index` 内部的
  `readInt() + 1` 环绕与其三个调用点的再 `+ 1`（`demangleSwift3GenericParamIndex`
  两分支、`demangleSwift3GenericSignature` 的参数计数）同批补修，四条触发字符串
  （`_Ttq18446744073709551615_` 等）已进 exit test。**为什么第一轮漏了（元教训，比
  多修四行更值钱）**：F1 头号站点 `demangleIndex()` 的缺陷本质是「环绕算术后自增」，
  但横向排查按「窄化转换」这个**表面特征**去扫同类——而 Swift 3 孪生不含任何窄化，
  纯 `UInt64` 域内 `+ 1` 环绕，按错误的特征扫必然漏。正确的排查特征是「**任何吃
  `conditionalInt()` / `readInt()` 结果的算术**」；拼写守卫测试的注释已把这条特征
  定义留档，新增同形拼写须入其禁止清单。
  行为守卫：exit test `DefectRegressionTests.malformedIndexArithmeticThrowsInsteadOfTrapping`
  （review 验证过的两条触发字符串，修复前 SIGTRAP、修复后抛错）；拼写守卫：
  `demanglerSourceAvoidsUncheckedNarrowingOfParsedNumbers` 钉住三种致陷拼写不得回归
  （对经中间变量洗过的转换失明——由 exit test 兜底，两道防线的盲区互补）。
  第 1 条本体（TypeDecoder 8 处）维持暂缓裁决不变。

---

## 1. TypeDecoder：多处会陷入（trap）的整数转换

对畸形输入，`TypeDecoderEngine` 的契约是抛 `TypeLookupError`；但以下位置用了会 trap 的
整数转换初始化器，守卫（guard）只挡 `nil` 不挡量级，超范围值直接使进程崩溃（SIGTRAP）。
均为 `main` 既有问题，非 node-store PR 引入。

> **2026-08-02 更正**：本条原先写作「三处」并只列了 4 个位置。全文件重扫后实际有
> 8 处——由于本清单是 review 流程「已裁决即跳过」所依据的机制，清点不全会把从未裁决过
> 的崩溃点静默转为「已裁决」。补全如下。
>
> **2026-08-07 更正**：行号按当前代码（`feature/node-store` @ `f913742`）重新对过，
> 8 处全部仍在；顺带修正两处的归属函数——原表把 `silBoxTypeWithLayout` 分支里的两处
> 记成了 `decodeRequirements`。

| 位置（`TypeDecoder.swift` @ `f913742`） | 转换 | 触发条件 |
|---|---|---|
| `decodeMangledType` 的 `.dependentGenericParamType` 分支（335 行） | `Int(depthValue)` / `Int(indexValue)` | depth 或 index `>= 2^63` |
| `decodeMangledType` 的 `.silBoxTypeWithLayout` 分支（807 行） | `genericParamsAtDepth.append(Int(index))` | `index > Int.max` |
| 同上（820 行） | `parameterPacks.append((Int(depth), Int(index)))` | depth 或 index `> Int.max` |
| `decodeMangledType` 的 `.integer` 分支（975 行） | `Int(index)` | `index > Int.max` |
| `decodeMangledType` 的 `.negativeInteger` 分支（981 行） | `Int(index)` | `index > Int.max` |
| `decodeRequirements` 的 `.dependentGenericInverseConformanceRequirement` 分支（1449 行） | `UInt32(index)` | `index > UInt32.max`（`?? .copyable` 兜底永远等不到转换完成） |
| `decodeRequirements` 的 layout constraint 分支（1474 行） | `alignment = Int(align)` | `align > Int.max`；**可达性未验证**，需确认 `align` 是否受 layout 语法约束 |
| 同上（1477 行） | `size: Int(size)` | 同上，可达性未验证 |

807 / 820 两处吃的是与其余各处**同一个**环绕十进制扫描器，可达性与下文的论证完全一致；
1474 / 1477 两处的 `align` / `size` 来源尚未追到底，修复前需先确认。

**从 mangled 字符串可达**：scanner 解析十进制数用环绕算术（`conditionalInt`，注释自述跟随
Swift 编译器对畸形输入允许溢出），因此任意 `UInt64` 都能从字符串进入节点树。已验证的
字符串级触发器（demangle 完全成功、decode 时崩溃）：

```
$s$9223372036854775807_D   → .integer 节点携带 2^63，Int(index) 崩溃
```

inverse requirement 的 index 走 `Ri<十进制>_` 语法同理可达；`.dependentGenericParamType`
的超大 depth 可由 Swift 3（`_T` 前缀）demangler 路径以原始 `UInt64` 构造
（`demangleSwift3GenericParamIndex`）。

**复现测试形态**（未入库）：Swift Testing exit test，断言 `processExitsWith: .success`
（body 内 catch `TypeLookupError` 后正常退出）；现状三例均以 `.signal(SIGTRAP)` 失败。

**修法方向**：8 处全部改用 `Int(exactly:)` / `UInt32(exactly:)`，超范围抛
`TypeLookupError`。

> **2026-08-16 更新：字符串级可达链已切断，本条降级但不关闭（第三轮 review finding 4）。**
>
> 上面「从 mangled 字符串可达」整段的前提是 `conditionalInt` 的环绕累加。该累加已改为
> 溢出即抛 `DemanglingError.integerOverflow`，因此**上表全部 8 处的字符串级触发器全部
> 失效**——超过 `UInt64` 的数字串在 demangle 阶段就被拒，进不了节点树。上面记录的触发器
> `$s$9223372036854775807_D` 仍然有效（2^63 在 `UInt64` 内，不触发溢出检测），所以本条
> **不能关闭**：只是把「任意 `UInt64` 都能从字符串进树」收窄为「任意 `UInt64` 值仍可从
> 字符串进树，但不能再由更大的数字串绕回构造」，以及手搭树依旧全部可达。8 处
> `Int(exactly:)` 的修法仍然要做。
>
> 附带：`conditionalInt` 那两行注释（「Swift 编译器对畸形输入允许溢出，所以我们有义务
> 照做」）**前提不成立**，据此把该处列为「刻意与上游对齐」的第三轮 wrapping 审计裁决
> 一并推翻。上游 `demangleNatural` 有显式溢出检测（`if (newNum < num) return -1000`，
> 每个调用方都在哨兵值上失败），`demangleBuiltinType` 另有 `size > 4096` 上限，
> `xcrun swift-demangle`（LLVM 21）实测**拒绝** `$sBi18446744073709551617_`；本库此前
> 接受它并打印 `Builtin.Int1`，与合法的 `$sBi1_` 逐字节相同。与 N8 同构：前提被证伪，
> 按本文件契约重新裁决为「修」。回归测试
> `DefectRegressionTests.anOverflowingDigitRunIsRejectedRatherThanWrapped`。

## 2. TypeDecoder 公开入口不经 `StackSafeExecutor`，小栈线程上深度守卫失效

`TypeDecoder.decodeMangledType(node:)`（含 `NodeReference` 重载）在调用线程原地执行——
这是**有意设计**（`TypeBuilder` 回调可能绑定 actor/线程，见方法文档），代价是栈余量由
调用方负责。而 unoptimized 构建下这里每个深度单位约吃 30KB 栈：在 512KB 的协作/派发
线程上，约嵌套 16 层（8–10 层 Optional 套叠）即先于守卫爆栈 SIGSEGV。
`demangle` / `remangle` / `print` 三族入口均自动经 `StackSafeExecutor` 保护，唯此入口
不对称，文档虽有要求（调用方自行 `withLargeStack`）仍属易踩的坑。

> **2026-08-07 更正**：本条原写作「`maxDepth = 160` 按 8MB 栈实测校准」。该常数已于
> 2026-08-02 回退为上游的 **1024**（见第二部分 N8），问题因此**变严重而非缓解**——
> 即使在完整的 8MB 线程上，实测约 250 层就爆栈，1024 的守卫根本轮不到生效。参见
> 第 4 条。

**修法方向**：不改变"回调在调用线程执行"契约的前提下，无法简单套用 executor 跳线程；
可考虑入口处检测剩余栈并在不足时直接抛 `TypeLookupError`（拒绝而非崩溃），或在文档升级为
编译期可见的 API 形态（如要求显式传入栈证明参数）。需要单独设计。

## 3. 打印缓存的完整 fragment 会回放到「本应截断」的深位置

`DemanglingPrinter` 的 fragment 缓存以节点身份为键，不含剩余深度。已有的截断防护
（`truncationCount` 检查）只挡「截断过的 fragment 入缓存」这一个方向；反方向缺口仍在：
浅处缓存的**完整** fragment，在深度逼近 `maxPrintDepth` 的位置命中缓存时被整段回放，
而无缓存的 walk 在同一位置会输出 `<<too complex>>`。后果有二：深度上限不再是单次输出
量的硬上界；同一棵树的输出依赖子树的遭遇顺序（与 C++ printer 的行为不一致，虽然每棵
树自身仍是确定性的）。

**影响面**：仅对抗构造可观测——需要共享子树 + 深度逼近 `maxPrintDepth`（现为 768）的
路径。回放的内容是该节点的真实完整渲染，所以是「输出过于完整」而非输出错误。

**修法方向**：fragment 记录自身渲染高度 `h`，命中时检查 `printDepth + h ≤ maxPrintDepth`，
不满足则走无缓存路径（该次不回放也不写缓存）。

## 4. 深度上限所需的栈超过 `StackSafeExecutor` 能保证的栈

> **2026-08-02 重新裁决**：本条原按 `maxPrintDepth = 512` 描述，问题是「2MB 探针
> 放行后深度预算最坏可耗 5.9MB」。上限已回退到上游的 768（理由见第二部分 N8：下游
> 在 512 下报 `<<too complex>>`，校准所依据的「真实符号最深 41 层」被证伪），
> 因此本条的量级随之扩大，重写如下。**这是三个上限回退后如实记录的代价。**

`StackSafeExecutor` 在调用线程剩余栈 ≥ 2MB 时原地执行，否则跳到 8MB 的池线程。而
`maxPrintDepth = 768`，unoptimized 下每层 `printName` 实测约 11.6KB，最坏 ≈ 8.9MB —— 
**超过池线程本身的 8MB**。实测：725 层能存活于 8MB 线程，745 层溢出。

因此存在两个窗口，unoptimized 构建下都会 SIGSEGV 而非输出 `<<too complex>>`：

1. **半耗尽栈窗口**：调用线程剩余 2–8.9MB 且符号单路径深约 180–767 层，探针放行、
   计数器来不及触发。
2. **满栈窗口**（512 时不存在，回退后新增）：即使跳到全新的 8MB 池线程，约 725 层
   以上仍先于计数器爆栈。

remangler（1024）与 TypeDecoder（1024，每层约 30KB）有同构的窗口，后者更窄——
其 8MB 线程实测在约 250 层溢出，远早于 1024。

**影响面**：需要 unoptimized 构建 + 极深符号 + （窗口 1 还需）半耗尽的调用线程栈。
release 构建帧小一个数量级，窗口大幅收窄。下游报告的 `<<too complex>>` 说明真实符号
会超过 512，但尚无证据表明它们接近 725——**需要下游提供实际触发的最深符号来定位**。

**测试覆盖现状（2026-08-02 常数回退的代价，需留档）**：由于 debug 构建下三个引擎的
栈都先于各自的深度上限死掉，「超限时优雅退化而非崩溃」这一性质**在本套件中已无法被
断言**——任何能触发上限的深度都会先让进程崩掉。因此随常数回退移除了 4 处断言：

| 测试 | 移除的断言 |
|---|---|
| `printingHandlesDepthsFarBeyondAnyRealSymbol`（原 `printingDegradesInsteadOfCrashingBeyondTheDepthLimit`） | 1000 层输出 `<<too complex>>` |
| `remanglingRoundtripsDepthsFarBeyondAnyRealSymbol`（原 `...AndRejectsBeyondIt`） | 150 / 1000 层抛 `ManglingError` |
| `decodesDeeplyNestedTypeInsideWithLargeStack` | 130 层抛 `TypeLookupError` |
| `printingDeepTreeOnCooperativeWorkerStackNeverCrashes` / `remanglingDeepTreeOnCooperativeWorkerStackNeverCrashes` | 深度列表由 `[200,600,1200,2400]` 收窄至 `[100,200,300]` / `[50,90]` |

各处均在代码注释中写明了移除原因并回指本条。**上述修法一旦落地，这些断言应当一并
恢复**（届时它们才第一次真正可测）。不受影响、仍跑到 2400 层的是引擎之外的迭代化整树
遍历（interning、`copy`、`Rewriter`、释放、store interning）——它们不经深度上限，
迭代实现与树深无关。

**修法方向**（按优先级）：
1. 入口按**实际剩余栈**折算本次生效的上限：栈少就早点 `<<too complex>>`，栈多就走满
   768。既堵住两个窗口，又不牺牲 release 构建的能力，贴合上游的形模型。
2. 把池线程栈提到 ≥ 16MB，并把探针阈值提到 ≥ 9MB（代价：跳线程更频繁、每线程内存翻倍）。
3. 仅在 unoptimized 构建下降低上限——**已否决**，同一棵树在 debug 与 release 下产出
   不同输出比现状更糟。

## 5. TypeDecoder store 路径每层重物化 decl 子树，O(k²)

`decodeMangledTypeDecl` 对走到的**每个**嵌套 decl 调 `materializedNode` 重建整棵子树
（`getUnspecialized` 也在物化结果上运行）；`NodeStore.materializeNode` 的 memo 只在单次
物化内有效，跨调用不缓存。嵌套 `k` 层的类型每层都重建自己的 context 链，合计 O(k²)。
实测：物化次数/解码比值 ≈ 0.56·k；深度 48 时 store 路径比 `Node` 路径慢 11.4×，且差距
随深度单调拉大。入口 API 的文档注释原先声称「不物化 `Node` 树」，已更正为如实描述。

**影响面**：仅 `NodeReference` 重载（PR 新增 API）；纯性能问题，非正确性。真实符号的
decl 嵌套深度通常在个位数，影响温和，但与该路径「零物化直读」的存在理由相悖。

**暂缓理由**：沿用上方 TypeDecoder 范围的暂缓决策。

**修法方向**：engine 内加 per-decode 的「store 索引 → 物化 `Node`」缓存；或让 decl
handoff 直接携带 `NodeReference`，把物化推迟到 `TypeBuilder` 真正需要处。

## 6. TypeDecoder 在共享 DAG 上按出现次数解码，深度上限约束不了总工作量

`TypeDecoderEngine.decodeMangledType` 沿子节点递归构建 `BuiltType`，没有按实例身份的
memo；唯一的守卫 `maxDepth`（现为 1024）只封顶**单条根到叶路径**的长度，不封顶路径条数。
替换反向引用让 demangle 输出本身是 DAG——同一子树实例出现在 k 条路径上就被解码 k 次，
`TypeBuilder` 回调也随之被调 k 次；构造的深共享 DAG 可以在不触碰深度上限的前提下把
回调次数推到指数级。这正是 printer 用 `printCache`、remangler 用 `deepEquals` 成对
memo 已经封掉的同一暴露面（evolution 0006 的横向排查发现），TypeDecoder 两者皆无。
`main` 既有问题，非 node-store PR 引入（`main` 与回退后的本分支上限同为 1024）。

**影响面**：仅 `TypeDecoder` 公开入口喂入共享 DAG 时；纯耗时/回调次数问题，产出的
类型值不受影响。真实符号共享深度浅，语料下无可测差异。

**暂缓理由**：其一，沿用上方 TypeDecoder 范围的暂缓决策（下游当前未使用）。其二，
与其余遍历不同，这里的修复**不是**纯机械加 memo：`TypeBuilder` 回调是用户代码，按
唯一实例去重意味着有状态 builder 的回调从「每次出现一次」变为「每个实例一次」——
与 `Node.Rewriter` 当年同款的公开契约语义变更（那次是刻意为之并文档化的），需要
单独决策与迁移说明，不适合混进无行为变化的修复批次。

**修法方向**：engine 内加「实例身份 → BuiltType」的 per-decode 缓存并在文档中声明
回调按唯一实例触发（对齐 `Rewriter` 的纯函数要求）；或保守方案——保持逐出现语义，
但加一个按已解码节点数计数的总量上限，超限抛 `TypeLookupError`。

---

# 第二部分：误报与非缺陷（已裁决，勿重复推导）

以下条目均来自 PR #6 的 code-review，经复现/对读/查史后**判定为误报或刻意设计**。
每条给出裁决理由；再次被报出时直接引用本节，不必重走四问。除非有推翻理由的新证据。

- **裁决日期**：2026-08-02（PR #6 第三轮 review 后的逐条复核）。

## N1. `printExtendedExistentialTypeShape` 读子节点 1 和 2

**发现**：该函数读 `children.at(1)` / `at(2)`，而 demangler 把子节点建在 0 和 1，
因此类型位置恒为 `<null node pointer>`；建议改读 0 和 1。

**裁决：非缺陷，刻意保持。** 这个 off-by-one 是**上游 C++ printer 自己的**
（`demangleExtendedExistentialShape` 与 `createWithChildren` 都建在 0/1，
`NodePrinter::printExtendedExistentialTypeShape` 读 1/2）。本库的契约是复现 Swift
编译器的 demangler，逐字节匹配 `swift demangle` 优先于产出更好看的输出——拿本库输出与
工具链对拍的消费方必须看到工具链所看到的。曾一度改为 0/1（分支中途），本轮改回。

实测（2 子节点的 shape）：读 1/2 输出 `existential shape for Swift.Int any <null node pointer>`，
读 0/1 输出 `existential shape for <A> any Swift.Int`。后者更可读，但与工具链不一致。

由 `NodePrinterRobustnessTests.printsExtendedExistentialTypeShapeTheWayUpstreamDoes`
钉住；函数体上方有长注释说明。**上游若修正其 printer，跟随上游改，不要走在它前面。**

## N2. `StackSafeExecutor.executeAsync` 缺少 `isRunningOnPoolWorker` 守卫

**发现**：`runOnLargeStack` 把 `!LargeStackThreadPool.isRunningOnPoolWorker` 标为
load-bearing，`executeAsync` 却无条件提交，可能死锁。

**裁决：误报。** 那个守卫的理由是「worker 的**阻塞等待**可能排在它自己正在跑的任务
后面」——关键在于 *wait*。`executeAsync` 不阻塞而是挂起，挂起的 task 不占用线程，
因此不构成等待环（代码内注释已说明）。另有一层保险：pool worker 是 8MB 栈，
`currentThreadHasSufficientStack`（阈值 2MB）会让它在提交点之前就直接 inline 返回。

附带发现的 `drainPendingWorkItemsWhileLocked` 在协作线程上同步执行他人任务，技术上属实，
但触发前提是 `pthread_create` 已经失败、线程池整体塌缩；该 drain 正是为修复一个**复现过的**
stranding 缺陷而存在（见 `LargeStackThreadPoolTests`）。在 OS 已无法创建线程时，
「阻塞一下协作线程」优于「任务永不执行」。不改。

## N3. `DemanglingPrinter.printRoot` 是 internal，SPI 消费方无法调用

**发现**：类型以 `@_spi(Internals)` 导出且 `init` 是 public，但 `printRoot` 是 internal，
所以「跨 root 复用 printer / 复用 fragment 缓存」不可得。

**裁决：非缺陷，刻意设计。** 打印被有意设计为**静态入口唯一**：只有
`NodePrinter.print(_:using:)` 与 `DemanglingPrinter.print(_:options:)` 能启动走查，
两者都经 `StackSafeExecutor`。若开放实例级 `printRoot`，一棵树能存活的深度就会取决于
调用线程的剩余栈——这正是该设计要消除的。跨符号缓存复用是这个取舍**有意付出**的代价。

唯一残留的整洁性问题：`printRoot` 既不可达，`public init(options:)` 就是一个构造出来
无法使用的 API 表面，应降为 internal。**已于 `5cc30c9` 完成**（2026-08-07 复核确认：
初始化器现为 internal，声明处写明了原因）。

## N4. `Set<NodeReference>` 不去重

**裁决：误报。** 完整论证见 `AGENTS.md` / `CLAUDE.md` 中 `NodeReference` 一节：
builder 插入即 hash-consing，**同一 arena 内「索引相同」就是「结构相同」**，`Set` /
`Dictionary` 正常去重（由 `hashedCollectionsDeduplicateWithinOneArena` 钉住）。
去重失败的现象说明每个元素来自各自独立的 arena——那是 `NodeReference(interning:)`
按设计产出的形状，用错了工具。

**唯一例外（真实但极窄）**：同一 arena 内插入 Unicode 规范等价、但字节不同的两种拼法
（NFC `caf\u{e9}` vs NFD `cafe\u{301}`）确实得到两个索引，因为文本 intern 按精确 UTF-8
字节比较。实测：`Set<NodeReference>` 得 2 个元素，`Set<Node>` 得 1 个。这是**刻意**的
（规范化的桥接会破坏跨表示相等的传递性，见 `NodeReference` 文档）。要触发需要同一标识符
在同一进程内以两种拼法出现，实际需对抗性构造。

顺带记录一个未文档化的相关行为：`Node.create(kind:text:)` 的叶子缓存以 `String ==`
（规范等价）为键，因此**先创建者的拼法胜出**，后来者的字节被静默替换——实测
`Node.create(text: NFD)` 返回的是此前 NFC 实例、其 `text` 字节是 NFC。属进程全局、
依赖创建顺序的行为，值得补文档。

## N5. `Int(someUInt32)` 在 32 位 `Int` 平台上 trap

**发现**：`NodeStore.swift` 等三处边界守卫写作 `Int(nodeIndex.rawValue) < nodes.count`，
在 watchOS（`Int` 为 32 位）上该转换本身会先于断言 trap。

**裁决：理论存在，实际不可达，不改。** 触发需要 `rawValue > Int32.max`（约 21 亿），
而 `NodeStore.NodeIndex(rawValue:)` 的初始化器是 `@usableFromInline`、**非 public**，
外部无法凭空构造索引；要让一个合法 store 自然产出 21 亿的索引，在 watchOS 上需约 25GB 内存。

需要区分两种机制：`Evolutions/0004` 禁止的是 `Int(UInt32.max)` 这类**常量**写法——它在
常量折叠期就把整个函数体缩减为无条件 trap，且构建全绿无诊断；而 `Int(变量)` 只在运行时
值超范围才 trap。因此 `DefectRegressionTests.librarySourceAvoidsWordSizeDependentIntegerConversions`
只扫三个字面量，与其目的是匹配的，并非「守卫太窄」。

**重申：维持不改，2026-08-14。** PR #7 第三轮 review 又一次提出同一条（这次连同
`BufferView.text(offset:length:)`、`withTextUTF8`、`reference(at:)`、
`NodeStoreBuilder.intern` 一起点名）。上面的理由逐条复核后仍然成立：这些位置的
`rawIndex` 全部来自 store 自身的缓冲区遍历，非 public 的初始化器挡住了伪造，两种结局
都是确定性 trap、只差诊断文案。**下次再有人提这条，先读这里。**

## N6. 遍历原语按路径计价（枚举类）

**发现**：`preorder()` / `inorder()` / `postorder()` / `levelorder()` / `all(of:)`
在共享 DAG 上按路径数（2^N）而非节点数计价。

**裁决：对枚举类操作是误报，刻意设计。** 这些操作枚举的是**逻辑树**，出现次数就是
正确答案；`Evolutions/0006` 的横向排查已明确将其归入「按出现次数是文档化语义」一类。

**下列例外曾是真实缺陷，已于 2026-08-02 修复（evolution 0007），勿再按本条跳过**：
`first(of:)` 与 `contains(_:)` 是**短路查询**，只回答「第一个是谁 / 有没有」，出现次数
对答案毫无影响，路径计价是纯浪费。0006 的裁决理由只论证了 `all(of:)`，被顺手套到了
这两个上。实测（无匹配、无法短路的加倍 DAG）：10 层 0.005s、14 层 0.074s、18 层 1.15s、
20 层 4.64s、22 层 **18.2s**，精确每 2 层 ×4；同一棵树上已去重的 `identifier` 恒为
0.0001s。修复采用与 0006 给 `identifier` 相同的方式（`printCacheIdentity` 去重），
正确性论证原样复用；由 `DefectRegressionTests.shortCircuitKindQueriesFinishOnADoublingDag`
及其 store 版本钉住（两者修复前均 30 秒超时判负）。

**残留的绕过路径（非缺陷，但需知悉）**：显式写 `node.preorder().first(of:)` 会拿到
`Sequence` 上的重载，重新变回按路径计价——去重版本挂在
`DemanglingNode where Self: Sequence, Self.Element == Self` 上，只有直接查询节点时才
命中。已在 `AGENTS.md` 的 Traversal 一节标注。

## N7. `Node.copy()` / `Node.Rewriter.visit(_:)` 的语义变更

**发现**：两者从「每次出现一次」改为「每个唯一实例一次」，属未声明的破坏性变更。

**裁决：属实，但是刻意的、已文档化的决策，不回退。** 动机是实测的指数级重建
（`Rewriter` 在 58 节点图上 720,891 次访问；`copy()` 把 48 唯一节点的真实符号展开成
131,070 个节点）。回退等于把指数爆炸放回公开 API。记录在 `Evolutions/0003` 与
`AGENTS.md`；`Evolutions/0001` 的「Source Compatibility」一节已于本轮更正为如实列出
四处破坏性变更。`Node.copy()` 的文档首句已改写，明确「every node」指唯一节点而非每次出现。

## N8. 三处深度上限下调（remangler 1024→384、TypeDecoder 1024→160、printer 768→512）

**发现**：下调基于 unoptimized 构建的实测，却无条件生效；release 构建帧远小于校准值，
等于白白削掉能力。

**裁决：确认为真，已全部回退到上游值（2026-08-02）。**

初判为「属实但不回退」，理由是旧上限在 debug 构建下必爆栈（见本文件第 4 条：768 ≈ 8.9MB，
连全新 8MB 线程都必爆），且三个常量均清除「真实符号最深 41 层」的 2 倍以上。

**推翻该裁决的证据**：下游消费方报告，普通的 SwiftUI 及同类泛型密集模块在 512 的打印
上限下会输出 `<<too complex>>`。也就是说「真实符号最深 41 层」这个语料测量**不成立**——
真实符号确实会超过 512，下调不是削掉理论能力，而是在截断本该正确的输出。前提被证伪后，
另外两个常量（同一批、同一套论证）也一并回退，而不是留下一个前提已倒的校准值。

回退后：`DemanglingPrinter.maxPrintDepth = 768`、`Remangler.maxDepth = 1024`、
`TypeDecoderEngine.maxDepth = 1024`，即上游 C++ 的三个值。

**代价如实记录**：下调想解决的 debug 构建爆栈风险是真的，回退后它也回来了，见本文件
第 4 条。结论是——那是一个栈安全问题，要当作栈安全问题解决（提高探针阈值、或按实际
剩余栈折算本次生效的上限），不能靠静默截断 release 构建能正常渲染的输出来换。

**教训**：这批常量的校准建立在一次语料扫描给出的「最深 41 层」上，而那次扫描的覆盖面
不足以代表下游真实负载。**再次下调任何一个上限之前，必须先有来自下游工作负载的语料
证据**，三处常量的注释里都写了这句话。

## N9. `NodeStoreBuilder.slotCount` 在槽数为 0 时死循环（PR #7 补充发现 1）

**发现**：`slotCount(holding:growingFrom:)` 用 `proposedSlotCount *= 2` 逼近目标，
`currentSlotCount == 0` 时 `0 * 2 = 0` 永不前进。

**裁决：属实但不可达，已用 `precondition` 把不可达性变成显式契约（2026-08-09）。**
三张槽表初值 4096 / 1024 / 1024，`resizeXxxSlots` 一律 `guard newSlotCount > current`
只增不减——0 从任何路径都到不了该函数。修法不是改循环（给不可达输入设计语义是过度
设计），而是在函数入口 `precondition(currentSlotCount > 0)`：万一未来某个新构造路径
把 0 递进来，得到确定性 trap 而非静默挂死。

## N10. `RetainCountVerification` 的判据与计数窗口（PR #7 补充发现 3）

**发现**：`unretained * 20 < retained` 在基线测到 0 时报 FAIL；且引用在计数窗口内创建。

**裁决：误报（fail-loud 正是想要的行为），2026-08-09。**
`retained == 0` 只在 interpose 没挂上或 watch 目标错误时发生——此时报 FAIL 是**正确**
行为（测量装置坏了就该喊，静默通过才是缺陷）。「窗口内创建引用」两个引擎的窗口形态
完全对称，比值判据不受影响；unretained 引擎实测 1.00 对/walk 恰为入口 `reference(at:)`
那一次，0008 决策日志已记账。

## N11. `forcesLegacyPath` 每次 demangle 过一次全局 `Mutex`（PR #7 补充发现 6）

**发现**：seam 读取在每次 demangle 的入口，每次都是一次 `Mutex` 往返。

**裁决：不修（成本不成立），2026-08-09。**
一次无竞争 `Mutex` 往返在 10ns 量级，单次 demangle 在 10µs 量级，占比 ~0.1%；0008 的
吞吐基准（77,893 symbols/s）就是带着这次读取测出来的。缓存化的前提是 seam 不可变，
而 SPI setter 仍然存在（尽管测试已禁止运行中翻转）；为 0.1% 引入「缓存与真值不一致」
的新状态空间不值。若未来 setter 移除、seam 降级为纯 env 常量，可顺手改为惰性 `let`。

## N12. `NodeStore` 整类 `@unchecked Sendable`（PR #7 补充发现 7）

**发现**：从「受检 `Sendable`」变成整类 `@unchecked`，检查面变宽。

**裁决：刻意设计，声明处已有完整论证，2026-08-09。**
`@unchecked` 的唯一原因是自管理缓冲（0010 步骤 1）编译器看不见其不可变性：每个存储
属性都是 `let`、已发布元素 write-once、冻结 store 无写者、共享 store 的写者只在已发布
计数之外追加并经锁槽重发布。论证完整记录在类型声明的 doc comment（`NodeStore.swift`），
review 的关切（「检查面变宽」）已由该注释 + `SharedNodeStoreTests` 的 TSan 全绿覆盖。

## N13. 三处重复代码（PR #7 补充发现 9）

**发现**：子节点索引解析的 switch 有三份、语料配方重复、benchmark 脚手架重复。

**裁决：不修（本轮），2026-08-09。**
子节点索引解析的两份 switch 在 `NodeStore` 内互指注释要求 lockstep（0008 落地时的
知情决策：数组版与 span 版无法共享实现）；语料配方与 benchmark 脚手架属清理项而非
缺陷，不随 review 修复批次动——单独的清理不带行为验证反而引入回归面。留待下次真正
触碰这些文件的批次顺手收敛。

**重新裁决：理由部分失效，降为「限期收敛」，2026-08-13。**
上面「互指注释要求 lockstep」这个理由，前提是两份 switch **确实保持了** lockstep。
第五轮 review 复核时发现它们的边界检查已经跑偏——注释要求同步，实际没同步。按本文件
头部自己的契约（「若新证据推翻了当初的理由，则更新本文件并重新裁决」），这一条不能再
以原理由继续挂着。

拆开看：
- **两份 switch**：理由失效。lockstep 靠注释维持而没有机制保证，已经漂了一次，还会
  再漂。**下次触碰 `NodeStore` 的批次必须收敛**，收敛方式要么是共享实现，要么是加一条
  对照两份边界检查的测试——注释不算机制。
- **语料配方与 benchmark 脚手架**：理由仍成立，维持不修。这两处没有「两份必须一致」的
  契约，漂了也不产生正确性后果。

**已收敛，2026-08-14。** 静态（`Span` 版）`rawChildIndex` 补回了实例版一直带着的
`edgeIndex < edges.count` 检查，两份 switch 的边界检查重新一致。

顺带澄清一处时序争议：第三轮 review 曾主张「PR #7 本身就是那个必须收敛的下一批」。
按 git 时间线不成立——本 PR 对 `NodeStore*` 的全部触碰都在 08-09 之前，而上面这条
「下次触碰必须收敛」写在 PR 的最后一个 commit（`5d2b476`）里，是在完全知晓本 PR 改过
`NodeStore` 的前提下写的，显式指向下一批。收敛发生在本轮，是因为本轮为修 N16 相邻的
`NodeIndex` 问题**又一次触碰了这个文件**，义务这才生效。

## N14. `stripManglePrefix` 把字节域长度喂给字素域 `dropFirst`（PR #7 第五轮 review）

**发现**：`Extensions.swift` 的 `stripManglePrefix` 用 `getManglingPrefixLength`（F9 后
改为按字节匹配）的返回值调用 `String.dropFirst`，而后者按**字素簇**前进。据此推断
`"$s\u{0301}4main4testyyF"` 会少砍 2 字节。

**裁决：误报，2026-08-13。**
实测 head 与 main 对该触发串及另外三组输入的输出**逐字节相同**，都是 `4main4testyyF`。

推断错在前提：`getManglingPrefixLength` 返回的是**字面常量** 3 / 2 / 14，不是算出来的
长度。F9（`ef9c1f4`）改的是**匹配方式**（`hasPrefix` → `utf8.starts(with:)`），不是
**计数方式**。所有被识别的前缀都是纯 ASCII，字节数恒等于字素数，喂给 `dropFirst` 的值
两版一致，不存在域错配。

附带确认一个两版都有的行为：组合音标会连同 `s` 一起被 `dropFirst` 吃掉（`$` + `ś` 算两个
字素簇）。这不是 PR 引入的，且这种输入本就不是合法 Swift 符号，不单独处理。

## N15. `GrowableStoreBuffer` 的别名危险（PR #7 第五轮 review）

**发现**：`GrowableStoreBuffer` 是可复制 `struct`，文档却称「类型系统已排除别名的复制」；
且 `append(contentsOf:)` 先取 `baseAddress` 再 `ensureCapacity()`，若源指向自身存储，
增长释放旧页后会从悬垂指针拷贝。

**裁决：文档失实已修，别名路径当前不可达，`~Copyable` 暂缓，2026-08-13。**
- 「类型系统已排除」确实说过头了：`~Copyable` 的是 `NodeStoreBuilder`（防止复制 builder），
  管不住模块内 `let snapshot = self.nodes` 复制出一个 buffer。文档已改为如实陈述。
- 别名的 use-after-free **当前不可达**：三个 `append(contentsOf:)` 调用点传的都是与目标
  无关的存储（`String` 的 UTF-8、独立的 `[UInt32]`、数组重载转发）；唯一取 `edges` 视图
  的地方（`NodeStoreBuilder.resizeManyChildrenSlots`）只读哈希，不追加。已加 `precondition`
  把这个前提钉住。
- 改 `~Copyable` 暂缓：它只解决第一半（复制），对 `baseAddress` 悬垂毫无作用，且会波及
  这里每一个存储属性与访问器。两个问题要分开处理，不要用一个 `~Copyable` 假装都修了。

**两处订正，2026-08-14。**

**其一：那条 `precondition` 曾经等于没钉。** 它的排除区上界写作
`existingBase + storage.capacity`，而 `StoreBuffer.init` 实际按 `max(capacity, 1)`
分配。初始代的 `capacity` 是 0，排除区宽度为 0，任何指针都能通过检查——恰恰在最需要
它的那一代。已新增 `allocatedCapacity` 并改用它做界。也就是说，上面「已加 `precondition`
把这个前提钉住」这句话，在写下时对第一代是不成立的。

**其二：use-after-free 这个机制本身在 ARC 上不成立。** 原描述说「第二个扩容的副本会
释放第一个仍在寻址的页面」——做不到：`storage` 是每个副本各自持有的**强引用**，还能写
的副本就是让页面活着的副本，两件事互斥。复制的真实后果是两份 `count` 分叉，各自
append 覆盖对方的元素（包括已发布给读者的元素）——**静默数据损坏，不是悬垂指针**。
类型文档里那句同样失实的注释已一并改写。

这两点都不改变结论：复制危险仍然存在，`~Copyable` 仍然暂缓。变的是「它到底会怎么坏」，
以及「原先以为钉住了的那一半其实没钉」。

## N16. `Remangler` 两处 `UInt8(index)` 被指为窄化陷阱同族（PR #7 第三轮 review）

**发现**：`Remangler.swift` 的 `trySubstitution` 有两处
`Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(index)))`，被列为与
`UnicodeScalar(UInt32(index))` 同族的窄化 trap。

**裁决：误报，2026-08-14。**
`findSubstitution` 返回 `UInt64?`，而这两处都在 `if index >= 26 { … } else { … }` 的
**else 分支**里——`index < 26` 已由条件本身保证，`UInt8(index)` 不可能失败，
`65 + index < 91` 也不可能溢出。

值得记一笔的是这条误报的来源：它是在「同族横向排查」时按**拼写**（`UInt8(` 后跟变量）
匹配出来的，没有读周围的控制流。横向排查按模式找候选是对的，但每个候选仍要单独确认
可达性——否则「修的是这一类」会变成「改的是长得像的那一堆」。

## N17. `textUTF8Span()` 混用两个 view 被指为正确性缺陷（PR #7 第三轮 review）

**发现**：`textUTF8Span()` 先经 `compactNode` 解析一次 view 拿描述符，再经
`store.currentView` 解析第二次拿边界与基址，被指为「一个 view 的描述符配另一个 view 的
基址」的正确性缺陷。

**裁决：正确性指控不成立，卫生问题已顺手修，2026-08-14。**
两次解析之间 view 只可能**前进**，而文本表是 append-only、每一代新缓冲区整段拷贝旧前缀，
且退休代由保活链持有——用旧 offset 到新 view 里读，逐字节相同，`precondition` 也恒过。
所以不存在读错数据的路径。

真实存在的是两件小事，已一并处理：多付一次共享 store 的锁，以及「同一个逻辑读跨两个
快照」这个坏味道。现在改为一次解析同时供给描述符和字节。
