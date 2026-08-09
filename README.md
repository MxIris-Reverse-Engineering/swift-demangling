# swift-demangling

A pure Swift library for demangling and remangling Swift mangled symbols, with full support for Swift 6 strict concurrency.

This project is derived from [CwlDemangle](https://github.com/mattgallagher/CwlDemangle) by Matt Gallagher, which is itself a line-by-line translation of the Swift compiler's C++ `Demangler` into Swift. Building on that foundation, this library has been significantly expanded with remangling, type decoding, tree traversal/rewriting APIs, node interning (hash-consing), and a generic printer target system.

## Features

- **Demangle** mangled Swift symbols into a structured `Node` tree
- **Pretty-print** demangled trees with configurable `DemangleOptions`
- **Remangle** modified trees back into valid mangled strings
- **Decode types** from mangled nodes via a pluggable `TypeBuilder` protocol
- **Traverse & rewrite** trees with built-in iterators and `Node.Rewriter`
- **Node interning (hash-consing)** via `NodeCache` — structurally equal subtrees share one instance, reducing memory ~4x for whole-binary demangling
- **Compact bulk storage** via `NodeStore` — an arena packing each node into 12 flat bytes with no object header, reference counting, or per-node allocation; printing and type decoding read straight from it without materializing a `Node` tree
- Supports all mangling prefixes: `_T0`, `_$S`, `_$s`, `$S`, `$s`, `$e`, `_$e`, `@__swiftmacro_`
- Swift 6 strict concurrency — all public types are `Sendable`

## Requirements

- Swift 6.2+
- macOS 10.15+ / iOS 13+ / macCatalyst 13+ / tvOS 13+ / watchOS 6+ / visionOS 1+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/MxIris-Reverse-Engineering/swift-demangling", from: "0.1.0"),
]
```

Then add `"Demangling"` to your target's dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "Demangling", package: "swift-demangling"),
    ]
),
```

## Usage

### Basic Demangling

```swift
import Demangling

// Demangle a mangled symbol into a Node tree
let node = try demangleAsNode("$s4main5helloyyF")

// Pretty-print with default options
let readable = node.print(using: .default)
// → "main.hello() -> ()"

// Pretty-print with sugar (e.g., Optional<Int> → Int?)
let sugared = node.print(using: .default.union(.synthesizeSugarOnTypes))
```

### Check if a String is a Swift Symbol

```swift
"$s4main5helloyyF".isSwiftSymbol       // true
"_objc_msgSend".isSwiftSymbol           // false

"$s4main5helloyyF".stripManglePrefix    // "4main5helloyyF"
```

### Demangle Options

`DemangleOptions` is an `OptionSet` with several presets:

```swift
// Full detail (default)
node.print(using: .default)

// Compact output — shortened thunks, value witnesses, archetypes
node.print(using: .simplified)

// Interface-style — no where clauses, no extension contexts, sugar on types
node.print(using: .interface)

// Custom combination
var options: DemangleOptions = .default
options.insert(.synthesizeSugarOnTypes)
options.remove(.displayModuleNames)
node.print(using: options)
```

### Inspecting the Node Tree

```swift
let node = try demangleAsNode("$s4main5helloyyF")

// Debug dump (kind/contents tree)
print(node.description)
// kind=global
//   kind=function
//     kind=module, text="main"
//     kind=identifier, text="hello"
//     ...

// Access node properties
node.kind          // .global
node.text          // nil (leaf text content)
node.index         // nil (leaf index content)
node.children      // Node.Children collection

// Subscript access
node[child: 0]             // first child (crashes if out of bounds)
node[safeChild: 0]         // first child or nil
node.children.at(0)        // same as safeChild
```

### Tree Traversal

`Node` conforms to `Sequence` with preorder traversal as default:

```swift
let node = try demangleAsNode("$s4main5helloyyF")

// Preorder (default)
for child in node {
    print(child.kind)
}

// Other traversal orders
for child in node.postorder()   { /* ... */ }
for child in node.inorder()     { /* ... */ }
for child in node.levelorder()  { /* ... */ }

// Find nodes by kind
let modules = node.all(of: .module)
let firstId = node.first(of: .identifier)
let hasType = node.contains(.type)
```

### Remangling

Convert a (possibly modified) node tree back into a mangled string:

```swift
let node = try demangleAsNode("$s4main5helloyyF")
let mangled = try mangleAsString(node)
// → "$s4main5helloyyF"

// Check if a tree can be remangled
canMangle(node)  // true
```

### Building & Modifying Trees

`Node` is immutable after creation. Use `NodeBuilder` to construct trees incrementally:

```swift
// Build a new node tree
let builder = NodeBuilder(kind: .tuple)
builder.addChild(element1)
builder.addChild(element2)
let tupleNode = builder.build()

// Non-mutating transformations (return new nodes)
let modified = node.addingChild(newChild)
let replaced = node.replacingDescendant(oldNode, with: newNode)
let changed  = node.changeKind(.structure)
```

### Tree Rewriting

Subclass `Node.Rewriter` for bottom-up tree transformations:

```swift
class ModuleRenamer: Node.Rewriter {
    override func visit(_ node: Node) -> Node {
        if node.kind == .module, node.text == "OldName" {
            return Node(kind: .module, contents: .text("NewName"))
        }
        return node
    }
}

let rewriter = ModuleRenamer()
let rewritten = rewriter.rewrite(originalTree)
```

### Custom Print Targets

Implement `NodePrinterTarget` to direct output to custom destinations:

```swift
struct HighlightedTarget: NodePrinterTarget {
    /// Every printed fragment with the semantic state it came from.
    private(set) var fragments: [(text: String, state: NodePrintState?)] = []
    /// The type reference the current writes belong to (innermost wins).
    private var typeReferenceScopes: [Node?] = []

    var count: Int { fragments.reduce(0) { $0 + $1.text.count } }

    init() {}

    mutating func write(_ content: String) {
        fragments.append((content, nil))
    }

    // Note `@autoclosure`: the context is built lazily, so a target that
    // ignores it never pays for it. This requirement has no default
    // implementation — an eager `context: NodePrintContext?` parameter is a
    // near-miss that fails to compile instead of silently doing nothing.
    mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
        // context()?.state is .printIdentifier, .printKeyword, .printType, …
        // and context()?.parentKind gives the enclosing node kind.
        fragments.append((content, context()?.state))
    }

    // Required so the printer can splice memoized fragments into the output
    // without dropping the annotations they carry.
    mutating func append(_ other: Self) {
        fragments.append(contentsOf: other.fragments)
    }

    // Also defaultless, for the same near-miss reason as write(_:context:).
    mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {
        typeReferenceScopes.append(node())
    }

    mutating func popTypeReferenceScope() {
        typeReferenceScopes.removeLast()
    }
}

let highlighted = NodePrinter<HighlightedTarget>.print(node, using: .default)
```

Both rich-target hooks (`write(_:context:)` and `pushTypeReferenceScope(_:)`)
take their payload as an `@autoclosure` and deliberately ship **without**
default implementations: a forwarding default would silently absorb an
implementation written against the older eager signature, leaving the printed
text byte-identical while every annotation vanished. Spelling both methods out
is required even for plain-text targets — `String`'s own conformance is the
minimal shape to copy. `popTypeReferenceScope()` keeps its default, since a
method with no arguments has no near-miss to absorb.

### Type Decoding

Implement the `TypeBuilder` protocol to construct your own type representations from demangled trees:

```swift
let decoder = TypeDecoder(builder: myTypeBuilder)
let type = try decoder.decodeMangledType(node: node)
```

### Memory Management

`demangleAsNode` interns the resulting tree through `NodeCache.shared` by default: leaf nodes are deduplicated at creation time, and the finished tree goes through a bottom-up subtree interning (hash-consing) pass. Structurally equal subtrees — across all demangled symbols — share a single `Node` instance, which reduces memory by roughly 4x when demangling a whole binary:

```swift
// Structurally equal subtrees are shared automatically
let node1 = try demangleAsNode(symbol1)
let node2 = try demangleAsNode(symbol2)
// e.g. the `Swift.Int` type subtree in both trees is the same instance

// Interned trees are retained by the cache; clear it when done to free memory
NodeCache.shared.clear()
```

Because interned nodes are canonical, demangling the same symbol twice returns the identical (`===`) tree instance. Interning never changes structural equality (`==`), printing, or remangling results.

For one-off demangling where the cache should not grow, opt out per call:

```swift
let node = try demangleAsNode(symbol, internsSubtrees: false)
```

For demangle-and-discard work — demangle, extract a string or a classification, drop the tree — use the fully cache-free entry instead. It touches no global state at all (`internsSubtrees: false` still interns leaf nodes), and its tree remangles byte-identically to the canonical path, so deriving lookup keys via `mangleAsString` is sound:

```swift
let node = try demangleAsNodeTransient(symbol)
```

Rule of thumb: keeping the tree → `demangleAsNode` (canonical, `===`-comparable instances); dropping the tree → `demangleAsNodeTransient` (nothing is retained behind your back). The transient tree is not canonical — never key logic by instance identity (`===` / `ObjectIdentifier`) on it.

### Deep Generic Nesting and Thread Stacks

Recursion in the printer, remangler, and type decoder is bounded by fixed depth limits, the same model the Swift compiler uses — but calibrated so they actually fire before the stack dies in **unoptimized builds** (upstream's constants assume release-built frames and an 8MB stack). Every limit clears the deepest real-world symbol measured by 2× or more; a pathologically deep tree degrades to `<<too complex>>` (or a `.tooComplex` / type-lookup error) instead of crashing the process, identically in debug and release.

On Darwin every thread except the main one gets a 512KB stack, which only covers a few dozen levels of nesting. When the calling thread runs low, printing, remangling and demangling hop onto a pooled 8MB-stack worker; threads with room to spare (the main thread, or big threads you create yourself) run inline with zero overhead — which also keeps `po node` usable under LLDB. When you are about to make many calls from small-stack threads, wrap the batch so it pays for at most one hop:

```swift
// At most one thread hop for the whole batch; every call inside runs inline.
let results = StackSafeExecutor.withLargeStack {
    symbols.map { try? demangleAsNode($0) }
}
```

`withLargeStack` requires `@_spi(Internals) import Demangling`. If you drive the demangler from threads you create yourself, setting `stackSize` to 8MB or more has the same effect — the library detects the headroom and never hops.

`TypeDecoder` is the deliberate exception: its `TypeBuilder` callbacks are your code and may be tied to an actor or a thread, so decoding always runs on the calling thread. Wrap deep batches in `withLargeStack` yourself.

### Bulk Demangling with NodeStore

When demangling a whole binary and keeping every result, `NodeStore` stores nodes in a flat arena instead of as individual class instances: 12 bytes per node, no object header, no reference counting, no per-node allocation. Build with `NodeStoreBuilder`, then `freeze()` into an immutable, `Sendable` store:

```swift
var builder = NodeStoreBuilder()
builder.reserveCapacity(expectedSymbolCount: symbols.count)
var rootIndices: [NodeStore.NodeIndex] = []
for symbol in symbols {
    rootIndices.append(try builder.demangle(symbol))
}
let store = builder.freeze()
```

`reserveCapacity(expectedSymbolCount:)` is optional but recommended when the symbol count is known up front (it usually is — one image, one builder): it pre-sizes every internal buffer from corpus-measured per-symbol constants, so a bulk build pays no buffer-regrowth copies and none of their transient memory spikes. An undersized estimate just degrades to normal growth; `capacityUtilization` reports used-versus-reserved per buffer.

Nodes are addressed by `NodeReference`, a 16-byte value handle that mirrors `Node`'s accessors. Printing and type decoding read directly from the arena — no `Node` tree is materialized:

```swift
let reference = store.reference(at: rootIndices[0])
let readable = reference.print(using: .default)

for child in reference.children where child.kind == .identifier {
    // `withTextUTF8` borrows the store's string table without allocating;
    // `textUTF8Bytes` is the copying convenience when the bytes must escape
    print(child.text ?? "")
}
```

The builder hash-conses on insert, so structurally equal subtrees collapse to one index and `NodeReference` equality is O(1) within a store. This path never touches `NodeCache.shared`, so bulk indexing leaves global state untouched.

A `NodeIndex` is only meaningful in the store whose builder minted it. Debug builds enforce this: every index carries its builder's issuance tag, and handing it to another builder or store fails a precondition immediately instead of silently resolving to an unrelated node (release builds compile the tag out — same layout and behavior as before).

Interop with the `Node` API stays available in both directions — `builder.intern(existingNode)` imports a tree, and `reference.materialize()` rebuilds a standalone one:

```swift
var builder = NodeStoreBuilder()
let index = builder.intern(try demangleAsNode(symbol))
let store = builder.freeze()          // `freeze()` consumes the builder
let node = store.reference(at: index).materialize()
```

Measured on a SwiftUI dyld-cache corpus of 234,232 symbols: 619,688 unique nodes in 8.75 MB of flat storage (14.1 bytes per unique node), built no slower than the `Node` path.

### Incremental Interning with SharedNodeStore

`NodeStoreBuilder` wants its input set up front: `freeze()` is a one-shot barrier, nothing can be read before it and nothing interned after. When the input is discovered over time — type names surfacing while a user browses, late-arriving symbols demangled on demand, trees produced while resolving conformances — use `SharedNodeStore`: a long-lived, thread-safe arena whose `intern`/`demangle` return immediately usable, permanently valid references, with no freeze barrier:

```swift
let store = SharedNodeStore()                        // one per scope (per image / per process)
store.reserveCapacity(expectedSymbolCount: 10_000)   // optional, same 0009 coefficients

let nameReference = store.intern(someNodeTree)       // structurally equal trees resolve to
let sameReference = store.intern(equalCopy)          // the same reference: nameReference == sameReference
let lateReference = try store.demangle(lateSymbol)   // cache-free demangle straight into the arena
```

One shared store means one arena for the whole scope: common subtrees deduplicate across everything ever interned, `NodeReference`'s intrinsic `==`/`hash` (store identity + index) is structural equality across the scope, and `Set`/`Dictionary` keys deduplicate naturally. Interning serializes on an internal lock (the demangle parse runs outside it); reads are lock-free apart from resolving the current buffer descriptor. References keep the storage alive even after the `SharedNodeStore` itself is released — interning stops, reading never breaks.

Pick by workload: input set known up front → `NodeStoreBuilder` + `freeze()` (drops its interning tables at freeze, reads with zero indirection); input discovered over time → `SharedNodeStore`. The shape to avoid is one private store per tree — `NodeReference(interning:)` in a loop — which forfeits both deduplication and compactness (measured at 110× the memory of one shared arena on repeated names).

## Acknowledgments

- [CwlDemangle](https://github.com/mattgallagher/CwlDemangle) by Matt Gallagher — the original Swift translation of the demangler
- [Apple Swift](https://github.com/apple/swift) — the upstream C++ demangler implementation

## License

This project is licensed under the [Apache License 2.0 with Runtime Library Exception](LICENSE.txt), the same license as the [Swift project](https://github.com/apple/swift/blob/main/LICENSE.txt) and [CwlDemangle](https://github.com/mattgallagher/CwlDemangle), from which this library is derived.
