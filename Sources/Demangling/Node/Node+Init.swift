import SwiftStdlibToolbox

// MARK: - Factory Methods (with automatic leaf interning)

extension Node {
    /// Creates a node. Leaf nodes (no children) are automatically interned via `NodeCache.shared`.
    @inlinable
    public static func create(kind: Kind, contents: Contents = .none, children: [Node] = []) -> Node {
        NodeCache.shared.createInterned(kind: kind, contents: contents, children: children)
    }

    /// Creates a node from inline children. Leaf nodes are automatically interned.
    @inlinable
    public static func create(kind: Kind, contents: Contents = .none, inlineChildren: Children) -> Node {
        NodeCache.shared.createInterned(kind: kind, contents: contents, inlineChildren: inlineChildren)
    }

    @inlinable
    public static func create(kind: Kind, child: Node) -> Node {
        create(kind: kind, contents: .none, children: [child])
    }

    /// Creates an interned leaf carrying `text`.
    ///
    /// There is deliberately no `children` parameter: contents and children are
    /// mutually exclusive in `Payload`, so `mergedPayload` dropped `text` on the
    /// floor whenever children were present — silently, and through the subtree
    /// intern key, collapsing two differently-texted requests onto one shared
    /// instance. The overloads that accepted both are gone rather than
    /// precondition-guarded, so the invalid combination cannot be spelled
    /// (PR #7 review, finding 8).
    @inlinable
    public static func create(kind: Kind, text: String) -> Node {
        create(kind: kind, contents: .text(text))
    }

    /// Creates an interned leaf carrying `index`. See ``create(kind:text:)``
    /// for why there is no `children` parameter.
    @inlinable
    public static func create(kind: Kind, index: UInt64) -> Node {
        create(kind: kind, contents: .index(index))
    }

    /// Compound factory: creates `.type` wrapping a node of `typeWithChildKind` with a single child.
    /// Uses `create()` for intermediate nodes to ensure inline interning.
    static func create(typeWithChildKind: Kind, childChild: Node) -> Node {
        create(kind: .type, children: [create(kind: typeWithChildKind, children: [childChild])])
    }

    /// Compound factory: creates `.type` wrapping a node of `typeWithChildKind` with children.
    static func create(typeWithChildKind: Kind, childChildren: [Node]) -> Node {
        create(kind: .type, children: [create(kind: typeWithChildKind, children: childChildren)])
    }

    /// Compound factory: creates a Swift stdlib type node (`.type` > `kind` > [`.module("Swift")`, `.identifier(name)`]).
    static func create(swiftStdlibTypeKind: Kind, name: String) -> Node {
        create(kind: .type, children: [create(kind: swiftStdlibTypeKind, children: [
            create(kind: .module, text: stdlibName),
            create(kind: .identifier, text: name),
        ])])
    }

    /// Compound factory: creates a Swift builtin type node (`.type` > `kind(name)`).
    static func create(swiftBuiltinType: Kind, name: String) -> Node {
        create(kind: .type, children: [create(kind: swiftBuiltinType, text: name)])
    }
}

// MARK: - Transient Factory Methods (no interning)

/// Transient counterparts of `Node.create(...)` that never touch
/// `NodeCache.shared`: leaves are freshly allocated instead of interned, so
/// nothing gets pinned in global state for the process lifetime.
///
/// Exported via `@_spi(Internals)` for consumers whose whole pipeline runs
/// off the global cache (transient demangling feeding a `NodeStoreBuilder`,
/// symbolic-reference resolvers building splice nodes, and similar). The
/// returned nodes are NOT canonical: structurally equal nodes are distinct
/// instances, so `===`-based sharing assumptions do not apply.
@_spi(Internals)
extension Node {
    public static func createTransient(kind: Kind, contents: Contents = .none, children: [Node] = []) -> Node {
        Node(kind: kind, contents: contents, children: children)
    }

    public static func createTransient(kind: Kind, contents: Contents = .none, inlineChildren: Children) -> Node {
        Node(kind: kind, contents: contents, inlineChildren: inlineChildren)
    }

    public static func createTransient(kind: Kind, child: Node) -> Node {
        Node(kind: kind, contents: .none, children: [child])
    }

    /// See ``create(kind:text:)`` for why there is no `children` parameter.
    public static func createTransient(kind: Kind, text: String) -> Node {
        Node(kind: kind, contents: .text(text))
    }

    /// See ``create(kind:text:)`` for why there is no `children` parameter.
    public static func createTransient(kind: Kind, index: UInt64) -> Node {
        Node(kind: kind, contents: .index(index))
    }
}

extension Node {
    // A `text:`/`index:` counterpart of this builder would always discard its
    // contents — the builder exists to produce children, and children win in
    // `mergedPayload`. See ``create(kind:text:)``.
    @inlinable
    public static func create(kind: Kind, contents: Contents = .none, @ArrayBuilder<Node> childrenBuilder: () -> [Node]) -> Node {
        create(kind: kind, contents: contents, children: childrenBuilder())
    }
}
