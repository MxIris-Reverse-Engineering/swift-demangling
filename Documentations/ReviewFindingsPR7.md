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
| [F5](#f5) | `StoreBuffer.swift:129` | 空代跳过退休登记，已发布的描述符可指向已释放内存 | 是 | 应修 |
| [F6](#f6) | `StoreBuffer.swift:88` | `withBuffer` 的 range 读丢了 release 边界陷阱 | 是 | 应修 |
| [F7](#f7) | `NodeStoreBuilder.swift:473` | 整套内存安全论证依赖的不变量只用 `assert` 守，release 编译掉 | 是 | 应修 |
| [F8](#f8) | `StoreBuffer.swift:115` | `reserveCapacity` 精确扩容 + 退休链只增不减 = O(k²) | 是 | 应修 |
| [F9](#f9) | `Extensions.swift:5` | 前缀匹配改按字素簇比较，两个 public API 语义静默变化 | 是 | 应修 |
| [F10](#f10) | `NodeReference.swift:120` | `textUTF8` 签名不变但索引基从 store 绝对索引变 0 基 | 是 | 应修 |
| [F11](#f11) | `NodeStore+BufferView.swift:115` | legacy 文本物化分支没接进 seam，从未被任何配置执行过 | 是 | 应修 |
| [F12](#f12) | `DualPathParityTests.swift:46` | 翻进程级全局开关，并行套件被静默拽到 legacy 路径 | 是 | 应修 |
| [F13](#f13) | `SpanBorrowedViewsBenchmarks.swift:22` 等 3 处 | 三个 benchmark 套件测量窗口重叠，决策日志数字不可归因 | 是 | 应修 |
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

<a name="f5"></a>
## F5. 空代跳过退休登记 —— 已发布的描述符可以指向已释放的内存

- **位置**：`Sources/Demangling/Store/StoreBuffer.swift:127-136`
  ```swift
  private mutating func grow(to newCapacity: Int) {
      ...
      if count > 0 {          // ← 空代不进退休链
          ...
          retirementSink?(storage)
      }
  }
  ```

- **触发序列**：
  1. `SharedNodeStore()`；
  2. `reserveCapacity(10)` → edges 从 gen0 增长到 gen1，此时 `count == 0`，
     **gen1 没有进退休链**（gen0 侥幸存活，因为 `NodeStore.edgesStorage` 钉住的是
     **初代**）；随后 `publishCurrentState` 发布了一个 base 指向 gen1 的描述符；
  3. 某个读者在此窗口解析视图，于是它手里的 `BufferView` 记着
     `edges.baseAddress == gen1.base`；
  4. `reserveCapacity(500_000)` → gen1 增长到 gen2，**仍然 `count == 0`**，
     `retirementSink` 再次被跳过；`publishCurrentState` 覆写 `currentBuffers`，
     gen1 的最后一个引用消失 → `StoreBuffer.deinit` → `deallocate()`；
  5. 那个被钉住的描述符现在持有悬垂 base，`withSpans` 会在已释放内存上形成 `Span`。

- **为什么今天不崩**：`count == 0` 让所有边界检查先失败。但——
  - 这个理由论证的是**解引用**，而形成描述符和形成 `Span` 都不需要解引用；
  - `BufferView.text` 在一个对 `(0, 0)` 恒成立的 `precondition` 之后就计算
    `textBytes.baseAddress! + start`。

- **它与文档直接冲突**：`SharedNodeStore.swift:9-11` 写的是「any descriptor a reader
  ever obtained keeps addressing live memory for the store's whole lifetime」。
  这句话与当前实现二者只能留一个。

### 四问

1. **能复现吗**：触发序列如上，可构造。**不是误报**，但**今天是良性的**——需要极其明确
   地区分这两点。
2. **`main` 是否也有**：`SharedNodeStore` 是本 PR 新增。**本 PR 引入。**
3. **值不值得修**：**应修**。今天良性、明天不一定：任何让空代产生非零长度视图的改动
   （或 `BufferView` 新增一个不走边界检查的取址路径）都会把它变成真的 use-after-free。
   而它成本很低——去掉 `count > 0` 这个条件即可。
4. **以前修过吗**：**没修过，而且这是刻意设计，理由已留档**。
   - 0010 决策日志 2026-08-08 条目原文：「**空代直接释放**（count 0 的代不可能被任何
     已发引用寻址）」。
   - **这个理由今天是否仍成立**：结论（今天不崩）成立；**论证范围不成立**——它论证的是
     「不可能被寻址」，而风险在于「描述符与 `Span` 的**形成**」，二者不是一回事。
   - 所以本条不是「bug 重现」，是**一条已留档的设计决策与同一文件里另一句更强的承诺
     自相矛盾**。

- **修法方向**：二选一，**并把选择写进 0010 的决策日志**：
  - **方案 A（推荐）**：去掉 `count > 0` 条件，空代也进退休链。代价是极少量内存
    （空代本身没有数据），换取 `SharedNodeStore.swift:9-11` 那句承诺无条件成立。
  - **方案 B**：保留优化，但把 9-11 行的承诺改写为「仅覆盖非空代」，并在
    `BufferView` 所有取址路径上补上「空视图不得形成指针」的显式守卫。
  - 无论选哪个，都要补一个测试钉住「预留 → 发布 → 再预留」这个序列下描述符仍然有效。

<a name="f6"></a>
## F6. `withBuffer` 的 range 读丢了 release 边界陷阱

- **位置**：`Sources/Demangling/Store/StoreBuffer.swift:88`（`withBuffer` 交出裸
  `UnsafeBufferPointer`），四个调用点在 `NodeStoreBuilder.swift`：

  | 行 | 调用 |
  |---|---|
  | 592-593 | `manyChildrenNodeMatches`：`edgeBuffer[edgesStart ..< edgesStart + childIndices.count]` |
  | 642-645 | `resizeManyChildrenSlots` |
  | 684 | `textLocationMatches` |
  | 749 | `resizeTextSlots` |

- **现象**：`UnsafeBufferPointer` 的 **range 下标只有 `_debugPrecondition`**。这些位置
  在本 PR 之前是 `ContiguousArray` 切片，**release 下会 trap**；现在不会。

- **它与类型自己的文档冲突**：`StoreBuffer.swift:45` 写着「Reads are bounds-checked
  against the initialized count in every configuration, matching the ContiguousArray
  semantics this replaces: an out-of-range index traps deterministically instead of
  reading foreign memory, **in release too**」。这句话**只对 `subscript(index:)` 成立**，
  对每一个 range 读都不成立。

- **后果**：被污染的 `payloadWord0` 或 `TextLocation` 会读过初始化前缀，
  `elementsEqual` 拿未初始化的容量区做比较，**可能报告一个假的 interning 命中，从而把
  两棵不同的树永久别名到同一个 index**。这是静默的数据损坏，不是崩溃。

### 四问

1. **能复现吗**：需要先有一个被污染的 payload/location 才能触发，属于**二阶**问题。
   **不是误报**（语义倒退是确凿的），但触发它需要另一个 bug 先发生。
2. **`main` 是否也有**：`main` 上这些是 `ContiguousArray` 切片，**release 下会 trap**。
   **本 PR 引入的语义倒退。**
3. **值不值得修**：**应修**。理由不在「今天会不会踩」，而在「它把一个确定性 trap 换成了
   静默的树别名」——后者是这个库最难查的一类故障（interning 的全部正确性都建立在
   「结构相等 ⟺ 同一 index」上）。
4. **以前修过吗**：**没修过这一处，但风险在同一次迁移里被识别过、且只修了一半**。
   - `9997830`（引入 `StoreBuffer` 的那个 commit）的 message **自己就写了**：
     「Read-side bounds semantics preserved: explicit preconditions match the release
     trapping the array subscripts provided.」
   - 也就是说「从 `ContiguousArray` 换裸缓冲会丢掉 release 边界陷阱」这件事，作者
     **识别到了、写进 commit message 了、在读侧补上了**——builder 侧的这四处 range 读
     没补。读侧确实补了（`NodeStore+BufferView.swift` 的 46/66/107/151/192 五处
     `precondition`），对比之下 builder 侧的缺失更像遗漏而非决策。
   - 补充：同一个文件 `NodeStoreBuilder.swift` 在 `4ec46d8` 刚因为边界守卫问题修过
     一次（那个 commit 自称「同一文件第二次」）。

- **修法方向**：
  1. 给 `StoreBuffer` 加一个 range 版访问器，内部做 `precondition(range.upperBound <= count)`
     后再切片，四处调用点改用它；
  2. 或者在四个调用点各自补 `precondition`——但那样下一个调用点还会漏，不推荐；
  3. 修正 `StoreBuffer.swift:45` 的文档措辞，让它与实际保证一致。

<a name="f7"></a>
## F7. 内存安全论证依赖的不变量只用 `assert` 守，release 编译掉

- **位置**：`Sources/Demangling/Store/NodeStoreBuilder.swift:473`
  ```swift
  // ...The shared store's stale-view safety (step 4) rests on exactly this — a
  // published view that covers a root index covers the root's whole subtree, so a
  // reader pinned to an older view can never chase an edge past its view's bounds.
  assert(
      childIndices.allSatisfy { Int($0) < nodes.count },
      "interior node interned before one of its children — the bottom-up invariant is broken"
  )
  ```

- **现象**：注释就写明了「`SharedNodeStore` 的 stale-view 内存安全**完全依赖**这个
  不变量」，而 `assert` **在 release 里被编译掉**——release 正是发布配置。
  release 下唯一的残余强制是 `intern(kind:children:)` 里一个附带的 `precondition`
  （两个调用者之一）；`internInterior`、`appendNode`、`internManyChildren`
  ——**边真正被写入的那个咽喉**——什么都不检查。

- **后果**：任何未来的插入路径（批量 intern 快路径、延迟补子节点方案、mmap 反序列化器）
  都能编译通过、debug 测试全绿，同时把「读到陈旧视图」变成「在已退休的代上越界读」。

- **一致性问题**：本 PR 其它每一处内存安全边界都用 `precondition`
  （`StoreBuffer.swift:81`、`NodeStoreBuilder.swift:178`、
  `NodeStore+BufferView.swift` 的 46/66/107/151/192），唯独这一处不是。而 many-children
  路径本来就要遍历 `childIndices`，改成 `precondition` 几乎零成本。

### 四问

1. **能复现吗**：当前代码路径下不可复现（不变量确实成立）。**不是误报，但它是一个
   「护栏缺失」而非「当前有 bug」**——必须如实这样描述。
2. **`main` 是否也有**：`main` 上没有 `SharedNodeStore`，也没有这个 assert。
   **本 PR 引入。**
3. **值不值得修**：**应修**。成本极低（`assert` → `precondition`），收益是让一个
   「内存安全论证的基石」在发布配置里真的成立。
4. **以前修过吗**：**没修过，但这是同一个文件在七天内第二次踩「守卫在 release 下失效」**。
   - **谁引入的**：`1adf202`（2026-08-08），这个 commit 的**全部内容**就是
     「pin the bottom-up child-before-parent invariant (evolution 0010, step 2)」。
   - **当时为什么用 `assert`**：验收写的是「full-corpus store sweep **in debug** with
     the assertion live — zero triggers」。也就是说作者把它当作**一次性验证工具**用
     （跑一遍 debug 语料证明不变量成立），而不是当作运行时护栏。这个动机是合理的，
     但它没有覆盖「以后新增插入路径」这个场景，而 commit 自己的注释恰恰声称它守护的是
     step 4 的内存安全。
   - **时间线**：2026-08-02（`4ec46d8`）刚把**同一个文件**的守卫改成 release 生效的
     `precondition`，2026-08-08（`1adf202`）新加的安全不变量又用了 debug-only 的
     `assert`。

- **修法方向**：
  1. `assert` → `precondition`，并**下沉到边真正写入的那个咽喉**（`internManyChildren`
     写 edge 的位置），而不是留在 `internInterior`；
  2. 顺手让另外两个入口（`appendNode`、`internInterior`）也走同一个检查；
  3. 在 0010 的决策日志里记一行：这个不变量的强制点在哪、为什么必须是 `precondition`。

<a name="f8"></a>
## F8. `reserveCapacity` 精确扩容 + 退休链只增不减 = O(k²) 内存

- **位置**：`Sources/Demangling/Store/StoreBuffer.swift:115-123`
  ```swift
  mutating func reserveCapacity(_ minimumCapacity: Int) {
      ... grow(to: minimumCapacity)        // ← 精确尺寸，不翻倍
  }
  mutating func ensureCapacity(_ requiredCapacity: Int) {
      ... grow(to: Swift.max(requiredCapacity, capacity * 2, 16))   // ← 这条才翻倍
  }
  ```

- **现象**：在 `SharedNodeStore` 上，每次 `reserveCapacity` 都退休掉上一次的完整预留，
  而退休链**只增不减**（整个 store 生命周期内不释放）。

- **已实测**（PR tip）：首次 intern 之后连续八次递增的
  `SharedNodeStore.reserveCapacity(expectedSymbolCount:)`，
  `retiredBufferCountForTesting` 依次为 **2, 4, 6, 8, 10, 12, 14, 16**。
  每一代退休的都是上一次的完整预留。

- **谁会踩**：按镜像逐个细化估算的索引器（10k → 20k → 30k …）。
  而 `reserveCapacity` 的文档明确写着「Callable at any point」——**增量负载正是这个类
  存在的理由**。

- **它与文档冲突**：`SharedNodeStore.swift:31-34` 写「Bounded by the doubling growth
  policy at less than one current-buffer's worth of bytes」。这个界**只对 `ensureCapacity`
  成立**，对 `reserveCapacity` 的 `grow(to: minimumCapacity)` 不成立。

### 四问

1. **能复现吗**：能，已实测（退休链 2→16）。**不是误报**。
2. **`main` 是否也有**：`main` 没有 `SharedNodeStore`，也没有退休链。**本 PR 引入。**
3. **值不值得修**：**应修**。它不会崩，只会让长跑索引器的内存缓慢膨胀——这类问题在
   下游（`MachOSwiftSection` / RuntimeViewer 的批量索引）最难归因。
4. **以前修过吗**：**没修过，是两个正确决策叠加出的新问题**。
   - `99100c3`（0009）引入 `reserveCapacity`，验收数据**全部来自一次性预留**场景
     （原文「>=1MiB allocation events 12 -> 4；the 4 are the reservations themselves」）
     ——**反复预留从来没测过**；
   - `9997830`（0010 步骤 1）换底层存储时，还把「精确尺寸分配」当作**优点**记进了决策
     日志（「nodes reservation utilization 73% → 96% from exact-size allocation」）；
   - `60afea0`（0010 步骤 4）加了退休链。
   - 三者各自都对，叠起来才是 O(k²)。而现存的
     `SharedNodeStoreTests.reservationKeepsTheRetirementChainEmpty` 只覆盖
     「任何 intern 之前预留一次」——**恰好是退休链保持为空的那唯一一种配置**。

- **修法方向**：
  1. `reserveCapacity` 也走翻倍下界：`grow(to: max(minimumCapacity, capacity * 2))`；
     或者在已有容量足够时直接跳过（`minimumCapacity <= capacity` 时 no-op）；
  2. 或者让退休链可回收（引用计数 / 代际水位），但这明显更复杂，不推荐作为首选；
  3. 修正 `SharedNodeStore.swift:31-34` 的界的措辞；
  4. **测试要覆盖「反复预留」**，不能只测「预留一次」——现有测试的配置选择本身就是盲点。

<a name="f9"></a>
## F9. 前缀匹配改按字素簇比较，两个 public API 语义静默变化

- **位置**：`Sources/Demangling/Utils/Extensions.swift:4-14`
  ```swift
  func getManglingPrefixLength(_ mangled: some StringProtocol) -> Int {
      if mangled.hasPrefix("_T0") || ... // ← String.hasPrefix：按字素簇 + 规范等价
  }
  ```
  影响 `Extensions.swift:17-24` 的两个 public 成员：`isSwiftSymbol`、`stripManglePrefix`。

- **现象**：`String.hasPrefix` 按**字素簇**比较并遵守**规范等价**；原来的
  `Demangler.getManglingPrefixLength` 走 `ScalarScanner.conditional(string:)`，其文档
  明确写着「purely based on direct scalar comparison (no decomposition or normalization)」。

- **A/B 已验证**，输入 `"$s" + U+0301 + "4main4testyyF"`（U+0301 是组合重音符）：
  | | merge-base | PR tip |
  |---|---|---|
  | `isSwiftSymbol` | `true` | **`false`** |
  | `stripManglePrefix` | 去掉前缀 | **原样返回** |
  | `demangleAsNode` 路由 | `demangleSymbol()`，报 `matchFailed("(read test function to succeed)", at: 2)` | **走 `demangleSwift3TopLevelSymbol()`**（`DemangleInterface.swift:149` 的 else 分支），报 `matchFailed(wanted: "_T", at: 0)` |

- **附带的内部不一致**：字节扫描器自己的 `conditional(string:)` 仍然是逐字节匹配。
  于是**入口和扫描器现在对「什么算前缀」的定义不一致**。

### 四问

1. **能复现吗**：能，见上表。**不是误报**，但**只影响非 ASCII（因而必然非法）的输入**。
2. **`main` 是否也有**：`main` 是 scalar 比较。**本 PR 引入的语义变化。**
3. **值不值得修**：**应修，但优先级低于前面几条**。合法 mangled 符号全是 ASCII，所以
   实际影响面窄；值得修的理由是「public API 行为未经宣告地变了」+「入口与扫描器定义
   不一致」，而不是「会出错」。
4. **以前修过吗**：**没修过。是有意改动，但影响评估漏了一维。**
   - **谁改的**：`ec3769a`。
   - **当时怎么论证的**：0008 提案有专门一节「**源兼容已核实**」讨论了这个函数，原文
     是「`getManglingPrefixLength` 只被同模块的 String 扩展调用。改具体类型不破任何
     公共 API」。
   - **这个论证的盲区**：它论证的是**编译期源兼容**（谁调用它、签名变不变），没有论证
     **运行时行为兼容**（它那两个 public 调用者的**行为**会不会变）。
   - **更能说明问题的一点**：同一节还有一个小标题就叫「**行为差异，明示**」，里面只列了
     「错误偏移从 scalar 计数变字节偏移」一条——提案自己**设了这个格子，却没把前缀匹配
     语义填进去**。

- **修法方向**：
  1. 改回按 scalar（或直接按 UTF-8 字节）比较，与扫描器的 `conditional(string:)` 对齐——
     推荐这条，因为它同时消除了入口与扫描器的定义分歧；
  2. 补一个测试钉住非 ASCII 输入下的前缀判定；
  3. 在 0008 提案的「行为差异，明示」一节补记这一条（**即使改回去也要补**——记录的是
     「当时漏了什么」，这正是决策日志的价值）。

<a name="f10"></a>
## F10. `textUTF8` 签名不变，索引基从 store 绝对索引变成 0 基

- **位置**：`Sources/Demangling/Store/NodeReference.swift:120`
  ```swift
  public var textUTF8: ArraySlice<UInt8>? { ... }
  ```

- **现象**：签名一个字符没变（还是 `ArraySlice<UInt8>?`），但语义变了两处：
  | | merge-base | PR tip |
  |---|---|---|
  | 实现 | 零拷贝切片，索引是 **store 绝对索引** | 新分配的 0 基数组，逐字节 `append` 填充 |
  | 实测（先 intern `"AAAAAAAA"` 再 `"BBBB"`，读第二个节点） | `startIndex=8, endIndex=12` | **`startIndex=0, endIndex=4`** |

- **两个后果**：
  1. 任何把切片索引与 store 字符串表关联的下游代码（`store.textBytesSpan()[slice.startIndex]`、
     按 `startIndex` 排序条目）**语义静默改变**，且**没有一个调用点会编译失败**；
  2. 每次访问现在都分配 + 逐字节 `append`（每字节一次唯一性检查 + 容量检查），
     而以前零分配。本 PR 已经把所有内部调用者迁到 span 上，所以**这个成本 100% 落在
     外部消费方头上**。

### 四问

1. **能复现吗**：能，已实测（8..12 → 0..4）。**不是误报**。
2. **`main` 是否也有**：`main` 是零拷贝绝对索引。**本 PR 引入。**
3. **值不值得修**：**应修**。这是一个「无声的下游破坏」——签名不变、编译通过、行为改变，
   属于最难被下游发现的一类。考虑到下游（`MachOSwiftSection` 等）正在用 store API，
   要么修，要么至少显式宣告。
4. **以前修过吗**：**没修过。同 F9 一个形态：有意改动，影响评估漏了一维。**
   - **谁改的**：`9997830`。
   - **commit message 原文**：「NodeReference.textUTF8 becomes a copying bridge
     (borrowed forms stay zero-copy)」——**承认了拷贝，没提索引基**。
   - 文档注释同样只写了拷贝，没写索引重基。
   - **没有任何测试钉住索引基**：`NodeStoreTests.swift:307` 和
     `BorrowedTextViewTests.swift:38` 都用 `Array(...)` 做了归一化，正好把这个差异抹掉。

- **修法方向**（三选一，需要决策）：
  - **A**：保持绝对索引语义（返回真正的切片视图），恢复源兼容；
  - **B**：接受 0 基，但**改签名**（例如改名或改返回类型），让下游编译失败而不是静默改变；
  - **C**：接受 0 基并保持签名，但在文档、`README`、0010 决策日志里显式宣告为破坏性变更。
  - 无论哪个，都要**补一个钉住索引基的测试**（不要用 `Array(...)` 归一化）。

<a name="f11"></a>
## F11. legacy 文本物化分支从未被任何配置执行过

- **位置**：`Sources/Demangling/Store/NodeStore+BufferView.swift:104-115`
  和 `DemanglerRuntimeSelection.swift` 的 `TextMaterializationStrategy.materialize`

- **现象**：`DEMANGLING_FORCE_LEGACY_PATH` 这个 seam **只切 demangler 侧**
  （输入借用方式 + 词表存储）。store 侧的文本物化只看 `#available`：
  ```swift
  return String(copying: UTF8Span(unchecked: textBuffer.span))   // :115，macOS 26+
  ```
  在 macOS 26 的开发/CI 机器上，**两次运行都走这一支**，
  `String(decoding: textBuffer, as: UTF8.self)` 这条「所有 26 之前的部署目标实际会执行的」
  分支**从来没有被执行过**。

- **纪律与现实的落差**：`StorePrintParitySweep.swift:14` 和 `SharedNodeStoreTests` 都把
  `DEMANGLING_FORCE_LEGACY_PATH=1 swift test -c release --filter ...` 记载为「覆盖
  legacy 路径的那一跑」。实际覆盖范围严格小于文档所述。

- **同一位置的第二个问题**：`BufferView.text` 用 `UTF8Span(unchecked:)`
  **完全没有有效性闸门**。而 demangler 侧专门为此建了 `TextMaterializationStrategy`
  并加了 `isKnownASCII` 门（0008 决策日志「偏差①」明确说：字节子区间可能切开非 ASCII
  scalar，`UTF8Span(unchecked:)` 会伪造非法 `String`）。于是 release 下一个来自其它
  store 的 `NodeIndex`（`reference(at:)` 的文档说这种情况「silently wrong, but
  well-formed」）可以在这里**伪造出带非法 UTF-8 的 String**——这是那句文档没有点名的
  第三种未定义行为形态。

### 四问

1. **能复现吗**：覆盖缺口可直接验证（两条运行路径在 macOS 26 上取同一分支）。
   `UTF8Span(unchecked:)` 的伪造需要先有一个错误 index，属**二阶**。**不是误报**。
2. **`main` 是否也有**：seam 由 `ec3769a` 建立（本 PR 内）。**本 PR 引入。**
3. **值不值得修**：**应修**。这个库声明支持 macOS 10.15+，legacy 分支是**绝大多数部署
   目标实际执行的代码**，而它一次都没跑过。
4. **以前修过吗**：**没修过。是范围缺口，非回归。**
   - seam 由 `ec3769a` 建立时，覆盖范围就只含 demangler 侧（0008 提案的「axis-1 选择」
     一节列的三项——输入借用、文本物化、词表——里，「文本物化」指的是 **demangler 的**
     文本物化）；
   - `4ed790e` 引入 store 侧 `#available` 文本物化分支时，**没有把它接进 seam**。

- **修法方向**：
  1. 让 store 侧的物化也走 seam（`forcesLegacyPath` 为真时强制走 `String(decoding:)`）；
  2. 给 `BufferView.text` 补上与 demangler 侧同等的有效性闸门（`isKnownASCII` 或
     校验解码）；
  3. 修正 `StorePrintParitySweep.swift:14` 与 `SharedNodeStoreTests` 里关于双跑覆盖范围
     的注释——它们现在说的比实际做的多；
  4. 元模式那句话在这里的答案：双跑纪律对「没有接进 seam 的分支」是瞎的。所以还需要一条
     元测试或清单，枚举所有 `#available` 分支并断言每条都有 seam 覆盖。

<a name="f12"></a>
## F12. 翻进程级全局开关，并行套件被静默拽到 legacy 路径

- **位置**：`Tests/DemanglingTests/DualPathParityTests.swift:44-47`
  ```swift
  let originalSeamValue = DemanglingRuntimePath.forcesLegacyPath
  DemanglingRuntimePath.forcesLegacyPath = true
  defer { DemanglingRuntimePath.forcesLegacyPath = originalSeamValue }
  ```
  套件声明在 `:14`：`@Suite("0008 dual-path parity", .serialized)`

- **现象**：`swift test` **默认并行跑各个套件**，而 `.serialized` **只排序本套件内部的
  测试**。当 `assertParity` 持有 seam 为真的这段时间里，
  `BorrowedTextViewTests`、`SharedNodeStoreTests`、`TransientRemangleParityTests`、
  `NodeStoreTests`（以及 `DEMANGLING_BENCHMARK=1` 下的三个 benchmark 套件）
  **全部走的是 legacy 分支**，而不是它们以为自己在测的现代分支。

- **两个后果**：
  1. 现代路径的覆盖**非确定性地丢失**——恰恰是这个 seam 存在的目的被反转了；
  2. 任何真实的分歧会表现为**某个不相关套件的偶发失败**，而且 `--filter` 单跑时
     **必然复现不出来**。

- **明确不是什么**：**不是数据竞争**（seam 由 `Mutex` 保护）。缺陷在于「进程级全局模式
  没有作用域」。

### 四问

1. **能复现吗**：机制确凿；表现为偶发。**不是误报**。
2. **`main` 是否也有**：`DualPathParityTests` 由 `ec3769a` 引入（本 PR 内）。
   **本 PR 引入。**
3. **值不值得修**：**应修**。它污染的是**其它所有套件的可信度**——本轮「520 全绿」的
   含金量直接受它影响。
4. **以前修过吗**：**修过一次，只修了一半。这是同一根因的第二次露头。**
   - **前科**：`4d08c9a` 的 commit message 原文——「DualPathParityTests no longer
     preconditions the seam clean: under a CI double-run
     (`DEMANGLING_FORCE_LEGACY_PATH=1`) the flag is legitimately set process-wide and
     **the old assertion trapped the whole test process**; the seam is now snapshotted
     and restored」。
   - **当时的修法**：快照 + 恢复。
   - **只修了哪一半**：处理了「**本套件被外部设置影响**」这个方向（别人设了 seam，
     我不要断言失败）；**没有处理「本套件影响其它并行套件」**这个方向。
   - 也就是说，这个进程级全局开关已经因为「作用域」问题出过一次事故，当时的修复没有
     触及作用域本身。

- **修法方向**（按推荐顺序）：
  1. 把 seam 从进程全局改成 **task-local** 或显式参数传递的策略——这是唯一真正消除
     根因的做法；
  2. 退而求其次：让所有 demangling 相关套件共享同一把锁；
  3. 最低限度：`--no-parallel`（但这会拖慢整个套件，且靠约定维持，容易失效）。

<a name="f13"></a>
## F13. 三个 benchmark 套件的测量窗口重叠，决策日志的数字不可归因

- **位置**：
  | 文件:行 | 套件 |
  |---|---|
  | `SpanBorrowedViewsBenchmarks.swift:22` | `@Suite(.enabled(if: ...DEMANGLING_BENCHMARK == "1"), .serialized)` |
  | `SharedNodeStoreBenchmarks.swift:26` | 同一个 gate |
  | `NodeStoreReservationBenchmarks.swift:33` | 同一个 gate |

- **现象**：三个套件共用一个 `DEMANGLING_BENCHMARK=1` 开关，`.serialized` 只排序**套件
  内部**，于是三者**并行交错**。而 `MallocCounter.swift:9-11` 自己写着：

  > a measurement window is only attributable when the workload under measurement is
  > the sole activity in the process. **Windows must not overlap.**

  交错的后果：套件 B 的 `start()` 把套件 A 的计数器清零；B 的 `stop()` 在 A 还在计时时
  卸载了 hook；两个并发的 `PhysicalFootprintSampler` 各自把对方的峰值算成自己的。

- **同一区域的另外两处污染**：
  1. `NodeStoreReservationBenchmarks.swift:77-78` 在 malloc 窗口**内部**启动采样线程
     （Thread + 栈 + NSLock 上下文都被计入），并且先停计数器（:97）后停采样器（:99）；
  2. `CMallocCounter.c:55/59` **覆写进程全局 `malloc_logger` 且不保存原值**，退出时写 0
     而非恢复——**此后整个进程的 MallocStackLogging / Instruments / `leaks` 全部失效**。
     另外这个全局写是非原子的，与其它线程的分配存在竞争（TSan 会报）。

### 四问

1. **能复现吗**：机制确凿（三个套件同一 gate、`.serialized` 语义明确）。**不是误报**。
2. **`main` 是否也有**：`main` 上没有这些 benchmark。**本 PR 引入。**
3. **值不值得修**：**应修，但它的性质与其它条不同**——它不影响产品代码的正确性，影响的是
   **0009 / 0010 决策日志里那些分配与 footprint 数字的可信度**。也就是说，它动摇的是
   「这个 PR 的性能主张」的证据基础，而不是运行时行为。`malloc_logger` 不恢复那一条
   独立于此，应当单独修（它会坑到任何在同进程里后续做内存诊断的人）。
4. **以前修过吗**：**没修过，但纪律是本项目自己定的，而且这类坑已经吃过亏。**
   - 「窗口不得重叠」这条纪律写于 `6874f6f`——**引入 `MallocCounter` 的同一个 commit**，
     当时只有一组 benchmark（0008 Phase 0 的三个测量在一个套件里）；
   - `e2d885c` 的 `MeasurementToolbox.md` 专门收录了「pitfalls that **have produced
     wrong numbers before**」（事件数看不见拷贝成本、同进程第二遍量不到 footprint 尖峰、
     机器不空闲计时作废）——说明**测量污染这一类以前就实际产生过错误数字**；
   - 套件从一组长到三组（`99100c3` 加了 reservation、`bb1f81c` 加了 shared store）时，
     **没有人重新检查这条重叠约束**。
   - `malloc_logger` 不保存不恢复：引入即有，无前科。

- **修法方向**：
  1. 给三个 benchmark 套件一把共享的全局互斥（或各自独立的 env gate，一次只跑一个）；
  2. `NodeStoreReservationBenchmarks`：把采样线程的启动挪到 malloc 窗口之外，并把
     停止顺序改为「先采样器后计数器」；
  3. `CMallocCounter.c`：保存原 `malloc_logger` 并在卸载时恢复；全局写改为原子；
  4. **重跑并订正 0009 / 0010 决策日志里受影响的数字**——如果重测结果与已记录的不同，
     按项目惯例**如实记录差异，不要回头改提案让它符合新数字**；
  5. 在 `MeasurementToolbox.md` 补一条：新增 benchmark 套件时必须检查窗口互斥。

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

**第 2 步 —— 内存安全与存储**

6. **F5**（空代退休）、**F7**（`assert` → `precondition`）、**F6**（range 读边界）：
   这三条同属「护栏」，一批做完，同时订正各自冲突的文档措辞。
7. **F8**（`reserveCapacity` O(k²)）：修扩容策略 + 补「反复预留」测试。

**第 3 步 —— 公开 API 语义**

8. **F9**（前缀匹配）、**F10**（`textUTF8` 索引基）：F10 需要**先做决策**（保持语义 /
   改签名 / 宣告破坏性变更），建议先问维护者再动手。

**第 4 步 —— 测试与测量基础设施**

9. **F12**（并行污染 seam）、**F11**（legacy 分支接进 seam）、**F13**（benchmark 窗口 +
   `malloc_logger` 恢复）。F13 完成后需要**重测并订正 0009 / 0010 决策日志里的数字**。

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
