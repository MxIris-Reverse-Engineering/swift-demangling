# 0012 - PR #7 第三轮 review 的结构性遗留

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-08-16
- **最后更新**: 2026-08-16
- **所属愿景**: 无单一归属——四条留档条目分属 `Evolutions/README.md` 愿景第 3 条（计价纪律与健壮性）与第 4 条（API 演进）
- **关联提案**: [0007](0007-short-circuit-queries-and-typedecoder-sweep.md)（同一类「横向排查漏了一族」的先例）、[0009](0009-swift-syntax-arena-lessons.md)（`reserveCapacity` 的引入方）、[0010](0010-appendable-shared-node-store.md)（视图钉扎纪律的确立方，本提案第 1 条是它的补扫）
- **实现分支 / PR**: 未开始
- **配套文档**: 裁决过程见 [`Documentations/ReviewFindingsPR7.md`](../Documentations/ReviewFindingsPR7.md) 第三轮

## 摘要

PR #7 第三轮 `max` 档 code-review 的 15 条发现里，11 条已在同批修完（见
`ReviewFindingsPR7.md` 第三轮处置索引）。剩下 4 条不是「改几行」能定的：它们各自要
么改变一个公共类型的读取形状，要么要在两种语义之间做选择。本提案把这 4 条集中起
来，逐条给出问题、可选方案与倾向，供批准后再落实现。

四条彼此独立，可分别批准、分别落地。

## 动机

### 1. 通用遍历 API 没享受到「每 walk 解析一次视图」的纪律

0010 确立了视图钉扎（view pinning）：walk 入口把 store 的缓冲描述符解析一次、钉住
整个 walk。F14 当时把 printer、`structurallyEquals`、`structuralDigest` 都改到了这
条纪律上，printer 走 `UnretainedNodeReference`。

**没进那次清单的是通用 `DemanglingNode` 遍历族**：`preorder()`、`for node in
reference`（`Sequence` conformance）、`first(of:)`、`contains(_:)`、`identifier`、
`isSimpleType`。它们整个建立在散点读上——每访问一个节点，`children` →
`compactNode` → `store.compactNode(at:)` → `withView` 过一次锁；`ChildrenView` 的
下标每个孩子再 `store.rawChildIndex(of:at:)` → `withView` 一次；`kind` 又一次。

`NodeStore.withView` 的注释自述共享 store 是「locked 48-byte copy」「per-access
reads resolve fresh each time」，委托处直接把 `NodeReference` 和 children view 叫
「per-access consumers」——**作者知道散点读走锁**；没意识到的是公共遍历 API 全都是
散点读。

单线程实测（冻结 store vs 共享 store，同样的树）只慢约 7%。**问题不是延迟，是串行
化**：`SharedNodeStore` 的文档用法就是「每镜像一个实例、多线程索引」，N 个索引线程
读同一 arena 会把每次 `kind` / `children` 读串行到一把进程级 `os_unfair_lock` 上，
读并行为零——而这个类型存在的全部意义就是长期共享的 arena。

没有任何基准能看见它：`SharedNodeStoreBenchmarks` 只测 interning，
`SpanBorrowedViewsBenchmarks` 建的是冻结 store（`withView` 走廉价常量路径）。

**为什么要走提案而不是直接修**：修法形状 printer 已有示范，但要改的是**公共
`Sequence` conformance 的实现形状**，牵涉借用生命周期约束（钉住的视图不能逃逸出
walk，而 `Sequence` 的迭代器天然要跨调用存活）。这是设计决定。

### 2. scope 归属与片段缓存不组合

第三轮 finding 5 已修掉一半：`" in "` / `" of "` 分隔词现在写在 nil 屏障内，不再继
承外层 nominal 的类型引用（回归测试
`NodePrinterScopeTests.contextSeparatorsCarryNoTypeReferenceScope`）。

**另一半是结构性的**：`printName` 在 `canCache` 为真时把输出重定向进
`var subTarget = Target()`，而新建 target 的 scope 栈是空的，`append` 也不做重新归
属。于是**任何经嵌套 `printName` 打印的文本都看不见外层 scope**。私有 / 局部
nominal 的名字正是这么丢的：`LocalStruct` 自己 scope 为 nil，而同一次打印里的
`" in "`（修复前）却拿到了 Structure。

即 **scope 归属现在取决于一个 walk 全局的可缓存性条件**——同一个节点在可缓存位置和
不可缓存位置打印，scope 结果不同。这不是某一处漏了屏障，是两个机制没有对齐。

`04c959b`（基线 `next` 的最新提交）刚用 nil 屏障修完同族的嵌套类型分隔点误归属，
本轮又是它的直接邻居——**作者在逐个撞见这类问题**。一次系统排查（把所有
`target.write` 直写点 × scope 栈状态列一遍）比继续逐个撞便宜。

### 3. scope hook 挂在手挑的 kind 清单上

`7fcb0f1` 的 commit message 白纸黑字：「wraps the nominal-type dispatch (class /
structure / enum / protocol / typeAlias)」——五 kind 清单是设计时手挑的。
`.otherNominalType` 从第一天就不在，本轮已并入（回归测试
`otherNominalTypeGetsTheSameScopeAsOtherNominals`），但**清单式设计天然漏尾**：以后
每新增一个 nominal kind 都会以同样方式静默丢失 span，而且因为文本一字不差，没有任
何文本比对测试能发现。

`Node.Kind.isAnyGeneric` 已经枚举了近似正确的集合，但**不能照单全收**：它还含三个
symbolicReference kind，那些打印的是 `… symbolic reference 0x…` 而不是限定名，是否
该成为可导航 span 要逐个判断。

### 4. `reserveCapacity` 的 2^30 钳制只防住了转换 trap

`estimatedCount` 的注释已按本轮结论改写为如实描述（钳制只防 `Int(Double)` 转换的
trap，不保证分配成功）。**真正的修法没做**：在钳制值上，预留会真实索取约 12.9 GB
节点 + 4.3 GB 边 + 1.1 GB 文本 + 8.6 GB 唯一文本，外加三张用
`ContiguousArray(repeating:count:)` 建的 intern 表（那些是**写入**，不是仅预留），
而 `UnsafeMutablePointer.allocate` 走 `swift_slowAlloc`，失败即 `fatalError`——在一
个契约处处是 typed-throws 拒绝的库里，出现一个不可恢复的 abort。

`reserveCapacity(expectedSymbolCount:)` 在 `NodeStoreBuilder` 和 `SharedNodeStore`
上都是 public，文档说它接受符号计数，天然来源是 Mach-O 导出表计数。放大倍数受文件
尺寸约束，所以这不是一条容易触发的路径——但它的失败形态是进程 abort。

## 方案

### 1. 遍历族的视图钉扎

| 方案 | 做法 | 代价 |
|---|---|---|
| **A（倾向）** | 给遍历族加一个「借用一次视图」的入口形态：`reference.withPinnedView { pinned in … }`，`preorder()` / `first(of:)` / `contains(_:)` 内部改走它；`Sequence` conformance 保留现状并在文档里注明它是散点读形态 | 新增一个公共入口；`Sequence` 的便利性不变但快路径要显式选用 |
| B | 让 `Sequence` 的迭代器自己持有钉住的视图 | 迭代器要跨调用持有借用，与 `~Escapable` 约束冲突，可能要等语言能力 |
| C | 只把 `first(of:)` / `contains(_:)` / `identifier` 这类**内部自成 walk**的查询改掉，`Sequence` 不动 | 覆盖面小但零 API 变化，可作为 A 的第一步 |

倾向 **C 先落地、A 作为完整解**：C 无 API 变化、能立刻拿掉大部分锁流量。

**验收**：多线程读同一 `SharedNodeStore` 的吞吐随线程数线性（现在是平的）；单线程
不回归。需要新增一个并发读基准——现有三个基准都看不见这条路径。

### 2. scope × 缓存的语义

| 方案 | 做法 | 代价 |
|---|---|---|
| **A（倾向）** | `append` 时把 sub-target 里「未归属」的 span 归到拼接点的栈顶 | 需要 target 协议表达「未归属」与「重新归属」，是协议层扩展 |
| B | `subTarget` 创建时继承当前 scope 栈 | 改动小，但缓存的片段就带上了位置相关的 scope——同一片段在不同位置复用会给出错误 scope，等于把 bug 换个形态 |
| C | 凡是 scope 栈非空就不缓存 | 正确但把缓存在最常见的路径上关掉了 |

倾向 **A**。B 有正确性问题（缓存片段必须是位置无关的，这正是 `truncationCount` /
`specializationPrefixVisitCount` 两个守卫存在的理由），C 代价过大。

**先决动作**：一次系统排查，把 `NodePrinter` 里全部 `target.write` 直写点连同当时的
scope 栈状态列成表——这张表本身是产出，能确定还有多少处误归属。

### 3. hook 的挂载点

| 方案 | 做法 |
|---|---|
| **A（倾向）** | 把 push/pop 移到 `printEntity` 内部，由它按参数判断是否是 nominal 引用；dispatch switch 不再各自持有清单 |
| B | 保留在 switch，但改用一个显式命名的 kind 集合常量（如 `Node.Kind.navigableNominals`），并加测试断言该集合与 `isAnyGeneric` 的差集只含已裁决的 symbolicReference kind |

倾向 **A**（挂到机制而不是清单），**B 作为退路**——若 `printEntity` 的调用点语义不
够齐，B 至少能让「漏尾」在测试里显形。

**验收**：新增一个测试，遍历 `Node.Kind.isAnyGeneric` 的全部成员，逐个断言「push 了
scope」或「在已裁决的豁免名单里」——名单里每一项要写明豁免理由。

### 4. 按字节预算封顶

倾向：把 `reserveCapacity` 的钳制从「元素数 2^30」改为「总字节预算」，预算取
`min(可用物理内存的某个比例, 一个绝对上限)`，超出时**按比例缩减**全部预留而不是拒
绝——预留本来就只是优化，缩减不影响正确性。同时把「预留失败不影响正确性」写进
doc comment。

不倾向让它 throw：`reserveCapacity` 现在是非抛的，改抛会波及两个公共类型的调用点，
而缩减方案不需要改签名。

## 影响

**源码兼容性**：条目 1 的方案 A 新增公共入口（加法，不破坏）；方案 C 零 API 变化。
条目 2 的方案 A 扩展 `NodePrinterTarget` 协议——**这是破坏性的**，需要一并规划默认
实现或迁移说明（注意本 PR 已有的三处破坏，见
`Documentations/NodeStoreArena.md` 源码兼容性一节，不宜再无声增加第四处）。条目 3、4
无公共 API 变化。

**ABI 兼容性**：不适用（纯 SPM 源码分发，未开 library evolution）。

**API 演进与废弃策略**：条目 2 若采用方案 A，`NodePrinterTarget` 的新要求应带默认实
现——与本 PR 里「删掉默认实现以暴露 near-miss witness」的取舍相反，但那条取舍针对的
是**已有实现会被静默顶替**的场景；一个全新的要求没有旧签名可被顶替，默认实现无害。

**下游仓库影响**：已知消费者 MachOSwiftSection、RuntimeViewer。条目 1 的收益直接落
在它们的多线程索引路径上；条目 2 的协议变更需要它们配合。

## 决策日志

- **2026-08-16**：由 PR #7 第三轮 review 的四条结构性发现立项，状态 `Draft`。同批已
  落地的 11 条修复见 `Documentations/ReviewFindingsPR7.md` 第三轮。
