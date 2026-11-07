# 0018 - demangle 不再复制整个 Demangler，remangle 不再逐格销毁节点哈希缓存

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-11-07
- **最后更新**: 2026-11-07
- **所属愿景**: `Evolutions/README.md` 愿景第 2 条（内存形态）与第 3 条（计价纪律）
- **关联提案**: [0016](0016-unretained-kind-queries.md)（同样是下游并行时暴露的引用计数开销）；下游 MachOSwiftSection 提案 `draft-machofile-performance`（问题在那里暴露）
- **实现分支 / PR**: `perf/demangler-self-copy`（快进合入 `next`，随 0.7.3 发布）

## 摘要

下游 MachOSwiftSection 把一个镜像全部符号的 demangle 分给多个线程做（每个线程各自 demangle 不同的名字），CPU 时间却是单线程的约 2.3 倍，采样里一半在 `swift_retain` / `swift_release`。根因在 `Demangler`：`try require(pop())` 这类写法里 `require` 不是 `mutating`，Swift 先求接收者再求参数，而参数要改 `self`，编译器只好先把整个 `Demangler` 复制一份当接收者；复制让节点栈的缓冲不再唯一，随后的 `pop()` 就把整个节点栈连同每个节点的引用计数写时复制一遍，复制品销毁时再逐个释放。单线程时这份复制也占 demangle 时间约三分之一；多个线程同时做时，`NodeFactory` 的无参单例节点被所有线程一起加减引用计数，缓存行在核之间来回搬。

同一批采样里还有一处：`Remangler` 每次创建都分配一张 512 格的 `[SubstitutionEntry?]` 节点哈希缓存，销毁时运行时对每一格调用一次值见证判断有没有要释放的引用——进程内打印 SwiftUI 时这一项约占 6%。

两处都只改实现：demangle 出的树、remangle 出的字符串逐字节不变，公开 API 不变。

## 方案

1. **`Demangler.require` 不再复制接收者**。两个 `require` 重载改为 `mutating`：mutating 方法的接收者是 inout 访问，在参数求值之后才开始，编译器不必复制。只有失败路径看得出差别：`DemanglingError.unexpected(at:)` 记的是参数求值之后的扫描位置，而不是之前的——对 `require(pop())` 这类不动扫描器的参数两者相同，对边读边判断的参数要往后挪过读掉的那几个字节。没有测试或下游依赖这个位置（下游一律 `try?` 或只转述错误），按「失败信息允许变化」处理。
2. **`Remangler` 的节点哈希缓存不再逐格销毁**。缓存格改成不含引用的平凡类型（节点的对象标识、哈希、是否当标识符），存进缓存的节点另记在一张保活表里，保证它们活到这次 remangle 结束——原先由缓存格自己的强引用保证，所以同一地址不会在一次 remangle 内被别的节点复用，按指针比对命中的语义不变。数组销毁时不再逐格调用值见证，只释放实际进过缓存的那些节点。
3. **找同类**：在 `Demangler`、`Remangler`、`NodePrinter` 里找参数会改 `self` 的非 mutating 方法调用（同样的接收者复制），一并处理或记下不处理的理由。
4. **验证**：全量测试（含全语料对齐 oracle，比对每个符号的树、remangle 结果与两种打印，`DEVELOPER_DIR` 指向 Xcode 27）；下游 MachOSwiftSection 的渲染 A/B。收益用下游的基准程序量（只建索引与打印的 instructions retired、并行时的 CPU 时间），改前改后记进决策日志。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-11-07 | 创建为精简提案，用户批准改并发版；状态 In Progress | 下游采样：并行 demangle 的一半 CPU 在这份复制引起的引用计数争用上；在沙盒里只把 `require` 标成 `mutating`，下游建 SwiftUI 索引的指令少约 5%，并行时的 CPU 从单线程的约 2.3 倍降到约 1.25 倍，interface 输出逐字节不变 |
| 2026-11-07 | 找同类：`Remangler`、打印器里没有这种复制；`Demangler` 里还剩 `createNode` 的四个组合形式（没有内联，参数里常带 `require(pop(...))`），一并标成 `mutating`。单节点的几个 `createNode` 不动：两个非 mutating 的函数要用它们，而它们总是内联、只读 `let internsLeaves`，优化器会把复制去掉 | 下游改后采样：`outlined destroy of Demangler` 只剩每次 demangle 结束时那一次，外加 `demangleStandardSubstitution` 的 `Optional` 分支（组合形式的参数里有 `require(pop(kind:))`）；其它函数里一次也没有 |
| 2026-11-07 | 下游实测（MachOSwiftSection 的基准程序，release，本机 cache 的 SwiftUI，与改动前同一构建对比，interface 输出逐字节不变） | 只建索引：离线 70 G → 64 G、进程内 65 G → 60 G 条指令，并行时 CPU 11.4 秒 → 6.8 秒；interface 打印：离线 92 G → 87 G、进程内 67 G → 61 G；改后采样里 `Remangler` 销毁哈希缓存的值见证调用从约 45 个样本降到个位数 |
| 2026-11-07 | 不加按分配次数断言的回归测试 | 输出不变由全语料对齐 oracle 逐符号保证（树、remangle 结果、两种打印）；分配次数随工具链的数组增长策略变化，写成断言会随 Xcode 升级误报。收益按本库惯例记在决策日志里，以后有回归时用同一套下游基准复量 |
| 2026-11-07 | 实现完成，编号 0018，快进合入 `next`，发 0.7.3 | 全量测试（`DEVELOPER_DIR` 指向 Xcode 27.2，含全语料对齐 oracle）645 个通过（8 个已知问题），两轮：一轮在组合 `createNode` 改动之前，一轮在之后；Xcode 26.6 编译通过。配套文档：`AGENTS.md` 的 Conventions 一节记下「接 `pop()` 当参数的辅助方法要 `mutating`」，不另写实现说明或指南。新术语：无 |
