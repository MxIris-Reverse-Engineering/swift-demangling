# 递归、线程栈与崩溃

> 概念篇。读完你会知道：栈为什么会爆、为什么 debug 构建比 release 更容易爆、深度上限
> 是什么、trap 和 SIGSEGV 有什么区别，以及本库为什么要把工作搬到另一条线程上跑。
> 前置：无（与其它概念篇正交）。

## 1. 栈是什么，为什么会爆

每次函数调用，运行时都要在**线程栈**上划一块空间存这次调用的局部变量、参数、返回地址，
这块空间叫**栈帧**（stack frame）。函数返回时栈帧弹掉。

递归函数每深入一层就多压一个栈帧。栈的总量是**固定的**，压满了就是**栈溢出**——程序
不会抛异常，而是直接被系统杀掉（SIGSEGV / SIGBUS）。

```
线程栈（比如 512 KB）
┌──────────────────────┐
│ printName 第 1 层     │ ← 每层约 11.6 KB（debug 构建实测）
│ printName 第 2 层     │
│ printName 第 3 层     │
│ ...                  │
│ printName 第 44 层    │
└──────────────────────┘  ← 满了，下一层 → 崩溃
```

本库有三个递归引擎：`NodePrinter`（打印）、`Remangler`（重新编码）、`TypeDecoder`
（构造类型）。一个嵌套很深的类型（`Int` 套 700 层 `Optional`）会让它们递归很深。

## 2. 线程栈有多大

这里有个很多人不知道的事实：**不同线程的栈大小差很多**。

| 线程 | 栈大小 |
|---|---|
| 主线程（macOS） | **8 MB** |
| Swift 并发的协作线程池 worker | **512 KB** |
| dispatch 队列的线程 | 512 KB |
| `Thread` 手动创建 | 默认 512 KB，可设置 |

也就是说：**同一段代码，在主线程上跑得好好的，挪到 `Task { }` 里就可能崩**——栈只有
1/16。这不是本库特有的问题，是 Darwin 平台的通用陷阱，但对一个「递归遍历用户输入构造
的树」的库来说格外要命。

## 3. debug 构建为什么更容易爆

同一个递归函数，**未优化（debug）构建的栈帧比优化（release）构建大一个数量级**。

原因大致是：优化器会把局部变量放进寄存器、复用栈空间、内联小函数、消除尾调用；未优化
构建则老老实实给每个变量、每个临时值都在栈上留位置，方便调试器观察。

实测（8 MB 线程、debug 构建）：

| 引擎 | 每层栈消耗 | 崩溃边界 |
|---|---|---|
| printer | ≈ 11.6 KB | 725 层能过 / 745 层崩 |
| remangler | — | 深度 565 过 / 605 崩 |
| TypeDecoder | ≈ 30 KB（每深度单位） | 约 250 层 |

**为什么这对本库是个问题**：上游 Swift 编译器的 demangling 代码永远是 release 构建
（它是编译器/运行时的一部分），而本库是给别人用的库——**下游会用 debug 配置编译它**。
同一套常数，在两种构建下的安全边界差了十倍。

## 4. 深度上限：优雅退化而不是崩溃

三个引擎各自带一个**固定深度上限**，递归到上限就停下来返回一个「太复杂」的结果：

```swift
node.print(using: .default)   // 超限 → 输出里出现 "<<too complex>>"，不崩溃
try mangleAsString(node)      // 超限 → 抛 ManglingError
```

现行取值与上游 Swift 编译器完全相同：

| 引擎 | 上限 |
|---|---|
| `DemanglingPrinter.maxPrintDepth` | 768 |
| `Remangler.maxDepth` | 1024 |
| `TypeDecoderEngine.maxDepth` | 1024 |

**为什么用固定常数，而不是「每层探测一下还剩多少栈」**：本库试过后者（按剩余栈字节做
每层探针），结论是撤回——它会让主线程也被迫跳线程，从而**卡死 LLDB 的 `po`**（调试器
求值默认只调度当前线程），还会造成优先级反转，而且「栈够用」并不等于「工作量有界」：
一个 3.2 万层的构造符号，靠栈耗尽来拒绝要烧 9.5 分钟 CPU，靠深度检查 0.1 秒就拒了。
**深度上限同时是资源上限，探测栈不是。**

### ⚠️ 一个尚未解决的矛盾

768 层 × 11.6 KB ≈ **8.9 MB** —— 比一整条 8 MB 线程还大。也就是说 debug 构建下，
**上限还没轮到生效，栈就先崩了**。

这个矛盾是知情的：曾经把上限下调到 512 / 384 / 160（按 debug 实测校准），但下游报告
普通的 SwiftUI 模块在 512 的打印上限下会输出 `<<too complex>>`——**下调不是削掉理论
能力，是在截断本该正确的输出**，于是全部回退。

结论写在 `KnownIssues.md` 第 4 条：这是一个栈安全问题，要当作栈安全问题解决（提高
门槛、或按实际剩余栈折算本次生效的上限），不能靠静默截断 release 构建能正常渲染的
输出来换。**没有下游语料证据之前，不要再动这三个常数。**

## 5. trap 和 SIGSEGV 不是一回事

排查崩溃时先分清这两类，方向完全不同：

| | trap（SIGTRAP） | SIGSEGV / SIGBUS |
|---|---|---|
| 是什么 | 程序**主动**中止：`precondition` 失败、数组越界、整数转换越界 | **非法内存访问**：栈耗尽、野指针 |
| 性质 | 可预期的拒绝——是代码里写着的检查生效了 | 失控 |
| 例子 | `Int(someUInt64)` 在值 > `Int.max` 时终止进程 | 递归太深，栈压满 |

本库里两类都有真实案例：

- **trap**：`KnownIssues.md` 第 1 条那 8 处整数转换。一个构造的符号
  `$s$9223372036854775807_D` 能**成功** demangle，然后在 `TypeDecoder` 里把进程打死——
  因为 mangling 的十进制扫描器跟随上游，对畸形输入允许溢出，于是任意 `UInt64` 都能
  进到节点树里。
- **SIGSEGV**：第 3 节那些崩溃边界。

顺带一个 32 位平台的坑（`evolution/0004`）：**永远不要把边界检查写成 `Int(UInt32.max)`**。
watchOS 上 `Int` 是 32 位，这个转换在**常量折叠阶段**就溢出，编译器会把整个函数缩减成
一条无条件 trap，而构建全绿、没有任何警告。要写成异构比较 `count <= UInt32.max`。
这条已由源码扫描测试守着。

## 6. `StackSafeExecutor`：不够就换条线程跑

本库的做法照搬 Swift 项目自己的模型：**在任务边界上安排一条大栈线程，引擎里用固定
深度上限**。

```
调用线程剩余栈 ≥ 2 MB  →  就地跑
                          （主线程、你自己建的大栈线程、LLDB 里的 po——零开销）

调用线程剩余栈 < 2 MB  →  搬到一条 8 MB 栈的常驻 worker 上跑
                          （512 KB 的协作线程、dispatch 线程走这条）
```

几个设计细节值得知道：

- **worker 是池化的、常驻的**。每次新建线程约 41 µs，23 万个符号就是 10 秒纯开销；
  池化后 `demangleAsNode` 的单次耗时从 46.73 µs 降到 12.48 µs。
- **批量场景应该在外层包一次**，让整批只付一次线程切换：

  ```swift
  StackSafeExecutor.withLargeStack {
      for symbol in allSymbols { ... }   // 作用域内全部内联，零往返
  }
  ```

- **Swift 并发环境用 `async` 重载**（`await node.print(using:)`）：需要换线程时它
  **挂起 task**，而不是阻塞一条协作线程池的 worker（后者会拖累整个线程池）。
- **`TypeDecoder` 故意不跳线程**：它调用的是**你的**代码（`TypeBuilder` 回调），可能
  绑定在某个 actor 或特定线程上。把它搬到后台线程会在一个看起来同步的调用背后偷偷换
  线程。所以契约是「回调永远在调用者线程」，深批量请自己包 `withLargeStack`。
- **`Node.description` 也不跳线程**：它是迭代实现、不可能爆栈，而且它正是调试器 `po`
  走的路——包一层只会把 `po` 变成挂死。

非 Darwin 平台没有执行器，只有深度上限。

## 7. 引擎之外的遍历：必须写成迭代

深度上限只能保护**经过引擎入口**的调用。有一类遍历永远绕过它：

`NodeCache.internTree`、`Node.==` / `hash(into:)`、`Node.copy()`、`Node.Rewriter`、
`Node.description` 的转储、`NodeStore.materializeNode`、`NodeReference.structurallyEquals`……

这些是公开 API，输入可能是调用方手工拼装的树，而且不在任何引擎的守卫之内。**它们一律
写成迭代（显式栈），不允许递归。**

最能说明问题的是**析构**：

> 释放一棵引用类型的树，本身就是递归——由运行时执行，发生在最后一个引用消失的地方。
> 任何引擎侧的护栏都覆盖不到它，崩溃时栈顶甚至没有本库的帧，几乎必然被误判成别的问题。
> 实测 512 KB 线程上 620 层就崩。

所以 `Node.deinit` 把 children 摘进一个显式工作队列逐个排空，只拆解唯一引用的节点。

**新增递归时的规矩**：要么收敛到一个带深度检查的入口，要么写成迭代。不能想当然——
remangler 就有过一个结构性绕过：`hashForNode` ↔ `entryForNode` 这对互递归在
`mangle(_:depth:)` 的计数器**之外**，第一次替换查询就把整棵子树走完了，上限形同虚设
（上游 C++ 有完全相同的洞）。验证方法是做调用图审计：把候选的收敛点删掉，看还有没有环。

## 在本库的哪里

- `Utils/StackSafeExecutor.swift` — 2 MB 门槛、8 MB worker 池、`withLargeStack`
- `Node/Printer/NodePrinter.swift` — `maxPrintDepth` 与 `<<too complex>>`
- `Main/Remangle/Remangler.swift` — `maxDepth`，以及迭代化后的 `hashForNode`
- `Node/Node.swift` — `deinit` 的迭代式析构
- `Tests/DemanglingTests/StackSafetyTests.swift`、`LargeStackThreadPoolTests.swift`

完整记录：[../StackSafety.md](../StackSafety.md)、[../KnownIssues.md](../KnownIssues.md) 第 2 / 4 条与 N8
