# swift-demangling

A pure Swift library for demangling and remangling Swift mangled symbols, with full support for Swift 6 strict concurrency.

This project is derived from [CwlDemangle](https://github.com/mattgallagher/CwlDemangle) by Matt Gallagher, which is itself a line-by-line translation of the Swift compiler's C++ `Demangler` into Swift. Building on that foundation, this library has been significantly expanded with remangling, type decoding, tree traversal/rewriting APIs, leaf-node interning, and a generic printer target system.

## Features

- **Demangle** mangled Swift symbols into a structured `Node` tree
- **Pretty-print** demangled trees with configurable `DemangleOptions`
- **Remangle** modified trees back into valid mangled strings
- **Decode types** from mangled nodes via a pluggable `TypeBuilder` protocol
- **Traverse & rewrite** trees with built-in iterators and `Node.Rewriter`
- **Leaf-node interning** via `NodeCache` for memory-efficient batch processing
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
node.children      // NodeChildren collection

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
struct AttributedStringTarget: NodePrinterTarget {
    var count: Int { /* ... */ }

    init() { /* ... */ }

    mutating func write(_ content: String) { /* ... */ }

    mutating func write(_ content: String, context: NodePrintContext?) {
        // Use context.state (.printIdentifier, .printKeyword, .printType, etc.)
        // and context.parentKind to apply syntax highlighting
    }
}

var printer = NodePrinter<AttributedStringTarget>(options: .default)
let attributed = printer.printRoot(node)
```

### Type Decoding

Implement the `TypeBuilder` protocol to construct your own type representations from demangled trees:

```swift
let decoder = TypeDecoder(builder: myTypeBuilder)
let type = try decoder.decodeMangledType(node: node)
```

### Memory Management

When processing many symbols (e.g., scanning a binary), use `NodeCache` for deduplication:

```swift
// Leaf nodes are automatically interned during demangling
let node1 = try demangleAsNode(symbol1)
let node2 = try demangleAsNode(symbol2)
// Shared leaf nodes (e.g., .module("Swift")) use the same instance

// Clear the cache when done to free memory
NodeCache.shared.clear()
```

## Acknowledgments

- [CwlDemangle](https://github.com/mattgallagher/CwlDemangle) by Matt Gallagher — the original Swift translation of the demangler
- [Apple Swift](https://github.com/apple/swift) — the upstream C++ demangler implementation

## License

This project is licensed under the [Apache License 2.0 with Runtime Library Exception](LICENSE.txt), the same license as the [Swift project](https://github.com/apple/swift/blob/main/LICENSE.txt) and [CwlDemangle](https://github.com/mattgallagher/CwlDemangle), from which this library is derived.
