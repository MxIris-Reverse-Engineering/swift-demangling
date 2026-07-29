# AGENTS.md
This file provides guidance to coding agents when working with code in this repository.

## Project Overview

Pure Swift library for demangling (and remangling) Swift mangled symbols. Port of the Swift compiler's `Demangler` / `Remangler` / `NodePrinter` to idiomatic Swift, targeting reverse-engineering tooling.

- **Library target**: `Demangling`
- **Swift tools version**: 6.2 (strict concurrency)
- **Platforms**: macOS 10.15+, iOS 13+, macCatalyst 13+, tvOS 13+, watchOS 6+, visionOS 1+
- **Dependency**: `FrameworkToolbox` (provides `FoundationToolbox`, `SwiftStdlibToolbox`)

## Build & Test

```bash
swift package update && swift build 2>&1 | xcsift
swift package update && swift test 2>&1 | xcsift
```

Run a single test by name:
```bash
swift test --filter DemanglingTests.NodeBuilderTests/initWithExistingNode
```

Tests use the Swift Testing framework (`@Suite`, `@Test`, `#expect`, `Issue.record`), **not** XCTest.

## Architecture

### Core Pipeline

```
mangled string → Demangler → Node tree → NodePrinter → human-readable string
                                       → Remangler  → re-mangled string
                                       → TypeDecoder → abstract type (via TypeBuilder)
```

### Key Types

- **`Node`** (`Node.swift`) — Immutable tree node (reference type, `Sendable`). Uses a unified `Payload` enum that merges contents (`.text`/`.index`/`.none`) and children (`.oneChild`/`.twoChildren`/`.manyChildren`) into a single discriminated union — contents and children are mutually exclusive. Mutation methods are `fileprivate`; external code must use `NodeBuilder`.
- **`Node.Children`** (`Node.Children.swift`) — Inline storage for 0–2 children without heap allocation; falls back to `ContiguousArray` for 3+.
- **`NodeBuilder`** (`Node.swift`) — Thread-safe builder for constructing `Node` trees incrementally (uses `os_unfair_lock`).
- **`Node.create()`** (`Node+Init.swift`) — Public static factories that go through `NodeCache.shared` for leaf-node interning. Always use these instead of `Node.init()` when creating nodes that should be cached. The `@_spi(Internals)` `Node.createTransient(...)` counterparts never touch the cache — use them (together with `demangleAsNodeTransient`, which also accepts a `symbolicReferenceResolver`) in pipelines that must not pin anything in global state, such as symbolic-reference resolvers and store-feeding bulk demangling.
- **`NodeCache` / `NodeFactory`** (`NodeFactory.swift`) — `NodeCache` is the global interning cache with two levels: leaf nodes are interned eagerly at creation time, and whole trees are hash-consed bottom-up via `intern(_:)` / `internTreeUnsafe(_:)` (structurally equal subtrees collapse to one shared instance; interior-node keys compare children by `===`, which is safe because children are canonicalized before their parent). `demangleAsNode` runs the tree-interning pass by default (`internsSubtrees: true`), so identical symbols demangle to the identical (`===`) tree; opt out with `internsSubtrees: false`. `NodeFactory` provides pre-created singletons for common parameterless nodes (e.g., `NodeFactory.emptyList`, `.asyncAnnotation`). The `Node.init(...)` convenience initializers in `NodeFactory.swift` are **internal** and bypass the cache — they exist for `Demangler`/`Remangler` internals.
- **`Node.Kind`** (`Node+Kind.swift`) — Exhaustive enum of ~300 node kinds matching the Swift compiler's `Demangle::Node::Kind`.
- **`Demangler`** (`Demangler.swift`) — Generic over `Collection<UnicodeScalar>`. Parses mangled prefixes `_T0`, `_$S`, `_$s`, `$S`, `$s`, `$e`, `_$e`, `@__swiftmacro_`.
- **`Remangler`** (`Remangler.swift`) — Converts a `Node` tree back to a mangled string. Uses hash-based substitution merging.
- **`NodePrinter<Target>`** (`NodePrinter.swift`) — Generic over `NodePrinterTarget` protocol. Converts a `Node` tree to human-readable output controlled by `DemangleOptions`.
- **`DemangleOptions`** (`DemangleOptions.swift`) — `OptionSet` with presets: `.default`, `.simplified`, `.interface`, `.interfaceType`, etc.
- **`TypeDecoder<Builder>`** (`TypeDecoder.swift`) — Walks a `Node` tree and builds abstract types via the `TypeBuilder` protocol.
- **`Node.Rewriter`** (`Node+Rewriter.swift`) — Open class for bottom-up tree rewriting. Override `visit(_:)` to transform nodes.
- **Traversal** (`Store/DemanglingNode+Sequence.swift`, `Node+Sequence.swift`) — the traversal machinery (`preorder`/`inorder`/`postorder`/`levelorder`), the kind-lookup helpers (`first(of:)`, `all(of:)`, `contains(_:)`, `filter(of:)` on `Sequence where Element: DemanglingNode`), and `identifier` are single generic implementations shared by both representations; `Node` and `NodeReference` each conform to `Sequence` with preorder as the default. Do not re-add `Node`-specific copies.
- **`NodeStore` / `NodeStoreBuilder` / `NodeReference`** (`Store/`) — Arena-based compact storage for bulk demangling (evolution proposal 0001; design notes and measurements in `Documentations/NodeStoreArena.md`). Nodes are flat 12-byte `CompactNode` values referenced by `UInt32` indices in one contiguous buffer; the `~Copyable` builder hash-conses on insert and `consuming freeze()` produces an immutable `Sendable` store. Interning tables are open-addressing slot arrays holding 4-byte indices (keys recovered from the buffers — no separate key storage). The builder's `demangle(_:)` bridge is fully cache-free (Phase 3): the transient tree is built with `internsLeaves: false`, so nothing touches `NodeCache.shared`. `intern(kind:...)` overloads construct nodes directly in the arena (wrapper `.type` nodes for index keys, etc.). `NodeReference` is a 16-byte value handle mirroring `Node` accessors (kind/text/index/children), plus `textUTF8` (zero-copy string-table bytes), allocation-free `isIdentifier`/`isSwiftModule` witnesses, `structurallyEquals(_ node: Node)` (zero-materialization cross-representation structural equality matching `Node.==` — the bridge for finding an externally demangled `Node` among `NodeReference` dictionary keys, since the frozen store drops its intern tables), `structurallyEquals(_ other: NodeReference)` (same-store O(1) via index equality, cross-store structural walk) plus `structuralHash(into:)` (structure-consistent hashing for value types that key dictionaries by node structure while storing references — `NodeReference`'s intrinsic `Hashable` is store-identity based), `NodeReference(interning:)` (interns one `Node` tree into a fresh private mini store — self-contained handles for values that outlive their source tree), and a `CustomStringConvertible` debug dump (materialization bridge). `demangleAsNodeTransient` is exported via `@_spi(Internals)` for bulk indexers that classify on the transient tree before interning it (the returned tree is NOT canonical). `materialize()` rebuilds a standalone (non-`NodeCache`) `Node` tree with an index-keyed memo, so store-level subtree sharing survives as shared instances instead of expanding the DAG.
- **`DemanglingNode` / generic engines** (`Store/DemanglingNode.swift`, `Node/Printer/NodePrinter.swift`, `Main/TypeDecoder/TypeDecoder.swift`) — read-only tree protocol conformed by both `Node` and `NodeReference` (members named to match `Node`'s API so generic engine bodies are representation-agnostic). Engines: `DemanglingPrinter<Target, SomeNode>` behind the public `NodePrinter<Target>` facade (store printing is **zero materialization**, byte-identical to the `Node` path across the full dyld-cache corpus), and `TypeDecoderEngine<Builder, SomeNode>` behind `TypeDecoder<Builder>` (the public `TypeBuilder` protocol still receives concrete `Node` at the five handoff points via `materializedNode`). The `Remangler` deliberately stays a `Node` engine — its walk constructs transient helper nodes with shared substitution state (same design as the C++ remangler) — so `mangleAsString(some DemanglingNode)` bridges through `materializedNode`. The derived helpers (`isSimpleType`, `needSpaceBeforeType`, `hasChildren`, `subscript(throwChild:)`, `isIdentifier(desired:)`, `isSwiftModule`, `isKind(of:)`, and `second` on `DemanglingNodeChildren`) live **only** on the `DemanglingNode` protocol/extension — do not re-add copies on `Node` or `Node.Children`: the generic engines dispatch to the shared implementation, so a parallel concrete copy would silently drift. `NodePrintContext.node` stays a concrete `Node?` (store path passes `name as? Node` → nil; harmless — no rich target reads it on the store path). `NodePrinterTarget.pushTypeReferenceScope` takes its node as `@autoclosure () -> Node?`: scope-ignoring targets (`String`, the default implementation) never evaluate it, keeping store-backed plain-text printing allocation-free, while rich targets (e.g. `SemanticString`) evaluate it and receive `materializedNode`, materializing only the nominal-reference subtree. Note the delivered node is canonical **only on the `Node` path**: store-backed printing builds a fresh non-interned subtree per evaluation, so two pushes of the same store index are not `===`. Rich targets must key scopes by structure (e.g. the remangled string, as `SemanticString` does) — never by `ObjectIdentifier`/`===`. `DemanglingPrinter` and `StackSafeExecutor` are exported via `@_spi(Internals)` for deep consumers (MachOSwiftSection rich targets).
- **`StackBudget` / `StackSafeExecutor`** (`Utils/`) — recursion in the three engines is bounded by **remaining stack bytes**, not by a frame count (design notes and measurements in `Documentations/StackSafety.md`; proposal 0002). A frame count is a proxy for stack bytes and the two are not proportional across build configurations, `DemanglingNode` specializations, or thread stack sizes — the old fixed limits (`maxPrintDepth` 768, `Remangler.maxDepth` 1024) simultaneously let debug builds overflow an 8MB stack and rejected legitimate generics beyond ~384 nesting levels. `StackBudget.forCurrentThread(fallbackDepthLimit:)` is captured at each engine entry (`DemanglingPrinter.printRoot` / `Remangler.mangle(_:)` / `TypeDecoderEngine.decodeMangledType(node:forRequirement:)` — at the walk, never at `init`, because a stack floor is only meaningful on the thread that produced it) and probed **on every level**; sampling every N levels is unsafe because a wrong per-level estimate crosses the whole reserve between probes. The probe is non-sticky (one deep path degrades, siblings do not) and the surviving frame-count constants are cycle backstops only. `StackSafeExecutor` moves work onto a **bounded pool of long-lived 64MB-stack workers**. Four properties are load-bearing: workers never retire (an idle timeout has a window where a submission counts a retiring worker as available and the item is silently dropped); a worker is created *before* its work is queued and creation is checked (`pthread_create`, never `Thread.start()`, which reports nothing when the OS refuses — that failure used to strand the item and permanently poison a process-wide singleton); `trySubmit` can **refuse**, in which case the caller runs the work itself under `StackBudget`, so every failure mode degrades instead of hanging; and a worker never submits back into the pool (thread-local `pthread_key_t` flag → nested calls run inline, since printing re-enters demangling for nested mangled names). The pool grows on demand to `max(2, activeProcessorCount)`, and *blocking* submissions may grow it further, to `max(32, 4 × that)` — a caller about to block is evidence of a parked thread, which is what breaks the wait cycle a fan-out inside `withLargeStack(_:)` would otherwise create; asynchronous submissions hold no thread and stay under the steady-state limit. **Every entry point runs its work with at least a worker's stack below it regardless of the calling thread** — the earlier 2MB threshold let the main thread's 8MB run inline and therefore cap depth *lower* than a 512KB cooperative worker that got moved to a 64MB worker, so the same tree printed in full from a `Task` and `<<too complex>>` from the main thread. `withLargeStack(_:)` is the batch-boundary entry — wrap a whole indexing pass in it and every call inside runs inline with zero thread hop. `executeWithUncheckedSendability` is the variant for `TypeDecoder`, whose `TypeBuilder` and built types carry no `Sendable` conformance. **Adding a new recursion**: it must either converge on a guarded entry point or be iterative. Verify with the call-graph audit described in `Documentations/StackSafety.md` (build the SCCs, then delete the candidate convergence point and re-run) — a single check on `mangle` was never enough; six cycles bypassed it. Whole-tree walks outside the engines are iterative for the same reason: `NodeCache.internTreeUnsafe`, `NodeStoreBuilder.internTree`, `Node.==` / `hash(into:)`, `Node.copy()` / `replacingDescendant(_:with:)` (public, and `NodeBuilder` runs them while holding its lock), `Node.Rewriter.rewrite` (`final`; only `visit` is `open`, so iterating changes no override point), `Node.description`'s dump, `NodeStore.materializeNode`, `NodeReference.structurallyEquals` / `structuralHash`, `getUnspecialized`, and `DemanglingNode.isSimpleType` / `needSpaceBeforeType`. `Node.deinit` tears trees down with an explicit work list because releasing a deep tree recurses in the runtime where no engine guard can reach it. **Still recursive and deliberately so**: `Demangler`'s `setParentForOpaqueReturnTypeNodesImpl` / `demangleBoundGenericArgs` and the `demangleSwift3*` recursive-descent component (reachable only through the `_T` prefix). Those all sit inside `demangleAsNode`, which routes through `StackSafeExecutor`, so they run on a 64MB worker and do not crash at any depth a real symbol reaches — but they fail by crashing rather than by erroring, so do not raise the depth they are expected to survive without guarding them first. Where no stack measurement is available (non-Darwin, or `pthread_get_stackaddr_np` failing), `StackBudget` falls back to the frame count each engine used before it existed, so those platforms keep exactly their old behaviour instead of losing the guard.
- **`Demangler` construction seam** (`Main/Demangle/Demangler+NodeCreation.swift`) — every node the demangler builds goes through `createNode(...)` instance methods; `internsLeaves: false` (used by the internal `demangleAsNodeTransient`) bypasses `NodeCache.shared` entirely. New construction sites in `Demangler` must use `createNode(...)`, never `Node.create(...)` directly.

### Node Identity vs Equality

`Node` is a reference type with structural `Hashable` conformance: `==` compares kind + contents + children recursively, while `===` checks identity. Interned nodes from `NodeCache` guarantee identity equality for structurally equal trees: leaves are canonical from creation, and any tree returned by `demangleAsNode` (default `internsSubtrees: true`) is fully canonical, so structurally equal subtrees are the same instance across all demangled symbols.

### Public API Entry Points

```swift
// Demangle
func demangleAsNode(_ mangled: String, isType: Bool = false, ...) throws(DemanglingError) -> Node

// Print
node.print(using: .default)      // → String (human-readable)
node.description                  // → debug tree dump (kind=..., text=...)

// Remangle
func mangleAsString(_ node: Node, usePunycode: Bool = true) throws(ManglingError) -> String
func canMangle(_ node: Node) -> Bool

// Helpers
"$s...".isSwiftSymbol             // prefix check
"$s...".stripManglePrefix         // remove mangling prefix
```

### Directory Layout

```
Sources/Demangling/
  Main/Demangle/     — Demangler, DemangleInterface, DemangleOptions
  Main/Remangle/     — Remangler, RemangleInterface
  Main/TypeDecoder/  — TypeDecoder, TypeBuilder protocol
  Node/              — Node, Node.Children, NodeBuilder, NodeCache, Kind, Conversions, Sequence, Rewriter
  Node/Printer/      — NodePrinter, NodePrinterTarget protocol, NodePrintContext/State
  Store/             — CompactNode, NodeStore, NodeStoreBuilder, NodeReference, DemanglingNode (evolution proposal 0001)
  Enums/             — SugarType, ManglingFlavor, DemanglingError, ManglingError, etc.
  Utils/             — StackBudget, StackSafeExecutor, Extensions, Common constants, Punycode
Tests/DemanglingTests/
```

## Conventions

- Swift 6 strict concurrency. `Node` is `Sendable` via `nonisolated(unsafe)` on its payload (safe because mutation only occurs during single-threaded demangling). `NodeBuilder` is `@unchecked Sendable` with `os_unfair_lock`.
- Typed throws throughout: `throws(DemanglingError)`, `throws(ManglingError)`, `throws(TypeLookupError)`.
- Performance-sensitive code is marked `@inlinable` / `@usableFromInline`.
- Use `Node.create()` (not `Node.init()`) when creating nodes that should participate in leaf interning. Direct `Node.init()` is for internal demangler/remangler use only.
- Test pattern: demangle with `demangleAsNode()`, print with `.print(using: .default.union(.synthesizeSugarOnTypes))`, assert with `#expect`.
