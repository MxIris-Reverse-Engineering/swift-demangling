# PR #7 code-review 发现清单（`feature/node-store`）

本文件是 **PR #7 一轮 `max` 档 code-review 的完整发现记录**，含每条发现的「四问」答案与
修法方向。**这些发现尚未裁决**——判定为「不修 / 误报」的条目，裁决后要迁进
[KnownIssues.md](KnownIssues.md) 并从本文件移除；判定为「修」的条目，修完后同样移除，
并在对应演进提案的决策日志里留一行。本文件清空即代表本轮 review 闭环。

## 元信息

| 项 | 值 |
|---|---|
| 审查目标 | PR #7 `feature/node-store` @ `9464265` |
| 对比基线 | merge-base `f913742`（已在 `main` 上） |
| PR 规模 | 61 个文件，+7,492 / −1,019，21 个 commit |
| 覆盖的提案 | 0008（扫描器字节化 / 借用视图）、0009（容量预留）、0010（`SharedNodeStore`）、0011（transient 入口转正） |
| 审查日期 | 2026-08-09 |
| 验证方式 | 在 PR tip 与 merge-base 各建独立 worktree 分别编译，用临时探针测试做 A/B 对比（探针已删） |
| 当时的套件状态 | PR tip 全量 **520 个用例全绿** |

**「全绿」这件事本身需要解释**：F2、F3、F11、F12 四条正是「为什么套件全绿却仍有
问题」的答案——一条功能回归、一个被静默编译掉的测试、一类吞掉失败的语料验收、一条从未
被执行过的分支。（F3 与 F4 已于 2026-08-09 落地并按本文件契约移除，落地记录见文末
移交清单第 0 步；元模式一节保留它们的行作为本轮 review 的完整背景。）

## 总览

优先级的判据是「谁会踩到、多容易踩到、后果多严重」，不是「改起来多难」。

| # | 位置 | 一句话 | 是否本 PR 引入 | 优先级 |
|---|---|---|---|---|
| [F14](#f14) | `NodeStore.swift:148` | 共享 store 每次散点读都过锁，walk 内逐节点重进 `withView` | 是 | 应修 |
| [F15](#f15) | `DemanglingNode.swift:318` | 异步 `print` 少了同步版有的生命周期锚点 | 否（`main` 既有） | 可延后 |

另有 [9 条补充发现](#补充发现)（**未逐条验证**，被 review 的条目上限截断）与
[1 条流程问题](#流程问题)。

---

## 元模式：验证方法对某一类问题结构性失明

15 条里至少 6 条（F1、F2、F4、F7、F11、F13）是同一个形态，而这个形态的名字是本项目
**自己**在 2026-08-02 的 `4ec46d8` 里写下的：

> a verification method structurally blind to this class
> （一种验证方法，对某一类问题结构性失明）

那次说的是：第一次 32 位整数问题（`06a423c`，字面量溢出）靠交叉编译发现，于是交叉编译
成了防线；但第二次（`Int(UInt32.max)` 被常量折叠成无条件 trap）**编译得干干净净**，
交叉编译这道防线对它完全看不见。

本轮的六条各自撞上一堵这样的墙：

| 发现 | 本该拦住它的防线 | 为什么没拦住 |
|---|---|---|
| F1 | `4ec46d8` 建的源码扫描测试 | 只扫三个**字面量**（防常量折叠型），`value + 1` 是运行时值溢出型 |
| F1 | `KnownIssues.md` §1 的崩溃点清单 | 清点范围只有 `TypeDecoder.swift`，`Demangler.swift` **从未被清点过** |
| F2 | 452 万符号的 dyld 语料扫描 | 符号表全是 ASCII，0xFF 永远不会出现在语料里 |
| F4 | 43.9 万符号的打印对拍 | 两边都 `try?`，失败符号在比较前就被 `continue` 掉了 |
| F7 | 全语料 debug sweep（零触发） | `assert` 只在 debug 生效，验收跑的正是 debug——验证了「今天没问题」，没建立「明天也不会有」 |
| F11 | `DEMANGLING_FORCE_LEGACY_PATH` 双跑纪律 | seam 只切 demangler 侧，store 侧只看 `#available`，双跑其实是同一条路跑两遍 |
| F13 | 「测量窗口不得重叠」的自定纪律 | 纪律写于只有一组 benchmark 时，套件长到三组后没人重新检查 |

**这条元模式本身就是一条修法要求**：下面每条的「修法方向」里，凡涉及新增防线的，都要
同时回答「这道防线对哪一类问题是瞎的」。只补一个测试用例而不问这句话，就是在重复
`06a423c` → `4ec46d8` → 本轮的循环。

---

# 第二部分：应修

<a name="f14"></a>
## F14. 共享 store 每次散点读都过锁，walk 内逐节点重进 `withView`

- **位置**：`Sources/Demangling/Store/NodeStore.swift:148`（`withView`）、
  `:178`（`nodeCount`）、`:220`（`reference(at:)`）、`:320`（`withSpans`）；
  `NodeReference.swift` 的 291 / 471 / 487 / 509 / 518

- **现象**：
  - `withView` 经 `sharedViewState.currentView()` → `state.withLockUnchecked`。
    于是 `reference.children[i].kind` 这样一次遍历，**每个节点要三次取锁往返**
    （`children` → compactNode，`children[i]` → rawChildIndex，`.kind` → compactNode）；
  - `reference(at:)` 解析视图**两次**，因为它的边界 `precondition` 读的是 public 的
    `nodeCount`（`:178`，自己又开一次 `withView`）；
  - 更严重的是 `structuralDigest()` 和 `structurallyEquals(_: Node)`：它们先开
    `store.withSpans`，然后在**循环内部**逐节点调 `store.contents(of:)` /
    `store.indexPayload(of:)`。一次 1,200 节点的摘要要多花约 1,200 次取锁 + 48 字节
    描述符拷贝——**而且一次比较的两半可能来自两个不同的视图**。

- **它与提案直接冲突**：0010 的「已否决方案」第 3 项原文：

  > **每次访问加锁——否。** 读是热路径，walk 内逐节点取锁的代价不可接受；
  > 本设计读侧无锁（钉视图后纯指针读）。

### 四问

1. **能复现吗**：代码路径确凿。**不是误报，但它是性能/设计偏离，不是正确性缺陷**——
   当前实现是**正确的**，只是慢，所以没有任何测试会抓到它。
2. **`main` 是否也有**：`main` 没有 `SharedNodeStore`。**本 PR 引入。**
3. **值不值得修**：**应修**。理由不是「现在慢」，而是**实现偏离了提案明确否决的方案，
   且这个偏离没有被任何地方记录**——下一个读提案的人会以为读侧是无锁的。
4. **以前修过吗**：**没修过。这是「实现偏离提案，且偏离未被记录」。**
   - 0010 提案第 214-215 行其实**预见到了**要用原子发布：「`ManagedAtomic` 级别的原语
     或 `os_unfair_lock` 保护的指针槽——描述符切换仅发生在增长时，频率极低，实现取锁
     也不构成热点；具体拼写落地时定」；
   - 落地（`60afea0`）选了 Mutex，决策日志自己写的是「读者**锁内**拷出 48 字节描述符」；
   - **问题出在提案那句「实现取锁也不构成热点」**——它成立的前提是「描述符切换时才取锁」，
     而实现变成了「**每次读都取锁**」。这个前提的翻转没有被任何一处指出。

- **修法方向**：
  1. 让 `withSpans` 直接把已解析的 `BufferView` 交出去（它本来就带
     `contents(of:)` / `indexPayload(of:)` / `rawChildIndex(of:at:)`），
     删掉 store 层那些会重新解析视图的转发器；
  2. 用原子盒发布描述符，让 `currentView()` 变成一次普通 load——这正是提案第 214-215 行
     原本设想的形态；
  3. `reference(at:)` 的边界检查改用已解析视图的 `nodes.count`，消除第二次解析；
  4. 在 0010 决策日志里补记这次偏离与订正。

---

# 第三部分：非本 PR 引入

<a name="f15"></a>
## F15. 异步 `print` 少了同步版有的生命周期锚点

- **位置**：`Sources/Demangling/Store/DemanglingNode.swift:302-303`（同步，有锚点）
  对 `:318`（异步，没有）
  ```swift
  public func print(using options: DemangleOptions = .default) -> String {
      withExtendedLifetime(store) {          // :303
  ...
  public func print(using options: DemangleOptions = .default) async -> String {
      // 没有对应的 withExtendedLifetime
  ```

- **现象**：同步版把整个 walk 包在 `withExtendedLifetime(store)` 里，正是因为
  `UnretainedNodeReference` 不持有任何强引用——它的安全契约
  （`UnretainedNodeReference.swift:17-25`）要求调用作用域保证 store 强存活，而这正是
  让 `StoreBuffer` 的分配（**包括共享 store 的退休代**）保持有效的东西。异步版只有
  在飞的 `store.withView` 调用带来的隐式借用。

- **相关的潜在隐患**（同一区域）：把这个句柄 conform 到 `DemanglingNode` 会自动派生出
  一批可逃逸的接口（协议的异步 `print`，以及 `DemanglingNode+Sequence.swift` 的
  `preorder()` / `postorder()` / `levelorder()`），它们会把栈帧指针存进可逃逸的值里，
  而 `@unchecked Sendable` 恰好压掉了编译器的反对意见。

### 四问

1. **能复现吗**：**今天不能**——异步路径当前是充分安全的。这是一条**不对称性/脆弱性**
   发现，不是当前缺陷。必须如实这样描述。
2. **`main` 是否也有**：**有**。同步侧的锚点来自 `4ed790e`；两个 print 合并到
   `DemanglingNode` 是 `f913742`，而 **`f913742` 已经在 `main` 上**。
   **非本 PR 引入。**
3. **值不值得修**：**可延后**，但本 PR **抬高了它的风险等级**：`60afea0` 引入退休链后，
   「store 强引用保活缓冲」的含义从「保住一块 buffer」变成了「保住整条退休链」。
   加一行 `withExtendedLifetime` 成本极低，建议顺手做。
4. **以前修过吗**：**没有前科**。两条路径在 `f913742` 合并时就是这样，合并 commit 的
   关注点是「消除 `Node` 与 `NodeReference` 的重复实现」，没有对齐生命周期锚点。

- **修法方向**：给异步版加上同样的 `withExtendedLifetime(store)`；顺带在
  `UnretainedNodeReference` 的文档里点明「协议派生的接口也在契约覆盖范围内」。

---

<a name="补充发现"></a>
# 第四部分：补充发现（未逐条验证）

以下 9 条被 review 的条目上限截断，**没有经过 A/B 验证，也没有做四问**。
**不要把它们当作已确认的缺陷**——处理前需要各自先复现。按「看起来值得先看」排序：

1. `NodeStoreBuilder.slotCount`：如果某张表的初始槽数为 0，会无限循环。
2. `PhysicalFootprintSampler.stop()` 在没有 `start()` 的情况下调用会死锁。
3. `RetainCountVerification` 的 `unretained * 20 < retained` 判据：基线测到 0 时会
   报 FAIL；而且它在计数窗口**内部**创建引用。
4. `SharedNodeStore` 没有暴露 `reference(at:)`，因此一个存下来的 public `NodeIndex`
   无法被解析回引用。
5. `publishCurrentState` 每次 intern 都在写锁内分配一个 3 元素的 `[AnyObject]`。
6. `forcesLegacyPath` 每次 demangle 都要过一次全局 `Mutex`。
7. `NodeStore` 从受检 `Sendable` 变成了整类 `@unchecked Sendable`。
8. `EmbeddedFlavorTests` 现在只构造 legacy 配置。
9. 重复代码：三份子节点索引解析的 switch、重复的语料配方、重复的 benchmark 脚手架。

---

<a name="流程问题"></a>
# 第五部分：流程问题

按 `~/.claude/CLAUDE.md` 的「Evolution 提案制」：**提案未经维护者批准（状态置为
`Accepted`）不得开始写实现代码**。本 PR 涉及的四份提案都没有经过 `Accepted` 这一状态：

| 提案 | 状态轨迹 | 状态更新与实现代码是否同 commit |
|---|---|---|
| 0008 | `Draft` → `In Progress` | 是 |
| 0009 | `Draft` → `Implemented` | 是（`99100c3`） |
| 0010 | `Draft` → `In Progress` | 是 |
| 0011 | `Draft` → `Implemented` | 是（`e874cbd`） |

这不影响代码正确性，但它意味着**这四批改动都没有经过「动手前先获批准」这一关**。
是否补办、怎么补办，由维护者决定；本文件只做记录。

---

# 移交清单

给接手实现的人。**顺序是有理由的，建议照做**：

**第 0 步 —— ✅ 已完成（2026-08-09，F3 与 F4 条目已按本文件契约移除）**
1. **F3 落地**：元测试先行确认红（`Lifetimes` 未达测试 target）→ `Package.swift`
   testTarget 补开关 → 元测试绿，`directReturnSpanAgreesWithClosureForm` **首次真实执行
   并通过**（借用视图代码本身无缺陷，此前只是零覆盖）。
2. **F4 落地**：四处吞失败全部改造——单边失败 = 对拍不匹配；双边失败改为按 stdlib
   demangler（默认 oracle 的同一裁判）分类：stdlib 也拒绝 → 一致拒绝（计数并打印样本），
   stdlib 能解而本库不能 → 回归，断言为 0。`nil == nil` 恒真形态消灭；
   RetainCountVerification 改为拒绝测量缩水的输入。
3. **重跑结果（真实基线）**：默认全套件 520 用例绿；对齐 oracle 4,573,306 符号
   demangle failures 0；三个 corpus sweep × 双运行时路径 439,522 符号 0 mismatch、
   0 单边失败。**果然抖出了东西**：语料实际是 439,533 个符号，其中 **11 个双路径
   都解不开**——正是原来被 `try?` 静默吞掉的（0011 决策日志「remangle 可达 439,522」
   的差值即此 11 个，当年被记成 remangle 不可达，实为 demangle 失败）；经 stdlib
   分类确认为一致拒绝（stdlib 同样解不开的符号表内容），非本库回归。

**第 1 步 —— ✅ 已完成（2026-08-09，F1 与 F2 条目已按本文件契约移除）**

4. **F2 落地**：字节域跳过（raw `FF` + `C3 BF` 两种拼写）；针对性测试修复前红、修复后
   绿（`AppleAlignmentTests.alignmentPaddingBeforeOperatorIsSkipped`）；`AlignmentGaps.md`
   A9 行已注记回归与复修；**横向排查完成**——group-a 其余 7 项全部为 ASCII 域比较或
   不经扫描器，全 Demangler 唯一的非 ASCII scalar 比较就是 0xFF 这一处，无同类失效。
   决策日志行在 0008（回归由其字节化引入）。
5. **F1 落地**：清点范围扩到 `Demangler.swift` / `Remangler.swift` / `NodePrinter.swift`
   并全库重扫，**找到的比 review 点名的多**——Demangler 六处（点名的 4 处 + `count = index + 1`
   环绕 + Swift 3 `nameStack` 下标先窄化后检查）+ Remangler substitution 哈希一处，全部
   无符号域界检查后再窄化，超界抛 `DemanglingError`；exit test（review 的两条触发字符串，
   红→绿）+ 致陷拼写扫描测试双防线入库，盲区互补已言明。清点全文在 `KnownIssues.md`
   2026-08-09 更新；决策日志行在 0004（整数陷阱家族）。TypeDecoder 8 处维持暂缓不变。

**第 2 步 —— ✅ 已完成（2026-08-09，F5–F8 条目已按本文件契约移除）**

6. **F5 落地（维护者裁决方案 A）**：空代也进退休链，「描述符终生有效」承诺无条件成立；
   红→绿测试 + 引用跨预留存活行为钉；`reservationKeepsTheRetirementChainEmpty` 更名为
   `reservationRetiresOnlyTheInitialEmptyGenerations`。**F7 落地**：`internInterior`
   的不变量 `assert` → `precondition`（release 生效；它是 interior 唯一铸造漏斗）。
   **F6 落地**：四处 range 读收敛到 `withBuffer(in:)` 界检查访问器 + exit test；
   `StoreBuffer` 与 `SharedViewState` 的冲突措辞全部订正。
7. **F8 落地**：`reserveCapacity` 取加倍下界（首次预留仍精确，增量再预留 ≤2× 超配换
   O(log) 代数）；策略测试断言坡道第 4/6/7/8 步为 no-op（修复前每步都增长，实测
   17 个退休代）。**吞吐复测挂账到 F13 之后**（测量窗口修好才有可信数字）。
   四条的决策记录合并为 0010 决策日志 2026-08-09 行。

**第 3 步 —— ✅ 已完成（2026-08-09，F9 与 F10 条目已按本文件契约移除）**

8. **F9 落地**：`getManglingPrefixLength` 改 `UTF8View.starts(with:)` 字节比较，与
   扫描器同一定义，`main` 行为恢复；非 ASCII 前缀判定测试入库；0008 的「行为差异，
   明示」一节已就地补记当年漏了什么。**F10 落地（维护者裁决：改签名）**：更名
   `textUTF8Bytes`、返回类型改 `[UInt8]?`——拷贝与 0 基进签名，旧拼写编译失败；
   内部使用点同批迁移，不做 `Array` 归一化的内容钉测试入库；README 陈旧注释与
   AGENTS.md 同步。决策日志行分别在 0008（F9）与 0010（F10）。

**第 4 步 —— ✅ 已完成（2026-08-09，F11–F13 条目已按本文件契约移除）**

9. **F12 落地**：legacy 腿抽为 internal 直接入口 `demangleAsNodeOnLegacyRuntimePath`，
   `DualPathParityTests` 显式驱动双腿、全程不碰进程状态；task-local 方案经论证否决
   （seam 在 `StackSafeExecutor` 闭包内读取，pthread hop 不传播）；「测试 target 无
   seam 赋值点」扫描测试入库。**F11 落地**：store 创建时快照 seam + builder 增量
   维护的全表 ASCII 位随视图发布（全 ASCII 表 → 任意界内子区间自成合法 UTF-8，
   与 demangler 侧同构；非 ASCII 表降级带校验解码）；`#available` 分流点清单进
   `SpanBorrowedViews.md`。**F13 落地**：跨套件 `ExclusiveMeasurementWindow` 互斥、
   `malloc_logger` 保存/恢复 + `__atomic` 读写、采样线程启动挪出 malloc 窗口（停止
   顺序保留计数器先停，与 review 建议的偏差及理由见 0008 决策日志行）；
   `MeasurementToolbox.md` 增补新套件必包窗口规则。三条的决策日志行均在 0008；
   重测数字的 0009/0010 订正行随 benchmark 重跑同批。

**第 5 步 —— 性能与收尾**

10. **F14**（共享 store 的锁）：改 `withSpans` 交出 `BufferView` + 原子发布描述符 +
    在 0010 决策日志补记偏离。
11. **F15**（异步 print 锚点）：一行的事，顺手做。
12. **第四部分那 9 条**：逐条先复现再判断，不要直接改。

## 全程必须遵守的三条

1. **每个要修的问题，先写能复现的失败测试**，确认它在修复前**失败**，修复后**通过**，
   并作为回归测试**永久保留**、与修复代码同批次提交。
2. **确认为真的问题必须横向排查同类**——修的是「这一类」不是「这一个」。F1 和 F2 都明确
   带了横向排查任务。
3. **每加一道防线，回答一句「这道防线对哪一类问题是瞎的」**，并把答案写进代码注释或
   决策日志。不回答这句话，就是在重复
   [元模式](#元模式验证方法对某一类问题结构性失明)那张表里的循环。

## 文档同步要求

修复落地时，以下文档需要在**同一批次**更新（缺文档等同于缺代码）：

| 文档 | 因哪条而改 |
|---|---|
| `Documentations/AlignmentGaps.md`（A9 条目） | F2 |
| `Documentations/KnownIssues.md`（§1 清点范围；本轮裁决为「不修/误报」的条目迁入） | F1，以及所有最终判定不修的条目 |
| `Documentations/MeasurementToolbox.md`（新增 benchmark 套件的窗口互斥要求） | F13 |
| `Documentations/SpanBorrowedViews.md`（seam 覆盖范围、文本物化闸门） | F11 |
| `Evolutions/0008-span-borrowed-views.md`（「行为差异，明示」补记前缀语义） | F9 |
| `Evolutions/0009-*.md` / `Evolutions/0010-*.md` 决策日志（重测数字、锁偏离、空代决策） | F5、F8、F13、F14 |
| 本文件 | 每条闭环后移除；清空即本轮 review 结束 |
