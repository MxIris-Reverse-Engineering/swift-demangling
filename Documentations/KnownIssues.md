# 已知问题追踪（Known Issues）

> 已确认真实存在、但经维护者决定**暂缓修复**的问题。每条记录：现象与根因、复现方式、
> 影响面评估、暂缓理由。修复任何一条后请把该条目移除并在对应演进文档中记录修复。

- **记录日期**：2026-07-30（PR #6 review 期间逐条用复现测试确认）。
- **暂缓决策**：下游消费方（MachOSwiftSection 等）当前未使用 `TypeDecoder` 的任何接口，
  故 TypeDecoder 范围内的健壮性问题本轮不修（维护者 2026-07-29 决定）。
- **2026-07-30 更新**：原第 3 条（调用方构造的环状 `Node`）已修复并移除——`NodeBuilder`
  现在对外只交付冻结节点，环从公开 API 不可构造（见 `evolution/0003-review-hardening.md`）。
  同轮新增第 3–5 条（打印缓存回放越过深度上限、2MB 探针窗口、TypeDecoder store 路径 O(k²)）。

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

## 3. 打印缓存的完整 fragment 会回放到「本应截断」的深位置

`DemanglingPrinter` 的 fragment 缓存以节点身份为键，不含剩余深度。已有的截断防护
（`truncationCount` 检查）只挡「截断过的 fragment 入缓存」这一个方向；反方向缺口仍在：
浅处缓存的**完整** fragment，在深度逼近 `maxPrintDepth` 的位置命中缓存时被整段回放，
而无缓存的 walk 在同一位置会输出 `<<too complex>>`。后果有二：深度上限不再是单次输出
量的硬上界；同一棵树的输出依赖子树的遭遇顺序（与 C++ printer 的行为不一致，虽然每棵
树自身仍是确定性的）。

**影响面**：仅对抗构造可观测——需要共享子树 + 深度逼近 512 的路径；真实符号实测最深
41 层。回放的内容是该节点的真实完整渲染，所以是「输出过于完整」而非输出错误。

**修法方向**：fragment 记录自身渲染高度 `h`，命中时检查 `printDepth + h ≤ maxPrintDepth`，
不满足则走无缓存路径（该次不回放也不写缓存）。

## 4. 2MB inline 探针放行后，深度预算最坏可耗 5.9MB

`StackSafeExecutor` 在调用线程剩余栈 ≥ 2MB 时原地执行；而 `maxPrintDepth = 512` 按
全新 8MB 栈校准，unoptimized 下每层 `printName` 实测约 11.6KB，最坏 ≈ 5.9MB。窗口：
调用线程剩余 2–5.9MB **且** 符号单路径深度约 180–511 层时，探针放行、深度计数器又
来不及触发，直接 SIGSEGV。执行器文档自述「靠 limit 的 margin」，但 5.9 > 2，margin
在数学上不存在。（`main` 上更糟：旧上限 768 ≈ 8.9MB，连全新 8MB 线程都必爆；node-store
分支把上限降到 512 后只剩这个「半耗尽栈」窗口。）

**影响面**：需要 unoptimized 构建 + 深符号（>~180 层，真实最深 41）+ 半耗尽的调用线程
栈三者同时成立；release 构建帧远小于 11.6KB，窗口进一步收窄。

**修法方向**：入口按实际剩余栈折算本次生效的 `maxPrintDepth`（深符号提前
`<<too complex>>`，不增加跳线程频率，贴合上游形模型）；或把探针阈值提到 ≥ 6MB
（代价是主线程已用 >2MB 时更常跳线程）。

## 5. TypeDecoder store 路径每层重物化 decl 子树，O(k²)

`decodeMangledTypeDecl` 对走到的**每个**嵌套 decl 调 `materializedNode` 重建整棵子树
（`getUnspecialized` 也在物化结果上运行）；`NodeStore.materializeNode` 的 memo 只在单次
物化内有效，跨调用不缓存。嵌套 `k` 层的类型每层都重建自己的 context 链，合计 O(k²)。
实测：物化次数/解码比值 ≈ 0.56·k；深度 48 时 store 路径比 `Node` 路径慢 11.4×，且差距
随深度单调拉大。入口 API 的文档注释原先声称「不物化 `Node` 树」，已更正为如实描述。

**影响面**：仅 `NodeReference` 重载（PR 新增 API）；纯性能问题，非正确性。真实符号的
decl 嵌套深度通常在个位数，影响温和，但与该路径「零物化直读」的存在理由相悖。

**暂缓理由**：沿用上方 TypeDecoder 范围的暂缓决策。

**修法方向**：engine 内加 per-decode 的「store 索引 → 物化 `Node`」缓存；或让 decl
handoff 直接携带 `NodeReference`，把物化推迟到 `TypeBuilder` 真正需要处。
