/// The demangler's node-construction seam (proposal 0001, Phase 3).
///
/// Every node the demangler builds goes through these instance methods. With
/// `internsLeaves` (the default) they forward to the `Node.create` factories,
/// which intern leaves in `NodeCache.shared` — the historical behavior. With
/// `internsLeaves: false` they construct plain uncached nodes: no global lock
/// traffic and nothing retained once the transient tree is dropped, which is
/// what the `NodeStore` bridge wants.
extension Demangler {
    // Contents and children are never passed together, matching the public
    // factories — see `Node.create(kind:text:)`.
    @inline(__always)
    func createNode(kind: Node.Kind, children: [Node] = []) -> Node {
        internsLeaves
            ? Node.create(kind: kind, children: children)
            : Node(kind: kind, contents: .none, children: children)
    }

    @inline(__always)
    func createNode(kind: Node.Kind, contents: Node.Contents) -> Node {
        internsLeaves
            ? Node.create(kind: kind, contents: contents)
            : Node(kind: kind, contents: contents, children: [])
    }

    @inline(__always)
    func createNode(kind: Node.Kind, inlineChildren: Node.Children) -> Node {
        internsLeaves
            ? Node.create(kind: kind, inlineChildren: inlineChildren)
            : Node(kind: kind, contents: .none, inlineChildren: inlineChildren)
    }

    @inline(__always)
    func createNode(kind: Node.Kind, child: Node) -> Node {
        createNode(kind: kind, children: [child])
    }

    // Contents-carrying leaves only — see `Node.create(kind:text:)` for why the
    // `child:`/`children:` counterparts are gone.
    @inline(__always)
    func createNode(kind: Node.Kind, text: String) -> Node {
        createNode(kind: kind, contents: .text(text))
    }

    @inline(__always)
    func createNode(kind: Node.Kind, index: UInt64) -> Node {
        createNode(kind: kind, contents: .index(index))
    }

    // The compound forms below are `mutating` for the reason `require` is
    // (Demangler.swift): their callers pass arguments that mutate `self` —
    // `createNode(typeWithChildKind:childChildren: [..., require(pop(kind: .type))])`
    // — and a non-mutating receiver had to be a copy of the whole demangler,
    // taken before those arguments ran. The single-node forms above stay
    // non-mutating for the two non-mutating callers; they are always inlined
    // and read only `internsLeaves`, a `let`, so the optimizer drops their
    // copy, which the compound forms, not inlined, kept.

    /// Compound: `.type` wrapping a node of `typeWithChildKind` with one child.
    mutating func createNode(typeWithChildKind: Node.Kind, childChild: Node) -> Node {
        createNode(kind: .type, children: [createNode(kind: typeWithChildKind, children: [childChild])])
    }

    /// Compound: `.type` wrapping a node of `typeWithChildKind` with children.
    mutating func createNode(typeWithChildKind: Node.Kind, childChildren: [Node]) -> Node {
        createNode(kind: .type, children: [createNode(kind: typeWithChildKind, children: childChildren)])
    }

    /// Compound: Swift stdlib type (`.type` > `kind` > [`.module("Swift")`, `.identifier(name)`]).
    mutating func createNode(swiftStdlibTypeKind: Node.Kind, name: String) -> Node {
        createNode(kind: .type, children: [createNode(kind: swiftStdlibTypeKind, children: [
            createNode(kind: .module, text: stdlibName),
            createNode(kind: .identifier, text: name),
        ])])
    }

    /// Compound: Swift builtin type (`.type` > `kind(name)`).
    mutating func createNode(swiftBuiltinType: Node.Kind, name: String) -> Node {
        createNode(kind: .type, children: [createNode(kind: swiftBuiltinType, text: name)])
    }
}
