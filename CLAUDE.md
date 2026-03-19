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

Tests use the Swift Testing framework (`@Test`, `#expect`, `Issue.record`), **not** XCTest.

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
- **`NodeCache` / `NodeFactory`** (`NodeFactory.swift`) — Global leaf-node interning cache. `Node.create()` automatically interns leaf nodes. `NodeFactory` provides pre-created singletons for common parameterless nodes.
- **`Node.Kind`** (`Node+Kind.swift`) — Exhaustive enum of ~300 node kinds matching the Swift compiler's `Demangle::Node::Kind`.
- **`Demangler`** (`Demangler.swift`) — Generic over `Collection<UnicodeScalar>`. Parses mangled prefixes `_T0`, `_$S`, `_$s`, `$S`, `$s`, `$e`, `_$e`, `@__swiftmacro_`.
- **`Remangler`** (`Remangler.swift`) — Converts a `Node` tree back to a mangled string. Uses hash-based substitution merging.
- **`NodePrinter<Target>`** (`NodePrinter.swift`) — Generic over `NodePrinterTarget` protocol. Converts a `Node` tree to human-readable output controlled by `DemangleOptions`.
- **`DemangleOptions`** (`DemangleOptions.swift`) — `OptionSet` with presets: `.default`, `.simplified`, `.interface`, `.interfaceType`, etc.
- **`TypeDecoder<Builder>`** (`TypeDecoder.swift`) — Walks a `Node` tree and builds abstract types via the `TypeBuilder` protocol.
- **`Node.Rewriter`** (`Node+Rewriter.swift`) — Open class for bottom-up tree rewriting. Override `visit(_:)` to transform nodes.

### Public API Entry Points

```swift
// Demangle
func demangleAsNode(_ mangled: String, isType: Bool = false, ...) throws(DemanglingError) -> Node

// Print
node.print(using: .default)      // → String
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
  Node/              — Node, NodeChildren, NodeBuilder, NodeCache, Kind, Conversions, Rewriter
  Node/Printer/      — NodePrinter, NodePrinterTarget protocol, NodePrintContext/State
  Enums/             — SugarType, ManglingFlavor, DemanglingError, ManglingError, etc.
  Utils/             — Extensions, Common constants, Punycode
Tests/DemanglingTests/
```

## Conventions

- The codebase uses Swift 6 strict concurrency. `Node` is `Sendable` via `nonisolated(unsafe)` on its payload (safe because mutation only occurs during single-threaded demangling). `NodeBuilder` is `@unchecked Sendable` with an `os_unfair_lock`.
- Typed throws are used throughout: `throws(DemanglingError)`, `throws(ManglingError)`, `throws(TypeLookupError)`.
- Performance-sensitive code is marked `@inlinable` / `@usableFromInline`.
- `Node` creation during demangling uses `Node.create()` (not `Node.init()` directly) to go through `NodeCache` interning.
