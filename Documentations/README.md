# 文档索引

本目录收录内部专题文档：每篇对应一次实质性的架构演进或一块独立的子系统。

## 专题

- [SubtreeInterning.md](SubtreeInterning.md) — 全子树 interning（hash-consing）内存优化。把 interning 从叶节点扩展到全部子树，49k 符号语料解析驻留 39.5 MB → 12.9 MB。
- [NodeStoreArena.md](NodeStoreArena.md) — `NodeStore` arena 式紧凑存储。节点平铺进连续缓冲，每节点 12 字节、无对象头、无引用计数；printer 与 TypeDecoder 泛型化后可零物化直读。

两篇是承接关系：`SubtreeInterning` 把 class 形态下能做的去重做到头，`NodeStoreArena` 兑现了它结尾列为「待将来单独评估」的 arena 方向。

## 其他位置的文档

- `evolution/` — 演进提案（设计意图 + 决策日志）。`0001-node-store-arena.md` 是 `NodeStoreArena.md` 的提案原文。
- `docs/AlignmentGaps.md` — 与上游 Swift 编译器 `Demangling` 源码的对齐缺口追踪。
- `AGENTS.md` / `CLAUDE.md`（仓库根） — 面向编码 agent 的架构速查。
- `README.md`（仓库根） — 面向使用者的英文说明与用法示例。
