# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- **`NodeChildren`** (`NodeChildren.swift`) — Inline storage for 0–2 children without heap allocation; falls back to `ContiguousArray` for 3+.
- **`NodeBuilder`** (`Node.swift`) — Thread-safe builder for constructing `Node` trees incrementally (uses `os_unfair_lock`).
- **`Node.create()`** (`Node+Init.swift`) — Public static factories that go through `NodeCache.shared` for leaf-node interning. Always use these instead of `Node.init()` when creating nodes that should be cached.
- **`NodeCache` / `NodeFactory`** (`NodeFactory.swift`) — `NodeCache` is the global leaf-node interning cache. `NodeFactory` provides pre-created singletons for common parameterless nodes (e.g., `NodeFactory.emptyList`, `.asyncAnnotation`). The `Node.init(...)` convenience initializers in `NodeFactory.swift` are **internal** and bypass the cache — they exist for `Demangler`/`Remangler` internals.
- **`Node.Kind`** (`Node+Kind.swift`) — Exhaustive enum of ~300 node kinds matching the Swift compiler's `Demangle::Node::Kind`.
- **`Demangler`** (`Demangler.swift`) — Generic over `Collection<UnicodeScalar>`. Parses mangled prefixes `_T0`, `_$S`, `_$s`, `$S`, `$s`, `$e`, `_$e`, `@__swiftmacro_`.
- **`Remangler`** (`Remangler.swift`) — Converts a `Node` tree back to a mangled string. Uses hash-based substitution merging.
- **`NodePrinter<Target>`** (`NodePrinter.swift`) — Generic over `NodePrinterTarget` protocol. Converts a `Node` tree to human-readable output controlled by `DemangleOptions`.
- **`DemangleOptions`** (`DemangleOptions.swift`) — `OptionSet` with presets: `.default`, `.simplified`, `.interface`, `.interfaceType`, etc.
- **`TypeDecoder<Builder>`** (`TypeDecoder.swift`) — Walks a `Node` tree and builds abstract types via the `TypeBuilder` protocol.
- **`Node.Rewriter`** (`Node+Rewriter.swift`) — Open class for bottom-up tree rewriting. Override `visit(_:)` to transform nodes.
- **`Node` as `Sequence`** (`Node+Sequence.swift`) — `Node` conforms to `Sequence` with preorder traversal as default. Also provides `.inorder()`, `.postorder()`, `.levelorder()`. Sequence extensions add `first(of:)`, `all(of:)`, `contains(_:)` by `Node.Kind`.

### Node Identity vs Equality

`Node` is a reference type with structural `Hashable` conformance: `==` compares kind + contents + children recursively, while `===` checks identity. Interned leaf nodes from `NodeCache` guarantee identity equality for structurally equal leaves.

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
  Node/              — Node, NodeChildren, NodeBuilder, NodeCache, Kind, Conversions, Sequence, Rewriter
  Node/Printer/      — NodePrinter, NodePrinterTarget protocol, NodePrintContext/State
  Enums/             — SugarType, ManglingFlavor, DemanglingError, ManglingError, etc.
  Utils/             — Extensions, Common constants, Punycode
Tests/DemanglingTests/
```

## Conventions

- Swift 6 strict concurrency. `Node` is `Sendable` via `nonisolated(unsafe)` on its payload (safe because mutation only occurs during single-threaded demangling). `NodeBuilder` is `@unchecked Sendable` with `os_unfair_lock`.
- Typed throws throughout: `throws(DemanglingError)`, `throws(ManglingError)`, `throws(TypeLookupError)`.
- Performance-sensitive code is marked `@inlinable` / `@usableFromInline`.
- Use `Node.create()` (not `Node.init()`) when creating nodes that should participate in leaf interning. Direct `Node.init()` is for internal demangler/remangler use only.
- Test pattern: demangle with `demangleAsNode()`, print with `.print(using: .default.union(.synthesizeSugarOnTypes))`, assert with `#expect`.
