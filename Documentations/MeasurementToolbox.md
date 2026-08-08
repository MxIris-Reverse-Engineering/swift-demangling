# 测量工具箱：性能与内存结论是怎么量出来的

日期：2026-08-08

本库每一条性能/内存主张（「打印吞吐翻倍」「realloc 拷贝归零」「walk 期间恰 1 对
retain/release」）背后都有一件可复跑的进程内计量工具和一次真实语料基准。工具散落在
`Sources/DemanglingTestingSupport*`、`Scripts/` 和各基准套件里，用法与契约此前只存在于
提案决策日志——本文把它们收拢成一篇：**每件工具的原理、使用契约、以及那条「量错了
还不自知」的坑**。坑没有一条是假设的，全部真实踩过，出处随文标注。

0008 专属的复跑命令与验收数字见 [SpanBorrowedViews.md](SpanBorrowedViews.md)
「验证工具箱」一节；本文讲工具本身，不重复那些数字。

## 一句话结论

性能与内存的结论必须来自**决定论、可复跑**的计量——手工 Instruments 采样不进验收；
而比「量多少」更容易错的是「量什么」：分配**事件数**看不见拷贝成本、同进程第二遍起
**footprint 量不到尖峰**、并行干活会**污染计时**。本文六节工具各配至少一条这样的坑。

## 为什么自建工具，而不是 Instruments

三个理由，按重要程度排：

1. **可复跑**：验收数字要进提案决策日志、要能被将来的回归对比引用，「我当时在
   Instruments 里看到大概是……」做不到这一点。
2. **决定论**：计数器（分配事件、retain/release 对数）跑一百遍是同一个数；采样型
   profiler 每次都不同。
3. **抓得住手工采样抓不住的东西**：0008 B2 的验收本来打算用 Instruments 手工确认
   「walk 零 retain/release」，改成 interpose 计数 harness 后立刻量出 `unowned(unsafe)`
   方案实际是 **99 对/walk**（编译器给每次方法调用插了保护性 retain/release）——
   方案返工为 `Unmanaged._withUnsafeGuaranteedRef` 后归到 1.00 对/walk。手工采样看
   火焰图很可能把这 99 对当噪声放过去。

## 工具一：`MallocCounter` —— 分配事件计数

`Sources/DemanglingTestingSupportC/CMallocCounter.c` +
`Sources/DemanglingTestingSupport/MallocCounter.swift`。

- **原理**：把函数指针挂上 libmalloc 的 `malloc_logger` 钩子——进程里每一次分配
  事件都会回调它。这个符号由 libSystem 导出且稳定（MallocStackLogging 工具链依赖
  它），但声明它的头不在公开 SDK 里，所以 C 文件里自带声明。
- **计什么**：毛分配事件（`type & 2`：malloc / calloc / valloc / realloc 的分配半边）。
  释放事件**故意不计**——度量是「毛分配压力」，不是净存活。
- **使用契约**：进程级独占，窗口不可重叠；量的是全进程，测量窗口内不能有无关工作。
- **报告形式**：恒以 `mallocs/symbol` 之类的比值呈现并带上符号量（语料随机器变，
  绝对数没有跨机可比性）。

**坑（0009 踩）——事件数看不见拷贝成本**：store 构建一遍约 5,000 万次分配事件，
缓冲增长的整缓冲拷贝只占其中 ~40 次，总数上完全不可见（预估前后 50,120,094 vs
50,120,005，差 89 次，纯噪声量级）。但这 ~40 次每次都是多 MB 的 memcpy——**事件数
和搬运字节数是两个维度**。解法是 0009 给钩子加的**大分配阈值计数**：
`MallocCounter.setLargeAllocationThreshold(1 << 20)` 后，≥1 MiB 的事件单独计数，
增长拷贝立刻显形（12 → 4，剩余 4 次即预留分配本身）。实现细节一并记下：realloc
事件同时带 alloc|dealloc 两个 bit，此时 size 在 `arg3`（`arg2` 是旧指针）——普通
分配的 size 在 `arg2`。

## 工具二：`PhysicalFootprintSampler` —— 峰值 footprint

`Sources/DemanglingTestingSupport/PhysicalFootprintSampler.swift`。

- **原理**：独立线程每 0.5ms 读一次 `task_vm_info` 的 `phys_footprint`（OS 内存
  账本，Xcode memory gauge 报的就是它），窗口内取峰值减基线。
- **极限**：采样型工具，驻留时间 < 0.5ms 的尖峰会漏。多 MB 的缓冲拷贝远宽于此。

**坑（0009 踩）——同进程第二遍起量不到任何尖峰**：首轮验收在最终 pass 上采样，
预估与否的 footprint 增量都是 ≈0——前几轮 pass 释放的页仍驻留在 allocator 里被
复用，「新旧缓冲并存」的尖峰根本到不了 footprint 账本。**对比 footprint 必须每个
模式一个独立进程、在冷启动 pass（进程内第一遍构建）上采样**：这样量出预估 vs 不
预估是 9.0 vs 18.0 MiB，尖峰减半清晰可见。基准套件为此提供
`DEMANGLING_RESERVATION_MODE=unreserved|reserved` 按进程选模式。

## 工具三：retain/release interpose 计数

`Scripts/RetainCounter/retain-counter.c` + `Sources/RetainCountVerification/main.swift`
（后者是 `Package.swift` 里 `DEMANGLING_RETAIN_HARNESS=1` 才存在的 executable）。

- **原理**：dylib 用 `__DATA,__interpose` 段替换 `swift_retain` / `swift_release`，
  `DYLD_INSERT_LIBRARIES` 注入后对**单个被观察对象**计数（其余对象直通）。编译要
  `-undefined dynamic_lookup`（被替换符号在链接期不可见）。
- **决定论**：同一 workload 的对数逐次一致，可以写成 PASS/FAIL 判据（harness 的
  判据：unretained 引擎的 ARC 流量 < 保留式引擎的 5%）。
- **战果**：就是它把 `unowned(unsafe)` 的 99 对/walk 量出来的（见「为什么自建」
  第 3 条）；返工后实测 1.00 对/walk vs 保留式 220.54 对/walk。复跑命令见
  [SpanBorrowedViews.md](SpanBorrowedViews.md) 验证工具箱。

## 工具四：时间基准的纪律

时间是这套度量里噪声最大的一维，纪律比工具重要：

- **warmup + best-of-N**：每个基准先跑一遍不计时（页缓存、分支预测热身），再取
  3 遍计时的最小值。pass 间波动 ±5% 是常态，**离群 pass 是污染信号**（见坑）。
- **只在 release 量**；构建测试用 `swift test -c release`——
  `swift build -c release --build-tests` 会因 `@testable` 缺 testability 而报
  `ModuleNotTestable`（`swift test` 自动带 `-enable-testing`）。
- **报告恒带符号量**：语料随机器的 dyld cache 变，比值与增量才可比，绝对秒数不可比。

**坑（踩过两次）——机器不空闲，计时全作废**：0008 的 legacy 首轮基准与一次并行
编译重叠，不碰 seam 的打印基准慢了 50%（这本身就是「结果不可能受影响的项也变了」
的自检信号）；0009 首轮基准期间本会话在并行编辑文档，reserved 模式出现 12.68s
离群 pass（其余 ~9s）。两次都是数字作废、空闲机重跑、决策日志记录污染原因。跑
基准期间**什么都不要干**——包括「只是改改文档」。

## 工具五：语料——三级真实符号集

全部来自本机 dyld shared cache（MachOKit 抽取），量级随机器与系统版本漂移，故文档
与决策日志里的语料数字**恒带符号量**：

| 语料 | 组成 | 本机当前量级 | 用途 |
|---|---|---|---|
| print 语料（史称「49k」） | SwiftUI、SwiftUICore、Foundation、Combine 导出符号去重 | ~440k | demangle 吞吐、打印吞吐、打印对拍 |
| store 语料（史称「234k」） | print 语料 + AppKit、UIKitCore、AttributeGraph | ~454k | store 构建基准、容量系数标定 |
| 全量语料 | dyld cache 全部 Swift 符号 | ~4.57M | 对齐 oracle（与 Swift runtime 逐字节对拍）、双路径重跑 |

全量 oracle 与 store Phase 3 验收测试**直接在默认 `swift test` 里跑**（无环境开关，
debug 全量约 7 分钟），这是刻意的：正确性回归不允许被「忘了开开关」漏掉。

## 环境开关速查

| 环境变量 | 作用 | 消费方 |
|---|---|---|
| `DEMANGLING_BENCHMARK=1` | 启用基准套件（默认跳过，只在 release 有意义） | `SpanBorrowedViewsBenchmarks`、`NodeStoreReservationBenchmarks` |
| `DEMANGLING_PRINT_PARITY=1` | 启用 corpus 规模 store/Node 打印逐字节对拍 | `StorePrintParitySweep` |
| `DEMANGLING_FORCE_LEGACY_PATH=1` | 整进程强制 demangle 走 pre-macOS 26 旧路径（0008 seam） | 任意套件的双路径重跑 |
| `DEMANGLING_RESERVATION_MODE=unreserved\|reserved` | 0009 基准每进程只跑一种模式（footprint 对比的前提） | `NodeStoreReservationBenchmarks` |
| `DEMANGLING_RETAIN_HARNESS=1` | 让 `Package.swift` 生成 retain 计数 harness 的 executable target | `RetainCountVerification` |

## 各提案验收用了哪些工具

| 提案 | 用到的工具 | 数字所在 |
|---|---|---|
| 0001（arena） | footprint 增量、语料构建计时、存储字节统计 | 0001 Decision Log、[NodeStoreArena.md](NodeStoreArena.md) 实测收益 |
| 0008（借用视图） | 全部三套基准 + `MallocCounter` + interpose 计数 + 双路径重跑 + 打印对拍 | 0008 Decision Log、[SpanBorrowedViews.md](SpanBorrowedViews.md) |
| 0009（容量预估 + 签发 tag） | 大分配阈值计数 + 冷启动 footprint（跨进程） + `capacityUtilization` 标定 | 0009 Decision Log |

## 判读备忘

- **先看计数器，再看计时**：事件数/对数是决定论的，先用它们确认机制成立（拷贝
  归零了吗、ARC 归零了吗），时间收益作为结果呈现——反过来会拿噪声当结论。
- **诚实记录不显著**：0009 的构建耗时 −7.1% 在波动带内，决策日志原样写「幅度在
  波动带内、方向有利」，不圆成「显著提速」。反之亦然：预期为零的项（如 0008 打印
  基准之于 legacy seam）变了 50%，先怀疑测量被污染，不是先庆祝或恐慌。
- **语言特性可行性不属于本文**，但同一精神：结论必须来自 `swiftc -c`（跑 SIL 诊断），
  `-typecheck` 只能证伪不能证实——展开见
  [SpanBorrowedViews.md](SpanBorrowedViews.md)「与提案的差异」第 3 条。
