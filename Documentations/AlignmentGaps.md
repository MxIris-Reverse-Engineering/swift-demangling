# 与上游 Swift 编译器的对齐缺口（Alignment Gaps）

> 内部对齐追踪文档。记录本 port（`Demangling` 库）相对官方 Swift 编译器
> `Demangling` 源码的差异，供后续逐项跟进修复。

## 对齐基准

- **上游版本**：`swift-6.3.2-RELEASE`（`/Volumes/SwiftProjects/swift-project/swift`）。
- **关键事实**：上游 `swift-6.3-RELEASE` → `6.3.1` → `6.3.2` 之间，`lib/Demangling/` 与
  `include/swift/Demangling/` **0 次提交**，三个 tag 的 demangling 源码逐字节相同。"跟进 6.3.2"
  等价于"全面对齐到 6.3 系列"。
- **审计日期**：2026-06-20。标 ✓ 的条目已逐行复核上游原文 / 当前 main 代码。

---

## ⚠️ 0. 仓库状态背景：Group A 改动已被维护者有意从 main 移除

2026-04-18 的 PR #2（`fix/alignment-gaps-group-a`）曾标记 MERGED，但其全部修复 commit
（`4888a6e`/`0e8e26b`/`7eaf080`/`fde5c7a`/`f168266`/`7beb685`/`005ca33`/`b8b4171`/`18d7c73`…）
**均不是当前 main 的祖先**；merge-base(`main`, group-a) = `6b05bc6`，main 之后走了独立的 14 commit
重构线。

**定性（已由维护者确认）**：这**不是 force-push 意外丢失，而是被有意移除**——group-a 的实现存在问题，
破坏了之前正常的功能。因此 `fix/alignment-gaps-group-a`（HEAD `d3fc911`）**已被否决，不可作为
cherry-pick 来源**，也不要照搬其 diff。

下表仅记录这些点上 **当前 main 与上游的客观差异**（与 group-a 的具体实现无关，是我对照上游原文复核得到的）。
要修其中任何一项，都必须 **重新独立设计实现、并用现有测试套件守护**，先逐项判断「到底是上游对、还是当前
main 的行为可接受」——group-a 的教训说明，盲目对齐上游可能引入 regression。其中 A12（Sq/Sa/Sp）已由
`091e15c` 用另一种方式独立修复。

### 实证：为什么 group-a 破坏了实现（dyld cache 全量测试）

`DyldCacheSymbolDemanglingTests.main` 遍历本机 dyld shared cache 全部 Swift 符号，用**系统 runtime
demangler**（`swift_demangle`）作 ground truth，逐个 demangle→remangle 比对。2026-06-21 实测：

| 分支 | 符号总数 | Passed | Demangle 失败 | NodeTree mismatch | Remangle mismatch |
|---|---|---|---|---|---|
| **main（基线）** | 4,522,605 | **4,522,605（100%）** | 0 | 0 | 0 |
| **重放 group-a** | 4,522,605 | 4,457,099 | **65,506** | 0 | 0 |

把 group-a 的 8 个代码改动 cherry-pick 到当前 main（A12 因已修而跳过冲突），引入 **65,506 个 demangle
失败**，精确拆分为 **32,753 个 `…MR` + 32,753 个 `…Md`**，其它为 0。**唯一根因是 A8**——`4888a6e`
删除了 metatype 的 `case "R"` 与 `case "d"`：

- `case "R"`（`typeMetadataMangledNameRef`）处理 **32,753 个真实 `MR` 符号**（如 `_$s5ARKit12DataProvider_pMR`）；
- `case "d"`（小写变体 `typeMetadataDemanglingCache`）处理 **32,753 个真实 `Md` 符号**（基线里它们靠
  `Md`→`MD` 豁免计入 known issues；删 case 后直接 demangle 失败，known issues 同步归 0）。

其余 7 个 group-a 改动在本测试中**零 regression**（零失败、零 mismatch）——但本测试覆盖不到某些路径
（如 `'D'` 顶层 type-mangling 符号不出现在 dyld cache），不能据此断定它们全部正确。

**核心教训**：对齐的 ground truth 是 **Apple 工具链的 demangler + 真实符号**，不是开源 `Demangler.cpp`
文本。实测系统为 **Apple Swift 6.3.2（`swiftlang-6.3.2.1.108`，Xcode 26.5）——与开源 `swift-6.3.2-RELEASE`
同一版本号 6.3.2**，但 Apple 闭源构建的 demangler 含开源 `lib/Demangling` 里没有的扩展（`MR`、小写 `Md`）。
这不是版本新旧，而是 **Apple 闭源工具链 vs swiftlang 开源仓库** 的差异。port 为对齐 Apple 工具链而实现的
`typeMetadataMangledNameRef` 与保留的小写 `'d'`（系统 `swift-demangle` 确认是真实 node kind）正是为此。
group-a 严格照搬开源源码删掉它们，正是其破坏功能的根因——**开源源码只是参考，最终基准是 Apple 工具链**。

### 逆向 Apple swift-demangle 验证（2026-06-21）

用 IDA 逆向 Apple `swift-demangle`（Apple Swift 6.3.2，静态链接、符号未 strip），反编译三个分发函数：

- **`demangleMetatype`（'M' 前缀）**：Apple 的 case 集合与 port `Demangler.swift:1398-1444` **逐 case 完全一致**（36 个），
  含开源 `lib/Demangling` 没有的两个 Apple 扩展——`R` → `TypeMetadataMangledNameRef`（kind 256）、小写 `d`
  （与 `D` 合并）→ `TypeMetadataDemanglingCache`（kind 255），以及 `X`→privateContextDescriptor、`z`→
  canonicalPrespecializedGenericTypeCachingOnceToken。port 全部覆盖，**metatype 零遗漏**。group-a 删 `R`/`d`
  与 Apple 工具链直接冲突。
- **`demangleBuiltinType`（'B' 前缀）**：Apple case = `A B D I O P T V b c d e f i j o p t v w`，**无 `'W'`**。
  port 多出的 `W`→`builtinBorrow`（`Demangler.swift:965-967`）是 Apple 不认的自创节点（系统对 `…BW` 返回
  `<<NULL>>` 印证）。无害（真实符号不出现）但非 Apple 行为。
- **`demangleImplResultConvention`**：Apple 用 bitmask `0x125C49`（基 `'a'`）允许 9 个字符 `a d g k l m o r u`
  （含 `l`=@guaranteed_address、`g`=@guaranteed、`m`=@inout）。port 仅 6 个 → **确认 B-H4 是真实 gap**，
  且 Apple 工具链确实需要这三个。
- **`demangleImplParamConvention`（13 case，含 `X`=@in_cxx）、`demangleSpecialType`（含 `x`/`X` SILBox）、
  `demangleThunkOrSpecialization`（partial-apply / reabstraction 全系 / keyPath equals+hash thunk / prespecialized
  等，port 以合并 `case "R","r"` / `"K","k"` / `"H","h"` 等覆盖）**：逐 case 与 port **完全一致**，无遗漏。

**结论**：port 的 metatype 分发与 Apple 工具链逐 case 一致（含 Apple 私有扩展），从代码层面解释了 dyld 测试
100% pass。逆向暴露的唯一真实 gap 是 `demangleImplResultConvention` 缺 `l/g/m`（B-H4，dyld cache 里大概率
无 SIL impl 函数符号故未触发）；`builtinBorrow` 是 port 多余项。

### Part A — group-a 改动的最终裁决（已处理，2026-06-21）

逐项对照 Apple（IDA 逆向 `swift-demangle`）+ 开源源码 + 测试后，group-a 的 11 个改动 **8 个正确、3 个是 bug**。
**正确的 8 个已 squash-merge 到 main**（commit `8d0b396`），3 个 bug 全部排除。守护：dyld 测试 4,522,605 符号
0 失败 + 374 单测全绿。

| # | 改动 | 裁决 | 依据 |
|---|---|---|---|
| A2 | `NegativeInteger` remangle `mangleIndex(index)` 而非 `0 &- index` | ✅ 已合并 | dyld 0 mismatch |
| A3 | keyPath `H/h` `isSerialized` 消费 `'q'` 字节 | ✅ 已合并 | dyld 0 mismatch |
| A4 | `demangleWitness` O/B 停止重复 pop NoValueWitness | ✅ 已合并 | dyld 0 mismatch |
| A5 | `NativePinningMutableAddressor` 字符 `p`→`P` | ✅ 已合并 | 开源 `Demangler.cpp:4140` |
| A6 | `globalVariableOnceDeclList` 子节点 `.reverse()` | ✅ 已合并 | dyld 0 mismatch |
| A7 | `$e`/`_$e` 设 `.embedded` flavor（+ EmbeddedFlavorTests） | ✅ 已合并 | 开源 `Demangler.cpp:759` |
| A9 | `0xFF` 对齐填充字节跳过 | ✅ 已合并 | 开源 `Demangler.cpp:1029` |
| A10 | concrete conformance 间距 `#N `（trailing space） | ✅ 已合并 | 开源 `NodePrinter.cpp:3264` |
| **A1** | `'D'` typeMangling 走 `popFunctionParamLabels`（`[labelList, type]`） | ❌ **bug 排除** | 破坏 `functionTypes` 测试（main 通过、A1 失败 9 例 `.unexpected`）；下游 2-child 也不完整 |
| **A8** | 删 metatype `case "d"`/`case "R"` | ❌ **bug，保留 d/R** | Apple 工具链发出，65,506 真实符号依赖（实证 + 逆向） |
| **A11** | `globalVariableOnceToken` 走 `printEntity` | ❌ **bug 排除** | 偏离 Apple（上游 `NodePrinter.cpp:3386` 合并处理 + 三元文案） |
| A12 | `Sq`/`Sa`/`Sp` element type 子节点 | ✅ 早已修 | 独立 commit `091e15c` |

> **教训**：group-a 是 subagent 生成的低质量批次，11 个改动含 **3 个 bug**（A1/A8/A11）。合并前必须逐项对照
> Apple（逆向）+ 开源 + 测试守护，不能整体信任“已 review 的 PR”。A1 的下游隐患（`.typeMangling` 2-child）随
> A1 一并排除，不复存在。`typeMetadataMangledNameRef`('MR') 与小写 `'d'` 是 Apple 6.3.2 工具链的真实扩展，
> **必须保留**。

---

## Part B — 新增 6.3 对齐 gap（Group A 未覆盖）

> 进度（2026-06-21）：**Part B 已完全清零。**
> - **已修复并合并**：B-H4、B-H1 extension `'e'`（`04dc0b4`）；B-H5、B-H2、B-H3、B-M1、B-M2、B-M3、
>   B-M4、B-M5、B-M6、B-L4（`2099541`）；B-H1 preamble `'q'` + B-H6 `PreambleAttachedMacroExpansion`
>   node kind 全套 demangle/remangle/print（`ae500e2`）。每项均逐项对照 Apple（IDA 逆向 + `swift-demangle`）
>   验证 + 对抗式复核 + 新增回归测试，并由 dyld 4,522,605 符号 0 失败 + 381 单测守护。
> - **撤销（经验证非 bug）**：B-L1（ValueWitnessKind 编号——Apple 把 node index 当 opaque token，用同一
>   enum 读回，port 输出已与 Apple 一致）。

### 🔴 High

#### B-H1. Demangler 漏 `@attached(extension)` 与 preamble 宏解析 ✓
- **PORT**：`Demangler.swift:2652`（`demangleMacroExpansion` switch 只有 `a/r/m/p/c/b/f/u/X`）
- **UPSTREAM**：`Demangler.cpp:4549-4561`（`#include MacroRoles.def` 展开全部 role）
- **权威字符表**（`MacroRoles.def`）：`Accessor=a` / `MemberAttribute=r` / `Member=m` / `Peer=p`
  / `Conformance=c` / `Extension=e` / `Preamble=q`(experimental) / `Body=b` / `Freestanding=f`
- **差异**：缺 `'e'`(extension) 与 `'q'`(preamble)。`extensionAttachedMacroExpansion` node 已存在、
  remangler 也有 `fMe`，但 demangler 无法解析 `…fMe…` → `throw failure`（demangle/remangle 不对称）。
- **修复**：✅ extension `'e'` 已合并（`04dc0b4`，demangle + 既有 remangle `fMe` 对称）；preamble `'q'` 未做（experimental，不在本次范围，随 B-H6）。

#### B-H2. Remangler memberAttribute 字符错误：`fMA` 应为 `fMr` ✓
- **PORT**：`Remangler.swift:3609`（append `"fMA"`）
- **UPSTREAM**：`MacroRoles.def:55`（`r`）→ `Remangler.cpp:3256`
- port demangler 解析的是 `'r'`（`Demangler.swift:2654`），自身 demangle→remangle 都无法 round-trip。

#### B-H3. Remangler 全部 7 个 attached macro 子节点顺序错误 ✓
- **PORT**：`Remangler.swift:3602-3635`（均 `mangleChildNodes(全部)` 再 `append` code）
- **UPSTREAM**：`Remangler.cpp:3250-3258`（宏：`mangle child 0,1,2` → `"fM"+char` → `mangle child 3`）
- 子节点布局两侧一致 `[context, attachedName, macroName, discriminator]`（port `Demangler.swift:2678-2687`）。
  port 把 discriminator mangle 进 code **之前**，应在之后。`accessor/memberAttribute/member/peer/
  conformance/extension/body` 七个全部 round-trip 破坏。参照 `mangleObjCAsyncCompletionHandlerImpl`
  （`Remangler.swift:4113`）写法。
- **旁注**：freestanding `fMf` 上游顺序更特殊（`Remangler.cpp:3242-3246`），需一并复核。

#### B-H4. `demangleImplResultConvention` 缺 `l`/`g`/`m` ✓ — ✅ 已修（`04dc0b4`）
- **PORT**：`Demangler.swift:1210-1224`（只有 `r/o/d/u/a/k`）
- **UPSTREAM**：`Demangler.cpp:2290`（额外 `l`=@guaranteed_address、`g`=@guaranteed、`m`=@inout）
- 含上述 result 约定的 SIL `I…` impl 函数类型（read/modify coroutine、borrow 返回）会失败。
- **修复**：✅ demangle 补 `l/g/m` + remangler result 反向映射（`@guaranteed_address/@guaranteed/@inout`），已合并（`04dc0b4`）。

#### B-H5. TypeDecoder differentiability 解码恒为 `nonDifferentiable`
- **PORT**：`TypeDecoder+Types.swift:741-754`（按 `1/2/3/4` 映射）；调用点 `TypeDecoder.swift:379`
- **UPSTREAM**：`TypeDecoder.h:1006-1028`（把 child index 当 char 值 `'f'/'r'/'d'/'l'` switch）
- demangler 存 char 值（`'d'=100/'l'=108/'f'=102/'r'=114`），TypeDecoder 按 1/2/3/4 读 → 全落 default。
  经 TypeDecoder 的 `@differentiable` 函数类型全部丢失可微性（NodePrinter/Remangler 路径正确）。
- **修复**：`init(from:)` 改按 char 值映射，与 `Differentiability`（char-based）对齐。

#### B-H6.（关联 B-H1）补 `PreambleAttachedMacroExpansion` node kind
- **PORT**：缺失（node kind + demangle `q` + remangle `fMq` + print introducer `"preamble"` 全缺）
- **UPSTREAM**：`DemangleNodes.def:211`；`NodePrinter.cpp:1591-1598` 区域
- experimental，本身 Low，但与 macro 批同源，建议一起补全。

### 🟡 Medium

| 项 | 位置 | 问题 |
|---|---|---|
| B-M1 `popAnyProtocolConformance` 漏 opaque | `Demangler.swift:529-540` | 缺 `.dependentProtocolConformanceOpaque`（**勿动** `popDependentProtocolConformance`，那个与上游一致） |
| B-M2 `displayLocalNameContexts` flag 缺失 | `DemangleOptions.swift` | 上游公共 flag（默认 true），NodePrinter 消费于 `NodePrinter.cpp:1693/3576/3639`，门控 local context 显示 |
| B-M3 `showClosureSignature` 定义未接线 | `NodePrinter.swift:245/304` | 闭包签名实际挂在 `showFunctionArgumentTypes`，该 flag 永远无效（上游 `shouldShowEntityType` `NodePrinter.cpp:1410`） |
| B-M4 `DependentProtocolConformanceOpaque` 文案 | `NodePrinter.swift:1058` | `"dependent result conformance"` 应为 `"opaque result conformance"` |
| B-M5 `uniqueExtendedExistential…` 复制粘贴 | `NodePrinter.swift:513-515` | unique 引用错打成 `"non-unique existential shape…"` |
| B-M6 `ProtocolListWithAnyObject` 前缀门控 | `NodePrinter.swift:996-999` | 只判 `qualifyEntities`，上游还需 `displayStdlibModule`（`NodePrinter.cpp:2740`） |

### 🟢 Low

- **B-L1 `ValueWitnessKind` rawValue 互换** ✓：`ValueWitnessKind.swift:7-8`（`destroyArray=5`/`destroyBuffer=6`），
  上游 `ValueWitnessMangling.def` 为 `DestroyBuffer=5`/`DestroyArray=6`。`code` 字符映射正确、内部
  round-trip 自洽，仅外部把 `.index` 当 canonical 编号比对时有影响。
- **B-L2 `demangleDependentConformanceIndex` 缺 `index<=0` 拒绝**：`Demangler.swift:595-601`（上游 `Demangler.cpp:2062`）。
- **B-L3 `builtinBorrow`('BW')（逆向确认 Apple `demangleBuiltinType` 无 `'W'`——是 port 多余的自创节点，非 Apple 扩展）**：`Demangler.swift:965-967` 等。上游无 `'W'` builtin 分支，不撞车，
  6.3.2 不产生，属向前兼容隐患。（`typeMetadataMangledNameRef`/'MR' **必须保留**——见 A8 实证，处理 32,753 个真实 Apple 符号；勿当 stale 删除。）
- **B-L4 `SpecializationPass` 缺 4 个 case**：`SpecializationPass.swift`（上游 `Demangle.h:158-170`）。该 enum
  当前未被引用（demangler 用裸数字 `0...9` 校验），纯前瞻。
- **B-L5 公共便利 API 未提供**：`isAlias/isClass/isEnum/isProtocol/isStruct/isObjCSymbol`、
  `Context.getModuleName/getThunkTarget/isThunkSymbol/hasSwiftCallingConvention` 等，视 RE 工具需求。
- **B-L6 无 OldDemangler / OldRemangler**：已知设计取舍（`_T` 无 `0` 旧 mangling 的 remangle 未实现；
  `_Tt` 经 `demangleObjCTypeName` 处理）。非 6.3.2 增量。

---

## Node Kind 层结论

- port 的 `Node.Kind` 现已与上游 `DemangleNodes.def` 完全对齐（`PreambleAttachedMacroExpansion` 已于 `ae500e2` 补齐，见 B-H6）。
- `weak`/`unowned`/`unmanaged` 来自上游 `REF_STORAGE` 宏展开（`DemangleNodes.def:286-287`），保留正确。
- `typeMetadataMangledNameRef`('MR')、小写 `Md`：开源 `lib/Demangling` 无，但 Apple 6.3.2 工具链有（系统 `swift-demangle` 解析为真实 node kind，port 已对齐）；`builtinBorrow`('BW') 同类，待真实样本实证。见 A8 / B-L3。

## 已确认无差异（覆盖良好）

Pack/SILPackDirect/Indirect/PackExpansion、`Integer`、Inverse requirement、`Isolated`/`Sending`、
`BuiltinFixedArray`、`ConstrainedExistential`、`borrow`/`mutate` accessor、`RepresentationChanged`、
`ConstValue`、`CoroFunctionPointer`、`DefaultOverride`、`DependentGenericParamValueMarker`、
StandardTypes 替换表（含 `TaskExecutor`/`UnownedJob`/`MainActor`/`CancellationError` 等）、
`SymbolicReferenceKind`、`Directness`、`FunctionSigSpecializationParamKind`（含 bitmask）、
`ManglingFlavor`、`ManglingError`、function-type flags 打印、sugar、generic signature `each`/`let`/`where`。

---

## 建议修复路线

1. **Part B 是更安全的切入点**——group-a 从未触碰，与被否决的改动无关。先做 macro 批
   （B-H1/B-H2/B-H3/B-H6）→ B-H4（impl result 约定）→ B-H5（TypeDecoder 可微性）。
2. **Part B Medium**：B-M4/B-M5（文案，秒修）→ B-M1（opaque）→ B-M2/B-M3/B-M6（选项语义）。
3. **Part A 谨慎、逐项重做（不要 cherry-pick group-a）**：每项先确认「上游对、还是当前 main 行为可接受」，
   再设计不破坏现有测试的实现；改 A1 时务必同步其下游消费方（NodePrinter/TypeDecoder）。
4. **Low**：按需。
5. **测试守护**：任何改动前后跑全套 `swift test`，确保通过数不下降——group-a 正是因破坏既有功能而被移除。
