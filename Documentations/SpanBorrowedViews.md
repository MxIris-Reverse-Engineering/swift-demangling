# Span 借用视图：字节扫描器与 store 读路径去 ARC

日期：2026-08-07

提案原文：[Evolutions/0008-span-borrowed-views.md](../Evolutions/0008-span-borrowed-views.md)
（决策记录，保持历史原貌；本文是面向维护者的实现说明，实际落地与提案不一致的地方
集中写在「与提案的差异」一节）。概念背景：[Concepts/ArenaStorage.md](Concepts/ArenaStorage.md)
（store 三块平铺缓冲的由来）。词条速查见 [Glossary.md](Glossary.md) 的
「双路径」「seam」两条。

## 一句话结论

mangled 符号是纯 ASCII，把扫描器从 `String.UnicodeScalarView` 换成借用的 UTF-8 字节
`Span`，再把 store 读路径上「每访问一个子节点付一对 store retain/release」和「每次
物化文本重做一遍 UTF-8 校验」去掉之后：纯 demangle 吞吐 **+21.7%**、store 构建
**+8.4%**（每符号 malloc 数 117.3 → 110.4）、store 打印吞吐**翻倍**（+80% ~ +104%）；
全量 dyld cache 4,573,306 符号新旧两条运行时路径各跑一遍，0 失败 0 差异，公共 API
无破坏。代价是本文要解释的东西：**代码里从此有两条按 OS 版本分流的路径和一批
生命周期标注**，它们各自在哪、为什么在那、动的时候要守什么规矩。

## 复杂度的地图：两条门控轴

这批优化用的语言特性分两类，各有一个「不可用」的世界，所以代码里有两条门控轴。
**先记住这张地图，后面每一节都在这张图上**：

| 轴 | 门控条件 | 卡住的东西 | 不可用时走什么 |
|---|---|---|---|
| 轴 1：OS 运行时版本 | `if #available(macOS 26.0, iOS 26.0, …, *)` | `.span` 属性、`UTF8Span` 家族、`InlineArray`（都要 macOS 26 系运行时） | 旧路径：`withUTF8` 闭包借用、带校验的 `String(decoding:)`、`ContiguousArray` 词表 |
| 轴 2：编译器能力 | `#if hasFeature(Lifetimes)` | `@_lifetime` 直接返回式借用 API | 该 API 面整体消失，闭包式是永远存在的基线 |

四条纪律（0008 review 裁决确立，**改代码时必须维持**）：

1. **共享核心单份**：分叉只允许出现在**入口、物化点、存储选型**三处。扫描逻辑、
   打印引擎、intern 逻辑永远一份——防两套语义漂移。
2. **两套产出逐字节一致**：`DualPathParityTests` 管单点，`StorePrintParitySweep` 管
   corpus 规模，全量对齐测试双跑管全部。
3. **可测性 seam**：`DemanglingRuntimePath.forcesLegacyPath`（`@_spi(Internals)`，
   env `DEMANGLING_FORCE_LEGACY_PATH=1` 整进程生效）强制走旧路径，让一台 macOS 26
   机器把两条路径都测全。**不存在只被旧 OS 覆盖的分支**——新增 `#available` 分流时
   先想清楚 seam 能不能强制到它。
   - **seam 的两条使用规矩（PR #7 review F11/F12，2026-08-09）**：
     ① seam 只能在**进程启动时**经 env 设定；测试**绝不**在运行中翻它——它是进程级
     状态，翻一下就把所有并行套件拽到旧路径（`DefectRegressionTests` 有扫描测试钉住
     「测试 target 无赋值点」）。要单测旧腿，直接调 internal 的
     `demangleAsNodeOnLegacyRuntimePath`。task-local 化被否：seam 在
     `StackSafeExecutor` 闭包内被读取，pthread hop 不传播 task-local。
     ② **`#available(macOS 26)` 分流点清单**（新增分流时在此登记并确认 seam 可达）：
     `DemangleInterface.demangleAsNodeFromMangledText`（入口，读 seam ✓）、
     `TextMaterializationStrategy.materialize`（策略仅在入口 seam 判定后被选中，
     其内部 `#available` 不可达失配 ✓）、`NodeStore.BufferView.text`（store 侧物化，
     经 store 创建时的 seam 快照 + 全表 ASCII 闸门 ✓——此前只看 `#available`，
     双跑在这条分支上跑的是同一条路）、`NodeReference.textUTF8Span()` /
     `NodeStore.textBytesSpan()` 等直接返回式借用视图（双门控 `hasFeature` +
     `#available`，无物化语义分叉，seam 无需覆盖）。
4. **实验特性圈在 SPI 里**：依赖 `hasFeature(Lifetimes)` 的 API 一律
   `@_spi(Internals)`，公共 API 面不随编译器版本变化。

轴 1 的三个分叉点全部在一个函数里（`DemangleInterface.swift` 的
`demangleAsNodeFromMangledText`），选定后固化成具体类型或策略值，之后的热路径无分支：

| 分叉点 | 现代路径 | 旧路径 |
|---|---|---|
| 输入借用 | `String.utf8Span`（免拷贝、免闭包） | `withUTF8`（闭包内借用，bridged 字符串可能拷贝一次） |
| 文本物化 | known-ASCII 时 `String(copying: UTF8Span(unchecked:))`（免二次校验） | `String(decoding:)`（带校验） |
| 词表存储 | `InlineWordRanges`（`InlineArray<26, Range<Int>>`，栈上零堆分配） | `ArrayWordRanges`（`ContiguousArray`，惰性 reserveCapacity） |

## 关键设计

### 扫描器：字节进、Latin-1 scalar 出

`ScalarScanner`（`Demangler.swift` 文件私有）从泛型 `Collection<UnicodeScalar>` 换成
具体类型：`Span<UInt8>` + `var offset: Int`。换掉的是三样开销：非随机访问的
`index(after:)` 步进、单独维护的 `consumed` 计数器（offset 即位置）、逐 scalar 回退
的 `backtrack`（现在是整数减法）。

**改动能这么小的关键**：扫描器把每个字节按 Latin-1 包成 `UnicodeScalar` 交出去
（`UnicodeScalar(byte)`），于是 `Demangler` 四千行解析逻辑里所有
`case "A":`、`c.isDigit`、`c.value - UnicodeScalar("a").value` 一行没动。对 ASCII
输入这与旧行为严格等价；对含非 ASCII 的**非法**输入，旧实现按整 scalar 走、新实现按
字节走——后者才是 C++ 上游的语义，corpus oracle 不受影响，但
`DemanglingError` 携带的错误偏移从 scalar 计数变成了**字节偏移**。

`Demangler` 因为持有扫描器（内含 `Span`）成为 `~Escapable`：一次 demangle 全程活在
入口开出的借用作用域里，逃出去的只有 `Node` 树。这是编译期保证，不是约定。

顺手修掉的一个老陷阱：识别符长度前缀原来写 `Int(numChars)`（`numChars: UInt64`），
恶意的超大或溢出回绕长度会在**转换处 trap**。新扫描器提供 `UInt64` 入参的
`readRange` / `readScalars`，在 `UInt64` 域内先比界再转换，超界走正常 parse 失败
（0004 异构比较纪律的延伸）。

### 物化策略与 ASCII 门——提案论证里的一个洞

提案的免校验论证是「`String` 的 UTF-8 存储恒为合法，所以 `UTF8Span(unchecked:)`
免掉的校验是纯赚」。**这只对整段输入成立**：物化发生在字节**子区间**上，而合法
UTF-8 的子区间可以把一个多字节 scalar 从中间切开——对这种切片做 `unchecked` 物化会
伪造出非法 `String`，是健全性 bug 而不是性能选择。

补法零成本：`String.utf8Span.isKnownASCII` 是 O(1) 的标志位。入口据此选策略——
known-ASCII（真实符号的 100%）走 `prevalidatedCopying`，其余（以及整条旧路径）走
`decoding`。ASCII 输入的任何子区间都是完整 UTF-8，健全性无条件成立。

`demangleIdentifier` 的组装缓冲（词替换 + 字面段 + punycode 解码结果拼起来的
`[UInt8]`）也走同一策略物化，健全性论证略有不同：每个成分要么是 ASCII 输入区间、
要么是某个合法 `String` 的完整 UTF-8（punycode 输出），**合法 UTF-8 的拼接仍合法**，
且该缓冲从不被切片。

**维护契约**：新增任何物化点，必须经 `TextMaterializationStrategy` 走，禁止在别处
直接写 `String(copying: UTF8Span(unchecked:))`——ASCII 门在入口，绕开策略就绕开了门。

### 词表：存区间，不存字符串

词替换表从 `[String]`（每个词物化一个小字符串）改为存 `Range<Int>`（指向输入区间，
被 `a`–`z` 回引用到才拷贝字节）——C++ 上游的做法。词边界扫描直接在输入字节上做，
「上一个字符」就是 `bytes[currentOffset - 1]`（词字节在输入里连续）。

存储选型是轴 1 的第三个分叉：`Demangler` 泛型于 `Words: WordRangeStorage`，入口按
`#available` 实例化 `Demangler<InlineWordRanges>` 或 `Demangler<ArrayWordRanges>`。
**代价明示**：demangler 主体因此产生两份特化，这是「写两套」在存储上的实付成本
（提案 Alternative 7 记录了元组背衬的单份回退方案，如果将来体积成为问题）。

`InlineWordRanges.append` 带 `precondition(count < maxNumWords)`——上限守卫在
`demangleIdentifier` 的调用端（词只在 `words.count < maxNumWords` 时开始记录）。
**改动词扫描逻辑时不要弄丢那个守卫**，丢了不是静默截断而是 trap。

### `UnretainedNodeReference`：为什么 `unowned(unsafe)` 不够

store 打印 walk 的逐 child ARC 来自 `NodeReference.ChildrenView.subscript`：每访问
一个子节点构造一个 `NodeReference`，其 `store` 是强引用，一对 retain/release。walk
期间 store 由入口锚定、必然存活，这些 ARC 全是白付的。

解法是 swift-syntax `RawSyntaxArenaRef` 的分层：公共 `NodeReference` 保留强引用，
引擎内部用 16 字节的 `UnretainedNodeReference`（store 指针 + `rawIndex`）行走。
`NodeReference.print`（sync/async 都是具体类型上的 overload，遮蔽协议扩展的泛型
版本）在 `withExtendedLifetime(store)` / 闭包强捕获的锚定下把引擎实例化到句柄类型。

**这里有一个只有量了才知道的坑**：第一版句柄用 `unowned(unsafe) let store`，
interpose 计数实测 **99 对 retain/release / walk**——编译器在每次「经该属性调用
store 方法」时补一对 retain/release 保活，`unowned(unsafe)` 只免掉了存储本身的
ARC，没免掉使用点的。真正编译成裸指针访问的拼写是
`Unmanaged<NodeStore>` + `_withUnsafeGuaranteedRef`（句柄的 `withStore` 是唯一
访问路径）。返工后实测 **1.00 对 / walk**——恰好是入口 `reference(at:)` 那一次；
对照组（保留式引擎跑同一 store）是 220.54 对 / walk。

**安全契约**（写在类型 doc 注释里，这里再强调一遍）：句柄 sound 的前提是 walk 之外
有人强持 store——每个铸造句柄的入口都要锚定整个 walk；句柄**永不逃逸** walk——
rich-target 钩子和 `NodePrintContext` 交付的都是 `materializedNode` 产物（独立
`Node` 树），不是句柄。新增会把节点交给用户代码的钩子时，必须重新做这条审计。

### `withSpans` 与三个行走：本地拷贝锚定 + `_overrideLifetime`

`structuralDigest`、两个 `structurallyEquals` 这类纯 store 内紧循环改成：入口
`NodeStore.withSpans` 一次借出三块缓冲（nodes / edges / textBytes），循环里持
`rawIndex` 直读下标——既消掉每子节点的 `NodeReference` 构造，也把「每次访问经
class 属性取 `ContiguousArray`」的重复加载提出循环。memo 语义逐行保持（这些行走
的按图计价是 0005–0007 用真实退化换来的，动它们前先读那三篇提案）。

两个语言层的教训都在这里：

- **span 不能直接从 class 属性逃出语句**。`nodes.span` 的生命周期被限定在属性访问
  表达式内，连传给同一行的 `body` 都不行。可行拼写是先做**本地 CoW 拷贝**
  （`let nodesBuffer = nodes`，一次 retain、零元素拷贝）再取 `.span`——本地变量
  把 buffer 锚定到作用域结束。
- **直接返回式**（`textBytesSpan()` 等 `@_lifetime(borrow self)` 方法）还要再加一步
  `_overrideLifetime(span, borrowing: self)` 把依赖从本地拷贝改绑到 `self`。健全性：
  本地拷贝与不可变存储属性共享同一 buffer，`borrow self` 期间恒存活。
  `_overrideLifetime` 是带下划线的 stdlib 原语，**只允许出现在现有的
  `#if hasFeature(Lifetimes)` 圈内**；换工具链先跑 probe（见下）。

### store 侧的免校验物化

`NodeStore.text(offset:length:)` 同样走轴 1 双路径。这里的健全性论证比扫描器侧
干净：`textBytes` 全部 intern 自**整段** `String.utf8`，节点 payload 里的
(offset, length) 只会指向完整的一段存储文本，不存在切开 scalar 的可能。`text` /
`nodeContents` / `materializeNode` 所有物化点自动受益。

`internText`（B3）与双路径无关：FNV 哈希与字节比较走
`withContiguousStorageIfAvailable` 快路径（native 大小字符串都命中），命中路径
零分配——store 构建的 mallocs/symbol 从 117.3 降到 110.4 就是它。

## 与提案的差异

按「提案保持原貌、差异写进实现说明」的规矩，全部列在这里（细节在提案 Decision Log
对应条目里）：

1. **物化策略补了 ASCII 门**（健全性，见上节）。提案原文的论证对子区间不成立。
2. **`Lifetimes` 是模块级编译器下限，不只是 SPI 面的事**：struct 存 `Span` 属性
   （扫描器核心）没有该特性就是编译错误，Package.swift 对 `Demangling` 无条件开启。
   「编译器不认识 feature 名即退化为闭包式」只覆盖轴 2 API；好消息是实测未知
   feature 名会被静默忽略，不会炸构建——坏消息是炸的会是后面的 `Span` 属性。
3. **直接返回式借用视图是双门控**（`hasFeature` **加** `@available` macOS 26），
   不是提案预期的仅编译器门控：实现要用的 `.span` 属性本身要 macOS 26 运行时。
   提案的「10.15 target 实测可用」是 `-typecheck` 级结论——**生命周期诊断跑在 SIL
   层，`-typecheck` 不触发**，这是整个实施期最值得记住的探测方法论教训（本文所有
   语言特性结论最终都用 `swiftc -c` 复验过）。
4. **`nodesSpan()` / `edgesSpan()` 收为 internal**：`CompactNode` 非公共类型，
   public SPI 签名无法引用它。`textBytesSpan()` 与 `textUTF8Span()` 照案 SPI 交付。
5. **句柄从 `unowned(unsafe)` 返工为 `Unmanaged`**（见上节，验收工具抓出来的）。
6. **B2 验收从手动 Instruments 改为确定性 interpose 计数**（工具随库保留，见下节）。
7. **「malloc 下降」预期修正**：纯 demangle 基准上 mallocs/symbol 持平（85.3→85.8）
   ——分配主项是节点构造（约 85/符号 ≈ 节点数），扫描器省下的字符串物化只占个位
   数。下降主张兑现在 store 构建基准上（B3，117.3→110.4）。
8. **`readUntil(set:)` 的位掩码优化没有对象**：它和 `readUntil(string:)`、
   `skipUntil(set:/string:)`、`skipWhile`、`match(where:)` 一样是无调用者的死代码，
   直接删除。

## 验证工具箱

这里只列 0008 专属的复跑命令与验收数字；各计量工具本身的原理、使用契约与判读的坑
（malloc 计数、footprint 采样、interpose 计数、基准纪律）集中在
[MeasurementToolbox.md](MeasurementToolbox.md)。

全部可重复，验收数字（2026-08-07，arm64 本机，release）随各命令附注：

```bash
# 基准（三项 + malloc 计数；对照数字在 0008 Decision Log 的 Phase 0 / 验收两条）
DEMANGLING_BENCHMARK=1 swift test -c release --filter SpanBorrowedViewsBenchmarks

# corpus 规模的 store/Node 打印逐字节对比（439,522 符号 × 3 组选项，0 mismatch）
DEMANGLING_PRINT_PARITY=1 swift test -c release --filter StorePrintParitySweep

# 双路径：以上任意命令与全量测试套件，加环境变量整进程强制旧路径重跑一遍
DEMANGLING_FORCE_LEGACY_PATH=1 <同上>

# B2 归零验证（interpose swift_retain/swift_release，只计被观察的 store 对象；
# 实测 unretained 引擎 1.00 对/walk vs 保留式引擎 220.54 对/walk）
clang -dynamiclib -undefined dynamic_lookup Scripts/RetainCounter/retain-counter.c -o /tmp/libretaincounter.dylib
DEMANGLING_RETAIN_HARNESS=1 swift build -c release --product RetainCountVerification
DYLD_INSERT_LIBRARIES=/tmp/libretaincounter.dylib .build/release/RetainCountVerification
```

语言特性探测的方法论：结论必须来自 `swiftc -c`（跑 SIL 诊断），`-typecheck` 只能
证伪不能证实（差异点见上节第 3 条）。

## 遗留事项

- 提案 Source Compatibility 的「在 Xcode 26.0（Swift 6.2）SDK 上复核回部署标注与
  `hasFeature(Lifetimes)` 行为」仍未做（实施机只有 Swift 6.3.3）。若复核不过，
  实际编译器下限要抬并在 README 声明。
- `_overrideLifetime` / `_withUnsafeGuaranteedRef` 是下划线 stdlib 原语，官方
  lifetime 提案或 SE-0507（borrow accessors）落地后应替换拼写——落点已在 0008
  Future Directions 列明。
