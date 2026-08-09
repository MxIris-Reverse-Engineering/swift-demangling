# 0008 - Span 借用视图：扫描器 UTF-8 字节化与 store 读路径去 ARC（双路径）

- **Proposal**: 0008
- **Author**: Mx-Iris
- **Status**: Implemented
- **Date**: 2026-08-07
- **Last Updated**: 2026-08-07
- **Branch**: `feature/node-store`
- **Related**: `Evolutions/0001-node-store-arena.md`（arena 本体；本条兑现
  `Documentations/NodeStoreArena.md` 「后续方向」中的 **`Span` 借用视图**一项）；
  `Documentations/Concepts/ArenaStorage.md`（概念背景：class 节点的成本都花在哪）
- **配套实现说明**: `Documentations/SpanBorrowedViews.md`（面向维护者：双轴门控地图、
  维护契约、验证工具箱；实际落地与本提案不一致之处集中在其「与提案的差异」一节）

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
| 2026-08-07 | Phase A 落地（扫描器字节化，双入口/双物化/双词表） | 与设计的三处偏差，均为实现期发现：① **`prevalidatedCopying` 物化补 ASCII 门**——提案的健全性论证只对整段输入成立，字节**子区间**可能切开非 ASCII scalar，`UTF8Span(unchecked:)` 会伪造非法 `String`；改为入口用 `UTF8Span.isKnownASCII`（O(1)）选策略：known-ASCII 走免校验、其余走带校验解码，健全性无条件成立且零扫描成本。② **扫描器核心依赖 `Lifetimes` 特性**（见前一条核实记录），Package.swift 对 `Demangling` 无条件开启。③ **顺手修掉长度前缀的 `Int(UInt64)` 转换陷阱**——原代码 `Int(numChars)` 对恶意长度（含溢出回绕）在转换处 trap，新扫描器提供 `UInt64` 入参的 `readRange`/`readScalars`，在 `UInt64` 域内先比界再转换，超界走正常 parse 失败。另：词表区间化后 `demangleIdentifier` 以字节缓冲组装、结尾单次物化；word 边界扫描直接在输入字节上做（与 C++ 同构）；死代码删除（`readUntil(string:/set:)`、`skipUntil(set:/string:)`、`skipWhile`、`match(where:)` 均无调用者，`readUntil(set:)` 的位掩码优化随之无对象）；`opCharTable` 提为文件级常量。**验证**：全库 483 测试全绿；全量 dyld cache 对齐 4,573,306 符号 0 失败 0 mismatch（现代路径）；新增 `DualPathParityTests` 七组双路径逐字节对等（词表重负载/punycode/操作符/后缀/Swift3/私有名/非法输入错误偏移含非 ASCII）。 |
| 2026-08-07 | Created as Draft | 起因：`NodeStoreArena.md` 「后续方向」的 Span 项；触发点是实测确认 `Span` 家族核心类型已向后部署（Xcode 26.6 / Swift 6.3.3，`-target x86_64-apple-macos10.15` 逐特性 typecheck），deployment target 无需变动，此前「被 macOS 26 卡住」的判断仅对 `.span` 属性、`UTF8Span`、`InlineArray` 成立。 |
| 2026-08-07 | 改为双路径设计（Rev 2） | review 裁决：被 OS / 编译器卡住的特性不绕开，全部采用、写两套。补充实测三项支撑可行性：`UTF8Span(unchecked:)` 存在（免二次校验物化成立，且 `String` UTF-8 恒合法、两条入口都健全）；`@_lifetime` **方法**形式加 `Lifetimes` 实验开关在 10.15 target 编译通过（含跨调用存活消费方），属性形式仍编译错误；`UTF8Span` 无 `extracting`（工作表示必须是 `Span<UInt8>`）。据此确立「轴 1 OS 门控 / 轴 2 编译器门控 + 四条纪律（共享核心单份、逐字节一致、可测性 seam、实验特性圈 SPI）」。 |
| 2026-08-07 | B2 补原厂确证；swift-syntax 借鉴项拆为独立提案 0009 | 对 swift-syntax 最新 main 的 arena 实现做了对照审读：B2 的 unmanaged 句柄分层与其 `RawSyntaxArenaRef` 模式一致（引用已补进 B2）；审读发现的可实施项（builder 容量预估、跨 store 误用防护）按 review 指示独立成案 0009，本条范围不变。 |
| 2026-08-07 | Accepted → In Progress，Branch `feature/node-store` | Rev 2 通过 review（用户裁决）。随即开工，Phase 顺序按提案：0 → A → B3 → B1 → B2。 |
| 2026-08-07 | Phase 0 基线落定（release，arm64 本机，dyld cache 语料远大于历史「49k/234k」——打印语料 SwiftUI+SwiftUICore+Foundation+Combine 去重后 439,533 符号，构建语料另加 AppKit+UIKitCore+AttributeGraph 计 454,094 符号；三遍取最优，malloc 计数走 `malloc_logger` 钩子取末遍）：① 纯 demangle（transient 树）6.868s ≈ **63,995 symbols/s**，**85.3 mallocs/symbol**；② store 端到端构建 9.602s ≈ 47,290 symbols/s，117.3 mallocs/symbol（uniqueNodes 1,267,380 / storageBytes 17.9 MB）；③ store 打印 default 7.026s（62,557/s，21.5 mallocs/symbol）、simplified 5.019s（87,578/s，14.6）、sugared 7.200s（61,045/s，21.4）。基准套件 `SpanBorrowedViewsBenchmarks`（`DEMANGLING_BENCHMARK=1` + release 下手动运行）。**回填 A/B3 通过门槛**：任何基准不得劣于对应基线 2%；Phase A 需在 ① 上呈现吞吐提升与 mallocs/symbol 下降（词表/读取物化去堆化的直接后果）；B3 需在 ② 上呈现 mallocs/symbol 下降（`internText` 命中路径去 `Array` 物化）。 |
| 2026-08-07 | Phase A 基准（现代路径，与 Phase 0 同机同法） | ①纯 demangle 6.868s → **5.648s（+21.6%，77,817 symbols/s）**；②store 构建 9.602s → 8.502s（+13%）；③打印三组均在 ±2% 噪声内（default 7.026→7.094 −1.0%，simplified +4.6%，sugared +1.6%）——通过「不劣于 2%」门槛。**mallocs/symbol 持平**（85.3→85.8 / 117.3→117.8）：分配主项是节点构造（~85/符号 ≈ 节点数），扫描器省下的 word 表 / 读取物化 String 只占其中个位数——「吞吐提升」达成、「malloc 下降」这一半预期在 ① 上未成立，B3 的下降主张移到 ② 验证。**旧路径基准首轮作废**：跑批时并行启动了一次编译，打印组（不经扫描器）都慢了 50%，判定为 CPU 竞争污染，验收阶段在空载机上重测。 |
| 2026-08-07 | B3 落地（`internText` 去物化） | `Array(textValue.utf8)` 删除：FNV 哈希与字节比较走 `String.UTF8View.withContiguousStorageIfAvailable` 快路径（native 大小字符串均命中，bridged 字符串退化为逐字节迭代），追加走 `append(contentsOf: textValue.utf8)`。命中路径零分配。单份实现、无双路径（`UnsafeBufferPointer` 直接可用）。 |
| 2026-08-07 | B1+B2 落地，两处与提案的偏差 | ① **直接返回式借用视图需要双门控**（`#if hasFeature(Lifetimes)` **加** `@available(macOS 26 系)`），并非提案预期的仅编译器门控：实现要用的 `.span` 属性本身要 macOS 26 运行时；且 SIL 层生命周期诊断（`-typecheck` 不跑，提案实测由此漏判）拒绝任何从 class 存储属性逃逸的 span——可行实现是「本地 CoW 拷贝锚定 + `_overrideLifetime(_:borrowing:)` 重绑到 self」，健全性：本地拷贝与不可变存储属性共享同一 buffer，`borrow self` 期间恒存活。② `nodesSpan()`/`edgesSpan()` 收为 internal 而非 `@_spi`：`CompactNode` 非公共类型，public SPI 签名无法引用它；`textBytesSpan()` 与 `NodeReference.textUTF8Span()` 照案交付为 `@_spi(Internals)`。其余照案：闭包式 `withTextUTF8` 全平台基线；`textMatches`/`isIdentifier`/`isSwiftModule` 改走 store 共享核心；`NodeStore.text` 物化走轴 1 双路径（intern 自整段 `String.utf8`，unchecked 健全）；打印 walk 以 `UnretainedNodeReference`（`unowned(unsafe)` store + rawIndex，swift-syntax `RawSyntaxArenaRef` 同款）实例化引擎，入口 `withExtendedLifetime` / 强捕获锚定，rich-target 钩子审计确认只交付 `materializedNode` 产物、句柄零逃逸；`structuralDigest` 与两个 `structurallyEquals` 改为 `withSpans` 借用三缓冲 + 裸索引行走（每子节点一对 retain/release 归零，memo 语义逐行保持）。共享逻辑防漂移：子索引解析、contents 恢复、文本比较各收敛到 `NodeStore` 单点（数组版与 span 版子索引解析两个 switch 要求 lockstep，注释互指）。 |
| 2026-08-07 | B2 验收工具落地，句柄随即返工：`unowned(unsafe)` → `Unmanaged` + `_withUnsafeGuaranteedRef` | 建 interpose 验证工具替代手动 Instruments（`Scripts/RetainCounter/retain-counter.c` 插桩 `swift_retain`/`swift_release` 只计 store 对象；`DEMANGLING_RETAIN_HARNESS=1` 门控的 `RetainCountVerification` 可执行 target 在同一 store 上对比两个引擎）。**首测抓到问题**：`unowned(unsafe)` 存储的句柄，每次经属性调用 store 方法仍被编译器补一对 retain/release——实测 ~99 对/walk，只比保留式引擎（222.66 对/walk）少一半，并未归零；swift-syntax 用 `Unmanaged` + `_withUnsafeGuaranteedRef` 正是为此。返工后实测 **1.00 对/walk**（恰为入口 `reference(at:)` 那一次；保留式引擎 220.54 对/walk）。验收标准里的「Instruments 验证归零」由此改为可重复的确定性计数，工具随库保留。 |
| 2026-08-07 | **验收通过，状态置 Implemented** | ①**正确性**：全量 dyld cache 对齐 4,573,306 符号，现代路径与 seam 强制旧路径各跑一遍，均 0 demangle 失败 / 0 节点树 mismatch / 0 remangle mismatch，`DefectRegressionTests`（含 0004 源码扫描）全绿；打印对等清一色（新增 opt-in `StorePrintParitySweep`，`DEMANGLING_PRINT_PARITY=1`）：439,522 符号 × 3 组选项，store/`Node` 路径双路径均 0 mismatch。CI 双跑期间抓到并修复：`DualPathParityTests` 原以 precondition 断言 seam 干净，在整进程强制旧路径的双跑模式下必然 trap——改为快照-恢复（该模式下退化为 legacy vs legacy 的平凡对比，无害）。②**性能**（终态 vs Phase 0 基线，release 空载，best-of-3）：纯 demangle 5.643s（**+21.7%**，77,893 symbols/s；旧路径 5.878s 也快于基线 +16.8%）；store 构建 8.855s（+8.4%），mallocs/symbol 117.3→**110.4**（B3 门槛达成；旧路径 8.228s，与现代路径差异在跑次噪声内）；store 打印 default 7.026→**3.441s（+104%）**、simplified 5.019→2.779s（+80.6%）、sugared 7.200→3.529s（+104%），两条路径打印数字一致（打印不经入口轴，符合预期）。无任何基准回退（红线 2%）。③**B2 归零**：interpose 计数 1.00 对/walk（入口一次）vs 保留式 220.54 对/walk。④**栈安全**：新扫描器与三个改写的 store 行走全部迭代式（显式栈/循环），引擎深度计数路径未触碰，新文件自递归审计无发现。 |
| 2026-08-07 | 实现期核实三项（Swift 6.3.3 / Xcode 26.6 逐项 typecheck，`-target arm64-apple-macos10.15`） | ① Source Compatibility 遗留的「未知 experimental feature 名是否报错」：**不报错**，`-enable-experimental-feature` 收到未知名称时静默忽略（以伪造名实测），风险从「构建断裂」降级为「特性未开导致的正常编译错误」。② 新发现：**扫描器核心本身依赖 `Lifetimes` 特性**——不开该特性时，struct 存储 `Span` 属性直接是编译错误（"initializer cannot return a ~Escapable result"），因此「编译器不认识 feature 即退化为闭包式」只覆盖轴 2 的直接返回式 API；`Demangling` 模块整体要求编译器具备 `Lifetimes`（tools 6.2 起的 Apple 工具链均满足，Swift 6.2 原生行为仍待按提案在 Xcode 26.0 复核）。③ 轴 1 全部拼写在 10.15 target 下 typecheck 通过：`String.utf8Span`、`UTF8Span(unchecked:)`、`String(copying:)`、`Span.extracting(_:)`、`InlineArray<26, Range<Int>>(repeating:)`、`.span` 属性与 `withUnsafeBufferPointer { $0.span }` 桥接；含「~Escapable 扫描器持 `Span` 字段 + 泛型 `Demangler<Words>` + mutating 方法 + `withUTF8` 闭包内构造 + `Result` 桥回 typed throws」的组合探测。 |
| 2026-08-09 | PR #7 review 第 0 步落地（F3/F4，同批 commit） | **F3**：测试 target 一直缺 `Lifetimes` 开关，`#if hasFeature(Lifetimes)` 的测试（`directReturnSpanAgreesWithClosureForm`）从未进过测试二进制而套件照绿——本提案核实记录只声明了「`Demangling` target 无条件开启」，测试 target 从不在视野内。testTarget 补开关 + 元测试守卫（先确认红再修复转绿），该测试首次真实执行并通过。**F4**：`StorePrintParitySweep` 等语料验收的 `try?` 在比较前吞掉失败符号，「439,522 symbols, 0 mismatches」实际含义是「两边都成功的那些无差异」。改造为：单边失败即 parity mismatch；双边失败按 stdlib demangler（默认 oracle 同一裁判）分类，stdlib 也拒绝才算一致拒绝，stdlib 能解则断言失败。重跑揭示语料实为 439,533 个符号，其中 **11 个双路径皆败且 stdlib 同拒**（此前被静默吞掉），其余 439,522 双运行时路径 0 mismatch、0 单边失败。详见 `Documentations/ReviewFindingsPR7.md` 移交清单第 0 步。 |
| 2026-08-09 | PR #7 review F2 修复：0xFF 对齐填充跳过在字节化中被静默杀死（功能回归） | `ec3769a` 把扫描器换成逐字节 Latin-1 交出后，`demangleOperator` 的 `scalar.value == 0xFF` 死代码化——String 输入的 U+00FF 填充以 UTF-8 双字节 `C3 BF` 到达，循环永不执行；452 万符号语料全 ASCII，结构上覆盖不到（A9 自 `8d0b396` 合并起就没有针对性测试）。复修在字节域跳过 raw `FF` 与 `C3 BF` 两种拼写，`AppleAlignmentTests.alignmentPaddingBeforeOperatorIsSkipped` 修复前红、修复后绿并永久入库；横向排查 group-a 其余 7 项全部为 ASCII 域或不经扫描器（全 Demangler 唯一的非 ASCII scalar 比较即此处），无同类失效。防线盲区自答：该测试只覆盖 String 入口的 `C3 BF` 形态与本机运行时路径——raw `FF` 形态要等字节入口（0012 若立项）才可达，由注释与本行留档。 |
