# 0011 - transient demangle 入口转正为 public，并以测试固化 remangle 等价契约

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-08
- **最后更新**: 2026-08-08
- **所属愿景**: 无（隶属 `Evolutions/README.md` 愿景第 4 条「API 演进：稳定的公共面」）
- **关联提案**: [0001](0001-node-store-arena.md)（Phase 3 引入该入口）、[0005](0005-remangler-deepequals-memo.md)（替换表结构相等的 memo——本提案要守护的正是这层语义）、[0010](0010-appendable-shared-node-store.md)（同一轮下游排查的产物，彼此独立可先后落地）
- **实现分支 / PR**: `feature/node-store`（与本提案状态更新同一 commit）
- **配套文档**: 无独立文档——契约固化在入口 doc comment 与 `TransientRemangleParityTests`，README「Memory Management」节补充「何时选它」决策规则（判定见决策日志）

## 摘要

把 `demangleAsNodeTransient` 从 `@_spi(Internals)` 提升为普通 public：签名与行为
零变化，仅撤下 SPI 门并把 doc comment 改写为面向公开受众（非 canonical 契约、
禁止按 identity 键控、与 canonical 树的 remangle 等价保证）。同批补一条回归测试，
锁死「transient 树与 canonical 树的 `mangleAsString` 输出逐字节一致」——这层等价
目前成立但无任何东西守护，而下游已在生产路径上依赖它。

## 动机

### 「一次性 demangle」不是 bulk-indexing 独有的需求，SPI 门的前提已失效

`demangleAsNodeTransient` 现挂 `@_spi(Internals)`，doc comment 明写「for
bulk-indexing consumers (MachOSwiftSection's `SymbolIndexStore`)」
（`Sources/Demangling/Main/Demangle/DemangleInterface.swift:47`）。但 2026-08-08
的下游驻留排查落地后，事实是**两个下游仓库、五处调用**在用它，其中三类用途与
bulk-indexing 无关：

- RuntimeViewer `RuntimeRelationshipsResolver`（demangle → remangle 成键字符串
  → 树弃）与 `RuntimeEngine.objcReference(forSwiftMangledName:)`（demangle →
  取 identifier → 树弃）：单符号、用完即弃。RV 被迫写
  `@_spi(Internals) import Demangling`（两个文件）借道内部 SPI——普通
  `import Demangling` 下第一次编译就是 "cannot find in scope"；
- MachOSwiftSection `ObjCClassIndex` / `SpecializedMetadataNodeSubstitution`：
  同为一次性用途，同轮从缓存版 `demangleAsNode` 迁来。

背景：缓存版 `demangleAsNode` 把整棵树永久 intern 进不淘汰的全局 `NodeCache`，
一次性用途永久驻留——RV 五镜像实测存活 class `Node` 208,809 个，主要来源即
此类调用。「demangle 后立即取字符串、树不留」是逆向工具链的**常态形状**，不是
内部实现细节；让它借道 SPI 等于宣布公共 API 面覆盖不了本库的主要下游。

### remangle 等价契约在被依赖，却没有守卫

transient 树**非 canonical**（无叶 intern、部分实例经替换反向引用共享）。RV 的
「transient demangle → `mangleAsString` → 作键匹配 `makeRuntimeObject(forMangledTypeName:)`」
链条要成立，前提是 remangler 的替换表按**结构**而非**实例 identity** 匹配——
否则同一符号经 transient 树与 canonical 树会产出不同的 mangled 字符串，且不报错，
表现为 RV Relationships 面板里 Swift 桥接类静默消失。本轮已核实前提当前成立
（见前期调研），但库内**没有任何测试锁住它**：将来 Remangler 若把替换匹配改成
identity-keyed（例如为提速），全部现有测试照绿。这类「下游在生产路径依赖、
库侧无守卫」的隐式契约必须显式化。

## 前期调研

- **现状声明**：`DemangleInterface.swift:62-68` —— `@_spi(Internals) public func
  demangleAsNodeTransient(_:isType:symbolicReferenceResolver:) throws(DemanglingError) -> Node`，
  内部即 `demangleAsNodeFromMangledText(..., internsSubtrees: false, internsLeaves: false)`
  套 `StackSafeExecutor.execute`。行为已稳定（0001 Phase 3 起）。
- **替换表结构相等已两方独立核实**（RV 会话审计 + 本仓库复核，2026-08-08）：
  - 语义相等：`SubstitutionEntry.==`（`Remangler.swift:5866`）先比 `storedHash`
    （来自 `hashForNode` 的**结构**哈希）再走 `deepEquals` / `identifierEquals`
    ——纯结构；
  - `ObjectIdentifier` 仅出现在两处保语义的 memo 快路径：`nodePointerHash` /
    `matches(node:)`（`Remangler.swift:294,5855`）是「同实例复用已算的结构哈希」
    缓存，未命中就按结构重算、结果一致；`deepEquals` 内部的 proven-pair memo
    （0005）同理。
  - 结论：transient 树与 canonical 树 remangle 输出一致——**当前**成立。
- **SPI 与 public 的可见性关系**：符号转 public 后，`@_spi(Internals) import`
  照常可见——MachOSwiftSection 不需要任何改动；RV 删掉两处 `@_spi(Internals)`
  标记即可（其会话已确认无其他改动）。
- **async 重载需求已被真实调用方否定**：RV 实测单符号 demangle 微秒级，async
  上下文直接调 sync 版（栈富余时 inline，不构成 cooperative pool 阻塞问题），
  已删 await 落地。

## 提议方案

1. **撤 SPI 门**：`demangleAsNodeTransient` 去掉 `@_spi(Internals)`，签名、行为、
   `StackSafeExecutor` 路由零变化。
2. **doc comment 面向公开受众重写**，三条契约逐条写明：
   - 返回树非 canonical 亦非实例独立（`NodeFactory` 单例 + 替换反向引用共享），
     禁止按 `ObjectIdentifier` / `===` 键控（沿用现文案）；
   - 不触碰全局 `NodeCache`——一次性用途应选它而非 `demangleAsNode`，后者会
     永久驻留；
   - **remangle 等价保证**：同一符号的 transient 树与 canonical 树经
     `mangleAsString` 产出逐字节相同的结果（由本提案新增测试背书）。
3. **新增回归测试**（`TransientRemangleParityTests`）：
   - 定向集：0005 / 0006 的共享泛型 DAG 形状（替换表压力最大处）、含
     symbolic reference 的 metadata 名、punycode 标识符、`_Tt` 前缀——每例断言
     `mangleAsString(demangleAsNodeTransient(s)) == mangleAsString(demangleAsNode(s))`，
     进默认 `swift test`；
   - corpus 级：在既有 env-gated 全量对拍里加一条 transient remangle 腿
     （成本评估后若可忽略则并入默认 oracle，仿全量 oracle 无开关的先例）。

### 非目标

- **不加 async 重载**（真实调用方已否定需求；将来有高吞吐 async transient
  管线再议——加法向后兼容）；
- **不给 `demangleAsNode` 加 cachePolicy 参数**（见替代方案 1）；
- **不改 transient 树的语义**：非 canonical 契约维持原样，本提案只是把它写给
  公开受众。

## 详细设计

公开签名（与现 SPI 版逐字符一致，仅可见性变化）：

```swift
public func demangleAsNodeTransient(
    _ mangled: String,
    isType: Bool = false,
    symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil
) throws(DemanglingError) -> Node
```

测试骨架：

```swift
@Suite struct TransientRemangleParityTests {
    @Test(arguments: TransientRemangleParityTests.sharedSubstitutionHeavySymbols)
    func transientTreeRemanglesIdenticallyToCanonicalTree(symbol: String) throws {
        let transientMangled = try mangleAsString(demangleAsNodeTransient(symbol))
        let canonicalMangled = try mangleAsString(demangleAsNode(symbol))
        #expect(transientMangled == canonicalMangled)
    }
}
```

## 替代方案考量

1. **`demangleAsNode(_:isType:cache:)` 加 `DemangleCachePolicy` 枚举参数**——否。
   现入口已带 `internsSubtrees:` 参数，再叠一维参数组合出「intern 子树但不 intern
   叶」等无意义组态；两个入口按「树的语义不同」（canonical vs transient）分名，
   比一个入口按参数分叉更难用错。命名既有且下游已在用，转正成本最低。
2. **维持 SPI 现状，让 RV 继续 `@_spi(Internals) import`**——否。SPI 的含义是
   「实验期、不稳定、随时可破」，而该入口行为自 0001 Phase 3 起稳定、下游生产
   路径在用；名不副实的 SPI 门只会让每个新下游重撞一次 "cannot find in scope"。
3. **只补测试、不转 public**——否。测试解决第二个动机，解决不了第一个：需求
   已被证明不是 bulk-indexing 独有。
4. **把 remangle 等价写成 Remangler 内的 debug 断言而非测试**——否。断言只在
   有人恰好双路径 remangle 同一符号时触发，等于没有覆盖保证；corpus 级测试
   是确定性的。

## 影响

### 源码兼容性（source compatibility）

**纯新增**（可见性放宽）。既有 `@_spi(Internals) import` 调用方不受影响；普通
`import Demangling` 新获得该符号。无任何调用点需要修改。

### ABI 兼容性（条件项）

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

- **RuntimeViewer**：两个文件删掉 `@_spi(Internals)` 标记（其会话已确认）；
- **MachOSwiftSection**：零改动（SPI import 对 public 符号照常可见）；
- 本仓库内：`DemangleInterface.swift` 一处 + 新测试文件。

### 文档与示例

- 仓库根 `README.md`：public API 一览补 `demangleAsNodeTransient`（何时选它
  而非 `demangleAsNode` 的一句话决策规则）；
- `AGENTS.md`：Public API Entry Points 段同步；
- `Documentations/Glossary.md`：若「transient 树」尚未成词条则登记。

## API 演进与废弃策略

- 无被替代 API，无废弃；SPI → public 是单向放宽，无需 semver major。
- 一旦转正即承诺稳定性：将来若要收回只能走正式废弃周期——这正是本提案要
  用户明确批准的原因。

## 落地步骤

1. 撤 SPI 门 + doc comment 重写（构建即验证可见性）；
2. `TransientRemangleParityTests` 定向集（先于步骤 1 亦可独立落地——它守护的
   是现状）；corpus 腿成本评估后决定进默认还是 env-gated，结论记决策日志；
3. README / AGENTS.md / Glossary 同批；
4. 通知 RV 会话删 `@_spi(Internals)` 标记（其余零改动）。

**收尾判断**（写进决策日志）：配套文档——预计 README 一览级说明足够，无独立
指南（契约已在 doc comment 与测试内固化）；新术语——「transient 树」视 Glossary
现状决定。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-08 | Created as Draft | 起因：下游驻留排查（0010 同轮）落地后，RV 会话反馈两点——`demangleAsNodeTransient` 的 SPI 门迫使非 bulk-indexing 消费方借道 `@_spi(Internals) import`；其生产路径依赖的「transient 树 remangle 等价」无任何测试守护（当前成立，已两方独立核实替换表为结构相等）。 |
| 2026-08-08 | Draft → Accepted → In Progress | 维护者审核通过（与 0010 同批批准），随即开始实现。 |
| 2026-08-08 | In Progress → Implemented | 撤 SPI + doc comment 重写落地（`DemangleInterface.swift`）；`TransientRemangleParityTests` 定向集（7 组固定符号 + doubling DAG 生成符号 + symbolic reference 用例）进默认 `swift test`；全量 506 测试双路径绿（含 `DEMANGLING_FORCE_LEGACY_PATH=1` 重跑定向集）。**corpus 腿裁决：保持 env-gated**，与 0008 print-parity sweep 同族同开关（`DEMANGLING_PRINT_PARITY=1`），不并入默认 oracle——该腿每符号两次 demangle + 两次 remangle，且 canonical 侧把全 corpus 灌入 `NodeCache`；release 实测 47 秒 / 439,533 符号（remangle 可达 439,522，**mismatch 0**），成本不可忽略。**收尾判定**：配套文档——无独立指南，契约固化在 doc comment 与测试内，README「Memory Management」补「何时选它」决策规则；术语——「transient tree」已在 `Documentations/Glossary.md`，无需新增。测试期修正：定向集初版误用 `_TtC5AppKit10NSDocument`（`DualPathParityTests` 的**故意无效**符号，模块长度 5 对不上 6 字符的 "AppKit"），换为合法的 `_TtC6AppKit10NSDocument`。 |
| 2026-08-09 | PR #7 review F4 落地：corpus 腿的 `nil == nil` 盲区修复 + 一处历史记录勘误 | corpus 腿原实现两侧各自 `(try? demangle).flatMap { try? mangle }`，两侧双双失败时比较 `nil == nil` 恒真——对「两条路径同时回归」完全失明。改为比较带阶段与错误原因的完整结果（demangle 失败 / remangle 失败 / remangle 输出三态），demangle 失败另按 stdlib 裁判分类断言无回归。**勘误**：上一行「47 秒 / 439,533 符号（remangle 可达 439,522）」中 11 个的差值当年被理解为 remangle 不可达，重跑分类证实它们是 **demangle 失败**（stdlib 同样拒绝的符号表内容，非本库回归）；按惯例原记录保持原貌，以本行订正。重跑：0 mismatch（含失败原因一致）。 |
