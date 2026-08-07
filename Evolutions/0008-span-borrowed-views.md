# 0008 - Span 借用视图：扫描器 UTF-8 字节化与 store 读路径去 ARC（双路径）

- **Proposal**: 0008
- **Author**: Mx-Iris
- **Status**: Draft
- **Date**: 2026-08-07
- **Last Updated**: 2026-08-07
- **Branch**: TBD（未开工）
- **Related**: `Evolutions/0001-node-store-arena.md`（arena 本体；本条兑现
  `Documentations/NodeStoreArena.md` 「后续方向」中的 **`Span` 借用视图**一项）；
  `Documentations/Concepts/ArenaStorage.md`（概念背景：class 节点的成本都花在哪）

## Summary

前提事实放最前：**`Span` 家族的核心类型已向后部署到旧 OS**（实测见 Motivation 的
可用性表），采用它们**不需要动 deployment target**（macOS 10.15 / iOS 13 不变）。
仍有门槛的特性分两类——被 **OS 运行时版本**卡的（`.span` 属性、`UTF8Span`、
`InlineArray`，都要 macOS 26 / iOS 26）和被**编译器能力**卡的（生命周期标注、
borrow accessors）。本提案对这两类**都不绕开，全部采用，写两套**：

1. **Demangler 扫描器字节化（双入口）**：`ScalarScanner` 从泛型
   `Collection<UnicodeScalar>` 改为基于 `Span<UInt8>` 的具体类型字节扫描（mangled
   符号是纯 ASCII，字节扫描与 scalar 扫描等价，换来随机访问、O(1) 回退、整数偏移
   即位置）。入口双路径：macOS 26+ 走 `String.utf8Span`（免拷贝、免闭包），旧 OS 走
   `withUTF8` 桥接；文本物化双路径：新路径 `String(copying: UTF8Span(unchecked:))`
   免二次 UTF-8 校验，旧路径 `String(decoding:)`；word 表双路径：新路径
   `InlineArray<26, Range<Int>>` 栈上词表，旧路径 `ContiguousArray`。
2. **`NodeStore` 读路径**：文本借用视图三种形态并存（闭包式全平台基线、
   `@_lifetime` 直接返回式按编译器能力门控、`ArraySlice` 旧 API 保留）；store 打印
   walk 消除逐 child 的 store retain/release（`unowned(unsafe)` 句柄 + 作用域保活，
   `Span` 负责紧循环的缓冲借用直读）；`internText` 去掉每次调用的 `Array` 物化；
   store 文本物化同样走免校验双路径。
3. **公共 API 面稳定**：所有既有公共入口保持 String 基底不变（已核实泛型
   `Demangler<C>` 面是 internal）；依赖实验特性的直接返回形态先以
   `@_spi(Internals)` 交付，官方提案落地后再转 public。

Swift 6.4 才解锁的特性（SE-0507 borrow accessors、`UniqueArray`、`RawSpan` 安全
加载等）不随本批实施，记入 Future Directions；但本批的双路径结构就是为它们预留的
落点——工具链到位后是「换门控条件」而不是「再改架构」。

## Motivation

### 前提：Span 家族的实际可用性（逐特性实测，非文档转述）

Apple 平台的 stdlib 类型受 OS 内置 Swift 运行时版本约束，这曾是本库（目标
macOS 10.15 / iOS 13）不能碰 `Span` 的理由。但核心类型以 `@_alwaysEmitIntoClient`
形式向后部署了：代码内联进使用方，不依赖 OS 运行时版本。逐特性实测（Xcode 26.6 /
Swift 6.3.3，对每项单独 `swiftc -typecheck`，target 如注）：

| 特性 | 10.15 target | 26.0 target | 本提案的用法 |
|---|---|---|---|
| `Span` / `RawSpan` 类型、下标、`extracting` 切片 | ✅ | ✅ | 全平台共享核心：扫描器与缓冲直读的工作表示 |
| `MutableSpan`（SE-0467）/ `OutputSpan`（SE-0485） | ✅ | ✅ | 本批暂无落点，Future 备用 |
| `UnsafeBufferPointer.span` 属性 | ✅ | ✅ | **旧 OS 桥接**：`withUnsafeBufferPointer { $0.span }` |
| `ContiguousArray.span` / `Array.span` 属性（SE-0456） | ❌ 要 macOS 26 | ✅ | **双路径**：新路径直取属性，旧路径走上一行桥接 |
| `String.utf8Span` / `UTF8Span.count` / `.span` / `String(copying:)`（SE-0464） | ❌ 要 macOS 26 | ✅ | **双路径**：新路径入口免拷贝、物化免二次校验 |
| `UTF8Span(unchecked:)` | ❌ 要 macOS 26 | ✅（实测存在） | 新路径物化的关键：跳过 UTF-8 校验扫描 |
| `UTF8Span.extracting` | — | ❌ 不存在（实测） | `UTF8Span` 不能直接切片——工作表示必须是 `Span<UInt8>`，`UTF8Span` 只在物化点包一层 |
| `InlineArray`（SE-0453） | ❌ 要 macOS 26 | ✅（含 `Range<Int>` 元素、struct 存储属性，实测） | **双路径**：新路径栈上词表，旧路径 `ContiguousArray` |
| `@_lifetime` 用于**属性** | ❌ 编译错误（加 `Lifetimes` 实验开关也不行） | 同左 | 属性形式等官方提案 / SE-0507 生态，Future |
| `@_lifetime` 用于**方法**（`borrowing func → Span`） | ✅（需 `-enable-experimental-feature Lifetimes`；含跨调用存活的消费方，实测通过） | ✅ | **随本批交付**：直接返回式借用视图，`#if hasFeature(Lifetimes)` 门控 + `@_spi(Internals)` |

两条关键推论：

- **`String(copying: UTF8Span(unchecked:))` 在两条入口上都是健全的**：`String` 的
  UTF-8 存储恒为合法 UTF-8，`withUTF8` 与 `utf8Span` 给出的字节同样合法；store 的
  `textBytes` 全部 intern 自 `String.utf8`，同理合法。`unchecked` 免掉的校验扫描是
  纯赚的——门槛只在这组 API 本身要 macOS 26 运行时，所以是 OS 双路径而不是
  正确性取舍。
- **工作表示统一为 `Span<UInt8>`**：`UTF8Span` 没有 `extracting`（实测），不能作
  扫描/切片的载体；它只出现在物化点（包一层 `unchecked` 后交 `String(copying:)`）。
  双路径因此不会分裂扫描核心。

### 扫描器现状的开销（`Main/Demangle/Demangler.swift`）

- `ScalarScanner` 泛型于 `Collection<UnicodeScalar>`，实际输入是
  `String.UnicodeScalarView`——非随机访问，每步 `index(after:)`，另维护 `consumed`
  计数器换取位置信息；`backtrack` 逐步回退。
- `readUntil` / `readWhile` 逐 scalar 往 `String.unicodeScalars` 上 append 构建结果。
- `demangleIdentifier` 的 word substitution 表是 `words: [String]`（至多 26 项），
  每个词物化一个小 `String`，拼接 identifier 时再逐个 append；C++ 上游存的是输入
  区间。
- `demangleOperatorIdentifier` 每次调用重建一遍 `opCharTable` 数组。
- `match(where:)` / `read(where:)` 的谓词标了 `@escaping`（无必要）；
  `readUntil(set: Set<UnicodeScalar>)` 用 `Set` 查 ASCII 字符。

这些在单符号上都是微量，但本库的本职是批量 demangle 整个二进制 / dyld cache（0001
的 234k 符号语料），扫描是每符号必经的第一段。

### store 读路径现状的开销（`Store/`）

- **逐 child ARC**：`NodeReference.ChildrenView.subscript` 每次访问构造一个
  `NodeReference`，其 `store` 是强引用——每访问一个子节点就有一对 store 的
  retain/release。打印 walk 期间 store 不可变且必然存活（walk 入口就持有它），
  这些 ARC 全部是白付的。
- `textUTF8` 返回 `ArraySlice<UInt8>`：32 字节、带 owner 引用，取一次付一对缓冲
  retain/release；`textMatches` 的字节比较根本不需要 owner。
- `NodeStore.text(offset:length:)` 用 `String(decoding:)` 物化——每次调用重新做
  UTF-8 校验扫描，而 `textBytes` 的合法性在 intern 时已经确立。
- `NodeStoreBuilder.internText` 每次调用 `Array(textValue.utf8)` 物化一个数组——
  **即使该文本已在字符串表里**（intern 命中路径同样付这次分配）。

### 现有数字与缺口

0001 Phase 3 验收：234k 符号构建 25.3s（debug，`Node` 路径 28.5s）。**解析吞吐与
打印吞吐没有独立基准**——本提案把「先建基准」定为 Phase 0 硬性门槛，动手前先量出
扫描与打印各占多少，避免优化不存在的瓶颈。

## Detailed Design

### 双路径策略（执行纪律，先于所有 Phase）

两条门控轴，各自的分叉点和纪律：

- **轴 1：OS 运行时版本**（`.span` 属性、`UTF8Span` 家族、`InlineArray`）——
  `if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)`
  分流。**检查只放操作入口**（每次 demangle 的入口、每次 walk 的入口、物化策略的
  选定点），绝不放逐字节访问处；入口处把选择固化成具体类型或策略位，之后的热路径
  无分支。
- **轴 2：编译器能力**（`@_lifetime` 直接返回式）——`#if hasFeature(Lifetimes)`
  条件编译 + Package.swift 对 `Demangling` target 加
  `.enableExperimentalFeature("Lifetimes")`。闭包式是永远存在的共享实现，直接返回
  式是它上面的薄封装；将来官方 lifetime 提案或 SE-0507（Swift 6.4）落地，改的只是
  门控条件与 attribute 拼写。

四条纪律：

1. **共享核心单份**：双路径只允许在入口、物化点、存储选型三处分叉；扫描逻辑、
   引擎逻辑、intern 逻辑永远一份。防的是两套语义漂移。
2. **两套产出逐字节一致**：与 store/`Node` 双路径打印的既有标准相同。
3. **可测性 seam**：内部开关（`@_spi(Internals)` 或环境变量）强制走旧路径，让
   macOS 26 的开发机 / CI 一台机器把两条路径都跑全量 corpus。没有这个 seam，
   旧路径会在新 OS 普及后悄悄失去测试覆盖——这是双路径方案最常见的死法。
4. **实验特性圈在 SPI 里**：`hasFeature(Lifetimes)` 门控的直接返回式 API 一律
   `@_spi(Internals)`，公共 API 面不随编译器版本变化；官方化之后再转 public。

### Phase 0 — 基准先行（门槛，不是可选项）

release 构建下建立三个基准并把数字记入本提案决策日志，之后每个 Phase 的验收都对照
它们：

1. 49k 语料：`String` → transient 树的纯 demangle 吞吐（symbols/s）；
2. 234k 语料：`NodeStoreBuilder.demangle` 端到端构建；
3. 49k 语料 × 3 套打印选项：store 路径打印吞吐。

配套每符号 malloc 计数（malloc hook 或 Instruments Allocations），作为「分配下降」
主张的量化依据。基准需在**新旧两条路径上分别跑**（用可测性 seam 强制旧路径），
双路径的性能差本身就是要记录的数据。

### Phase A — 扫描器字节化（双入口、双物化、双词表）

**核心（单份）**：`Demangler` 去掉泛型参数 `C`，`ScalarScanner` 改为具体类型：持
`Span<UInt8>` + `var offset: Int`。`consumed` 删除（offset 即位置），`backtrack` /
`peek` 变 O(1) 整数运算。`readUntil` / `readWhile` 返回 `Range<Int>`，`words` 存
`Range<Int>`（指向输入区间，用到才物化）——对齐 C++ 上游的做法。

**入口（轴 1 双路径，`DemangleInterface.swift`）**：

```swift
if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
    // 新路径：utf8Span 免拷贝免闭包借用整个输入；String 存储恒为合法 UTF-8
    let utf8 = mangled.utf8Span
    return try runDemangler(input: utf8.span, materialization: .validatedCopying)
} else {
    // 旧路径：withUTF8 闭包内借用（可能触发一次桥接字符串的拷贝）
    var mutableCopy = mangled
    return try mutableCopy.withUTF8 { buffer throws(DemanglingError) in
        try runDemangler(input: buffer.span, materialization: .decoding)
    }
}
```

`Span` 是 `~Escapable`，两条入口都把 demangle 全程约束在借用作用域内——与现有
结构一致（demangle 本就在单个函数体内完成），逃逸出去的只有 `Node` 树。

**文本物化（轴 1 双路径，策略位在入口固化）**：

- 新路径：`String(copying: UTF8Span(unchecked: span.extracting(range)))`——
  免 UTF-8 校验扫描（健全性论证见 Motivation 的推论一）；
- 旧路径：`String(decoding:as: UTF8.self)`（现状语义，带校验）。

物化点共三处：identifier 拼接、`readUntil` 类结果、suffix。策略以入口注入的枚举
（上例的 `materialization`）表达，物化函数内 `switch`——单份代码、无重复分支逻辑。

**word 表（轴 1 双路径，存储选型分叉）**：容量上限 `maxNumWords = 26` 是协议常量，
天然适配定长栈上存储。

```swift
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
struct InlineWordRanges: WordRangeStorage {   // InlineArray<26, Range<Int>> + count，零堆分配
    ...
}
struct ArrayWordRanges: WordRangeStorage {    // ContiguousArray<Range<Int>>，reserveCapacity(26)
    ...
}
```

`Demangler` 泛型于 `Words: WordRangeStorage`，入口按 `#available` 实例化
`Demangler<InlineWordRanges>` 或 `Demangler<ArrayWordRanges>`。**代价明示**：
demangler 主体产生两份特化，代码体积约 ×2（demangler 编译单元量级，非全库）；
这是「写两套」在存储选型上的实付成本，Phase 0 基准会记录两条路径的实测差值供
将来复核这笔开销是否值回。

**顺手收口（同批、无需单独提案）**：谓词去 `@escaping`；`readUntil(set:)` 的
`Set<UnicodeScalar>` 换 128-bit ASCII 位掩码（两个 `UInt64`）；
`demangleOperatorIdentifier` 的 `opCharTable` 提为 `static let`。

**行为差异，明示**：`DemanglingError` 携带的错误偏移从「scalar 计数」变「字节
偏移」。对合法 mangled 输入（纯 ASCII）两者恒等；仅对含非 ASCII 的**非法**输入
数值不同。corpus oracle 比对的是 demangle 输出，不受影响。

**源兼容已核实**：`DemangleInterface.swift` 的 public 入口全部 String 基底
（sync / async / `@_spi` transient 三个），泛型 `demangleAsNode<C>` 是 `private`，
`Demangler<C>` 无访问修饰（internal），`getManglingPrefixLength` 只被同模块的
String 扩展调用。改具体类型不破任何公共 API。

### Phase B — store 读路径

**B1 文本借用视图（三种形态并存）**：

```swift
// (i) 闭包式——全平台基线，共享实现
public func withTextUTF8<Result>(_ body: (Span<UInt8>) throws -> Result) rethrows -> Result?

// (ii) 直接返回式——轴 2 门控，@_spi(Internals)，实测 10.15 target 可用
#if hasFeature(Lifetimes)
@_spi(Internals)
@_lifetime(borrow self)
public borrowing func textUTF8Span() -> Span<UInt8>?   // 在 NodeReference 上
#endif

// (iii) 既有 ArraySlice 属性——已发布 API，保留不废，文档引导新代码用 (i)/(ii)
public var textUTF8: ArraySlice<UInt8>?
```

`textMatches` / `isIdentifier(desired:)` / `isSwiftModule` 改走 (i)。
`NodeStore.text(offset:length:)` 物化改为轴 1 双路径（`String(copying:)` +
`unchecked` vs `String(decoding:)`），`text` / `nodeContents` 等所有物化点受益。

**B2 打印 walk 去 ARC**：先把话说透——逐 child ARC 的来源是 `NodeReference.store`
强引用，`Span` 治不了它（`~Escapable` 类型进不了要存进 frame 栈的句柄）。可行方案
是 swift-syntax 的同款模式，且经其最新 main 源码审读确证（对照记录见 0009
Motivation）：其引擎层 `RawSyntaxArenaRef` 就是 `Unmanaged` 包装，注释原话
"passing around in this form doesn't cause any ref-counting traffic"；公共 `Syntax`
值持强 arena 引用、引擎在 `RawSyntax` 层零 ARC 遍历——正是这里「公共
`NodeReference` 保留 retain / walk 内部句柄 unmanaged」的分层：

- 新增 walk 内部句柄（internal，不进公共 API）：

  ```swift
  @usableFromInline
  struct UnretainedNodeReference: DemanglingNode {
      unowned(unsafe) let store: NodeStore
      let rawIndex: UInt32
  }
  ```

- store 打印路径入口 `withExtendedLifetime(store)` 包住整个 walk，句柄的
  `unowned(unsafe)` 拷贝零 ARC；泛型引擎 `DemanglingPrinter<Target, SomeNode>`
  不改，只是 store 路径实例化到新句柄类型。公开的 `NodeReference` 原样保留。
- **安全论证**：walk 期间 store 由入口强引用锚定；句柄的生命周期都在 walk 内
  （printer frame / context / state）。实现时必须审计 rich-target 钩子有没有把
  句柄逃逸给用户代码的路径——现有设计里钩子交付的是 `materializedNode` 产出的
  `Node`（不带句柄），应当没有；若审计发现某处会逃逸，该处物化为带 retain 的
  `NodeReference`，模式不破。
- `Span` 在此的角色：`structuralDigest` / `structurallyEquals` 这类纯 store 内
  紧循环，入口作用域借用三块缓冲直读下标，省掉反复经 class 属性取
  `ContiguousArray` 的访问开销。缓冲借用本身是轴 1 双路径：

  ```swift
  // withSpans 的内部实现
  if #available(macOS 26.0, ...) {
      try body(nodes.span, edges.span, textBytes.span)   // 直取属性
  } else {
      try nodes.withUnsafeBufferPointer { n in ... body(n.span, e.span, t.span) }
  }
  ```

  `NodeStore` 上同样提供轴 2 门控的直接返回式（`@_spi` + `@_lifetime(borrow self)`
  的 `nodesSpan()` / `edgesSpan()` / `textBytesSpan()`），供引擎内部与深度消费方
  （MachOSwiftSection）用非闭包形态组织代码。

**B3 `internText` 去物化**：删掉 `Array(textValue.utf8)`；FNV 哈希与字节比较直接走
`textValue.utf8`（`withContiguousStorageIfAvailable` 快路径拿 span，native String
恒命中；慢路径逐字节迭代），append 进 `textBytes` 用
`append(contentsOf: textValue.utf8)`。intern 命中路径从此零分配。此处无需双路径
（`UnsafeBufferPointer.span` 已回部署，单份实现全平台同形）。

### 分期交付

A、B1、B2、B3 相互独立，可各自成 PR；建议顺序 Phase 0 → A → B3 → B1 → B2（B2
改动面最大、依赖审计，放最后）。可测性 seam 随第一个双路径 PR（A）落地。

## Source Compatibility

- 既有公共 API 零变化；新增 public 仅 `withTextUTF8`。deployment target 不变
  （macOS 10.15 / iOS 13 / watchOS 6 全系保持）。
- **实验特性开关**：Package.swift 对 `Demangling` target 加
  `.enableExperimentalFeature("Lifetimes")`，作用域限本模块，不传染下游。风险与
  对策：attribute 拼写（`@_lifetime`）与 feature 名属实验面，未来编译器可能改名
  ——全部使用点在 `#if hasFeature(Lifetimes)` 内，编译器不认识即整体退化为闭包式，
  构建不破；**未知 experimental feature 名对旧编译器是否报错需在实现期核实**，若
  报错则开关也要包进工具链版本判断。依赖实验特性的 API 全部 `@_spi(Internals)`，
  公共 API 面不随编译器版本漂移。
- **编译器下限（待核实项）**：本机 Swift 6.3.3（Xcode 26.6）实测回部署成立。需在
  Xcode 26.0（Swift 6.2）SDK 上复核回部署标注与 `hasFeature(Lifetimes)` 行为——若
  不成立，实际编译器下限从「tools 6.2 隐含的 Xcode 26.0」抬到实测通过的最低小
  版本，核实结果记入决策日志，抬了就在 README 声明。
- 刻意**不**采用 `@inline(always)`（SE-0496，Swift 6.3 起），避免为标注抬编译器
  下限；见 Future Directions。
- watchOS（32 位 `Int`）：新代码继续遵守 0004 的异构比较纪律；`Span` 下标是
  `Int`，与 `UInt32` 偏移的换算处逐一过 0004 的源码扫描测试。

## Impact（库 / 源码分发）

- **源兼容性**：不变，详上节。
- **ABI 兼容性**：不适用（纯 SPM 源码分发，未开 library evolution）。
- **下游影响**：MachOSwiftSection / RuntimeViewer 无需迁移；`@_spi(Internals)` 面
  新增直接返回式借用视图（`textUTF8Span()`、`nodesSpan()` 等），签名带
  `hasFeature` 门控——SPI 消费方需接受「换编译器可能少这组 API」的实验期约定，
  文档明示。
- **API 演进与废弃策略**：`textUTF8: ArraySlice` 不废弃不警告，仅文档引导；官方
  lifetime 提案落地后直接返回式转 public、属性形式（SE-0507 生态）再作为第三形态
  加入，闭包式永久保留为基线。

## 验收标准

- **正确性**：全量 dyld cache 对齐测试 0 失败；49k 语料 × 3 套打印选项
  store/`Node` 路径逐字节一致；`description` corpus oracle 不变；
  `DefectRegressionTests` 全绿。**双路径对等**：强制旧路径（可测性 seam）重跑上述
  全部，产出与新路径逐字节一致；word 表两种存储在含 word substitution 的语料子集
  上逐符号等价。
- **性能**：Phase 0 三基准任一不得回退超过 2%（两条路径分别对照各自基线）；目标值
  （demangle 吞吐提升幅度、每符号 malloc 下降数）在 Phase 0 量出基线后回填本提案
  并作为 A/B3 的通过门槛；B2 以 Instruments 验证 walk 期间 store 的
  retain/release 计数归零为准。
- **CI 矩阵**：macOS 26 主机跑「新路径全量 + seam 强制旧路径全量」两遍；不存在
  只被旧 OS 覆盖的分支。
- **栈安全**：扫描器无新增递归；B2 不触碰引擎深度计数路径（`maxPrintDepth` 等
  一律不动）；按 `Documentations/StackSafety.md` 的 call-graph 审计流程复查。

## Alternatives Considered

1. **单路径：全部走旧 OS 桥接，不用 macOS 26 特性**（本提案初稿的立场）——
   review 裁决否决（2026-08-07）：新特性要真实采用而不是绕开，双路径的维护成本用
   「共享核心单份 + 可测性 seam + CI 双跑」纪律覆盖。初稿立场保留在此作为决策
   记录。
2. **等 SE-0456 的 `.span` 属性可用（或抬 deployment target 到 macOS 26）**——
   旧 OS 用户被直接抛弃，不可接受；双路径两头都拿到。
3. **`@_lifetime` 做属性形式的借用视图**——实测属性形式即使开 `Lifetimes` 实验
   开关也是编译错误；方法形式可用，故直接返回式以方法交付，属性形式等官方。
4. **全程 `UnsafeBufferPointer`，不引入 `Span`**——性能等价，但丢掉越界 trap 与
   禁逃逸的编译期保证；`Span` 已回部署，安全是白拿的。
5. **`UTF8Span` 做扫描器工作表示**——实测无 `extracting`，不能切片，做载体要么
   反复 `validating`（白付校验）要么全程带偏移手账；正确分工是 `Span<UInt8>` 做
   载体、`UTF8Span(unchecked:)` 只在物化点包一层。
6. **`DemanglingNode` 协议整体借用化**（`~Escapable` 句柄直接进泛型引擎）——依赖
   SE-0503（suppressed associated types，刚 Accepted）与 SE-0516 `Iterable` /
   SE-0519 `Ref`（Swift 6.4）的生态成熟，当前会把引擎逼进更深的实验区；列入
   Future。
7. **word 表不用 `InlineArray`，用可移植定长结构（元组背衬）单份实现**——可行且
   免双特化的代码体积，但与「新特性真实采用」的裁决相悖；若 Phase 0 实测双特化
   的体积/编译时间代价超预期，此项是回退方案，记录在案。
8. **引擎直接以 `(store, UInt32)` 参数化**（不要句柄类型）——收益与 unowned 句柄
   相同，但推翻 0001 确立的「一套泛型引擎、两种表示」结构，侵入面大得多。

## Future Directions（Swift 6.4 工具链解锁后，均不随本批）

- **兄弟提案 0009**（借鉴 swift-syntax arena）：builder 容量预估与跨 store 误用
  防护，与本条正交、可独立先行；其 C 节存档了「文本直达 arena」「惰性 path 层」
  「合并语义参照」三条与本条相邻的记录性结论。

- **SE-0527 `UniqueArray` / `RigidArray`**：builder 三块缓冲与 intern 槽数组换
  `UniqueArray`（`~Copyable`，无 CoW 唯一性检查、无引用计数）——arena 的「正确
  形态」进了 stdlib，这是对 `NodeStoreBuilder` append 热路径最对症的一条。
- **SE-0507 borrow accessors**：属性形式的借用视图（`var textSpan: Span<UInt8>`
  带 `borrow` accessor）作为第三形态加入；本批的直接返回式换掉 `@_lifetime` 拼写。
- **SE-0525 `RawSpan` 安全加载**：0001 Phase 4（平铺序列化 / mmap 符号数据库）的
  读端按这套 API 设计，映射区直读 `CompactNode` 记录不再需要 `unsafeLoad`。
- **SE-0494 `isIdentical(to:)`**：`textMatches` 等比较的身份快路径。
- **SE-0516 `Iterable` / SE-0519 `Ref`**：借用式遍历协议与官方引用类型，替代 B2
  的 `unowned(unsafe)` 手工模式。
- **SE-0496 `@inline(always)`**：编译器下限自然抬到 6.3 后，替换热路径上现在用
  `@inlinable` 近似的标注。
- **SE-0498 `Runtime.demangle`（Swift 6.4）**：测试侧的第二 oracle——与现有
  「对拍 Swift runtime 节点转储」的 corpus oracle 互补，直接对拍官方 demangler 的
  文本输出。

## Decision Log

| 日期 | 决定 | 依据 |
|---|---|---|
| 2026-08-07 | Created as Draft | 起因：`NodeStoreArena.md` 「后续方向」的 Span 项；触发点是实测确认 `Span` 家族核心类型已向后部署（Xcode 26.6 / Swift 6.3.3，`-target x86_64-apple-macos10.15` 逐特性 typecheck），deployment target 无需变动，此前「被 macOS 26 卡住」的判断仅对 `.span` 属性、`UTF8Span`、`InlineArray` 成立。 |
| 2026-08-07 | 改为双路径设计（Rev 2） | review 裁决：被 OS / 编译器卡住的特性不绕开，全部采用、写两套。补充实测三项支撑可行性：`UTF8Span(unchecked:)` 存在（免二次校验物化成立，且 `String` UTF-8 恒合法、两条入口都健全）；`@_lifetime` **方法**形式加 `Lifetimes` 实验开关在 10.15 target 编译通过（含跨调用存活消费方），属性形式仍编译错误；`UTF8Span` 无 `extracting`（工作表示必须是 `Span<UInt8>`）。据此确立「轴 1 OS 门控 / 轴 2 编译器门控 + 四条纪律（共享核心单份、逐字节一致、可测性 seam、实验特性圈 SPI）」。 |
| 2026-08-07 | B2 补原厂确证；swift-syntax 借鉴项拆为独立提案 0009 | 对 swift-syntax 最新 main 的 arena 实现做了对照审读：B2 的 unmanaged 句柄分层与其 `RawSyntaxArenaRef` 模式一致（引用已补进 B2）；审读发现的可实施项（builder 容量预估、跨 store 误用防护）按 review 指示独立成案 0009，本条范围不变。 |
