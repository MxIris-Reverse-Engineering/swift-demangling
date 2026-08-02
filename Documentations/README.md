# 文档索引

本目录收录内部专题文档：每篇对应一次实质性的架构演进或一块独立的子系统。

## 专题

- [SubtreeInterning.md](SubtreeInterning.md) — 全子树 interning（hash-consing）内存优化。把 interning 从叶节点扩展到全部子树，49k 符号语料解析驻留 39.5 MB → 12.9 MB。
- [NodeStoreArena.md](NodeStoreArena.md) — `NodeStore` arena 式紧凑存储。节点平铺进连续缓冲，每节点 12 字节、无对象头、无引用计数；printer 与 TypeDecoder 泛型化后可零物化直读。
- [StackSafety.md](StackSafety.md) — 栈安全模型：与上游同构的「8MB 大栈 + 按 debug 实测校准的固定深度上限」，加上引擎之外全部整树遍历的迭代化（含 `Node` 迭代析构）。曾短暂采用按剩余栈字节的 `StackBudget` 方案，因调试器挂死 / 优先级反转 / 工作量不受限等固有代价撤回，文中记录了撤回理由与校准数据。
- [KnownIssues.md](KnownIssues.md) — 已确认真实存在但暂缓修复的问题追踪：TypeDecoder 的三处整数转换 trap（含字符串级触发器）、TypeDecoder 入口在小栈线程上的深度守卫失效、打印缓存的完整 fragment 回放越过深度上限、2MB inline 探针与 5.9MB 深度预算之间的窗口、TypeDecoder store 路径每层重物化的 O(k²)。含复现方式与修法方向。

前两篇是承接关系：`SubtreeInterning` 把 class 形态下能做的去重做到头，`NodeStoreArena` 兑现了它结尾列为「待将来单独评估」的 arena 方向。`StackSafety` 与内存方向正交，处理的是递归深度与线程栈。

## 其他位置的文档

- `evolution/` — 演进提案（设计意图 + 决策日志）。`0001-node-store-arena.md` 是 `NodeStoreArena.md` 的提案原文；`0002-stack-safety.md` 是 `StackSafety.md` 的提案原文；`0003-review-hardening.md` 是 PR #6 review 收尾轮——冻结移交的 `NodeBuilder`（环不可构造）、整树重建的按图计价（memo 保共享）、`description` 与 runtime dump 的逐字节一致（外加 8MB 输出上限）、移除 `Node: Codable`（序列化用 mangled string）、以及让近似签名的 `NodePrinterTarget` 实现变成编译错误；`0004-32bit-store-guards.md` 修复 Store 越界守卫的 `Int(UInt32.max)` 写法在 watchOS（32 位 `Int`）上被常量折叠成无条件 trap 的问题，并以源码扫描回归测试禁止该转换家族再次进入 `Sources/`；`0005-remangler-deepequals-memo.md` 给 Remangler 替换表相等比较 `deepEquals` 补上其余三个成对遍历都有的 proven-pair memo——此前对两份实例不同但结构相等的共享 bound-generic DAG，`mangleAsString` 按路径数（2^N）增长；`0006-interntree-and-demangler-postpass-memo.md` 一批修复四处按路径计价的整树遍历（`NodeCache.internTree`、demangler 的 opaque-return-type 后处理、`findGenericParamsDepth`、`identifier`）——此前一个 131 字符的构造合法符号就能把默认 `demangleAsNode` 拖到指数级——并附全库横向排查收口（TypeDecoder 一处留档 KnownIssues #6）。
- `docs/AlignmentGaps.md` — 与上游 Swift 编译器 `Demangling` 源码的对齐缺口追踪。
- `AGENTS.md` / `CLAUDE.md`（仓库根） — 面向编码 agent 的架构速查。
- `README.md`（仓库根） — 面向使用者的英文说明与用法示例。
