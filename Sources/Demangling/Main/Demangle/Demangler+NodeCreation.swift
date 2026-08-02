/// The demangler's node-construction seam (proposal 0001, Phase 3).
///
/// Every node the demangler builds goes through these instance methods. With
/// `internsLeaves` (the default) they forward to the `Node.create` factories,
/// which intern leaves in `NodeCache.shared` — the historical behavior. With
/// `internsLeaves: false` they construct plain uncached nodes: no global lock
/// traffic and nothing retained once the transient tree is dropped, which is
/// what the `NodeStore` bridge wants.
extension Demangler {
    @inline(__always)
    func createNode(kind: Node.Kind, contents: Node.Contents = .none, children: [Node] = []) -> Node {
        internsLeaves
            ? Node.create(kind: kind, contents: contents, children: children)
            : Node(kind: kind, contents: contents, children: children)
    }

    @inline(__always)
    func createNode(kind: Node.Kind, contents: Node.Contents = .none, inlineChildren: Node.Children) -> Node {
        internsLeaves
            ? Node.create(kind: kind, contents: contents, inlineChildren: inlineChildren)
            : Node(kind: kind, contents: contents, inlineChildren: inlineChildren)
    }

    @inline(__always)
    func createNode(kind: Node.Kind, child: Node) -> Node {
        createNode(kind: kind, contents: .none, children: [child])
    }

    @inline(__always)
    func createNode(kind: Node.Kind, text: String, child: Node) -> Node {
        createNode(kind: kind, contents: .text(text), children: [child])
    }

    @inline(__always)
    func createNode(kind: Node.Kind, text: String, children: [Node] = []) -> Node {
        createNode(kind: kind, contents: .text(text), children: children)
    }

    @inline(__always)
    func createNode(kind: Node.Kind, index: UInt64, child: Node) -> Node {
        createNode(kind: kind, contents: .index(index), children: [child])
    }

    @inline(__always)
    func createNode(kind: Node.Kind, index: UInt64, children: [Node] = []) -> Node {
        createNode(kind: kind, contents: .index(index), children: children)
    }

    /// Compound: `.type` wrapping a node of `typeWithChildKind` with one child.
    func createNode(typeWithChildKind: Node.Kind, childChild: Node) -> Node {
        createNode(kind: .type, children: [createNode(kind: typeWithChildKind, children: [childChild])])
    }

    /// Compound: `.type` wrapping a node of `typeWithChildKind` with children.
    func createNode(typeWithChildKind: Node.Kind, childChildren: [Node]) -> Node {
        createNode(kind: .type, children: [createNode(kind: typeWithChildKind, children: childChildren)])
    }

    /// Compound: Swift stdlib type (`.type` > `kind` > [`.module("Swift")`, `.identifier(name)`]).
    func createNode(swiftStdlibTypeKind: Node.Kind, name: String) -> Node {
        createNode(kind: .type, children: [createNode(kind: swiftStdlibTypeKind, children: [
            createNode(kind: .module, text: stdlibName),
            createNode(kind: .identifier, text: name),
        ])])
    }

    /// Compound: Swift builtin type (`.type` > `kind(name)`).
    func createNode(swiftBuiltinType: Node.Kind, name: String) -> Node {
        createNode(kind: .type, children: [createNode(kind: swiftBuiltinType, text: name)])
    }
}
