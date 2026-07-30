# 已知问题追踪（Known Issues）

> 已确认真实存在、但经维护者决定**暂缓修复**的问题。每条记录：现象与根因、复现方式、
> 影响面评估、暂缓理由。修复任何一条后请把该条目移除并在对应演进文档中记录修复。

- **记录日期**：2026-07-30（PR #6 review 期间逐条用复现测试确认）。
- **暂缓决策**：下游消费方（MachOSwiftSection 等）当前未使用 `TypeDecoder` 的任何接口，
  故 TypeDecoder 范围内的健壮性问题本轮不修（维护者 2026-07-29 决定）。

---

## 1. TypeDecoder：三处会陷入（trap）的整数转换

对畸形输入，`TypeDecoderEngine` 的契约是抛 `TypeLookupError`；但以下三处用了会 trap 的
整数转换初始化器，守卫（guard）只挡 `nil` 不挡量级，超范围值直接使进程崩溃（SIGTRAP）。
三处均为 `main` 既有问题，非 node-store PR 引入。

| 位置（`TypeDecoder.swift`，`feature/node-store` @ 69fdbd3） | 转换 | 触发条件 |
|---|---|---|
| `decodeMangledType` 的 `.integer` / `.negativeInteger` 分支（964/970 行附近） | `Int(index)` | `index > Int.max` |
| `decodeRequirements` 的 `.dependentGenericInverseConformanceRequirement` 分支（1426 行附近） | `UInt32(index)` | `index > UInt32.max`（`?? .copyable` 兜底永远等不到转换完成） |
| `decodeMangledType` 的 `.dependentGenericParamType` 分支（329 行附近） | `Int(depthValue)` / `Int(indexValue)` | depth 或 index `>= 2^63` |

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

**修法方向**：三处改用 `Int(exactly:)` / `UInt32(exactly:)`，超范围抛 `TypeLookupError`。

## 2. TypeDecoder 公开入口不经 `StackSafeExecutor`，小栈线程上深度守卫失效

`TypeDecoder.decodeMangledType(node:)`（含 `NodeReference` 重载）在调用线程原地执行——
这是**有意设计**（`TypeBuilder` 回调可能绑定 actor/线程，见方法文档），代价是栈余量由
调用方负责。但 `maxDepth = 160` 按 8MB 栈实测校准（unoptimized 每层约 30KB）；在 512KB
的协作/派发线程上，约嵌套 16 层（8–10 层 Optional 套叠）即先于守卫爆栈 SIGSEGV。
`demangle` / `remangle` / `print` 三族入口均自动经 `StackSafeExecutor` 保护，唯此入口
不对称，文档虽有要求（调用方自行 `withLargeStack`）仍属易踩的坑。

**修法方向**：不改变"回调在调用线程执行"契约的前提下，无法简单套用 executor 跳线程；
可考虑入口处检测剩余栈并在不足时直接抛 `TypeLookupError`（拒绝而非崩溃），或在文档升级为
编译期可见的 API 形态（如要求显式传入栈证明参数）。需要单独设计。

## 3. 调用方构造的环状 `Node` 使"完成时写 memo"的迭代遍历无界增长

`NodeBuilder` 可构造互相引用的环（`a ↔ b`）。`Node.==`/`structurallyEquals` 因"提前登记
已访问对"而环安全；但按"节点完成后才写 memo"的迭代遍历——`Node.structuralDigest` /
`Node.hash(into:)`（把环状节点当字典键即触发）、`NodeCache.internTreeUnsafe`、
`NodeStoreBuilder.internTree`、`NodeReference(interning:)`——在环上节点永不"完成"，
frame 栈无界增长直至 OOM（旧递归实现的失败形态是爆栈，迭代化后变为 OOM）。

仅对抗性输入可达（demangler 不产环）；`isSimpleType` 的 `.type`-unwrap 循环已对同类
构造设界，这批遍历尚未。**复现即无界耗内存，不适合入库为自动化测试**。

**修法方向**：与 `==` 一致，为这些遍历加"在途节点"检测（visited-on-stack 集合），
遇环时按身份折叠或直接 fatalError 带诊断信息。
