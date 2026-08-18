import SwiftStdlibToolbox

// MARK: - Factory Methods (with automatic leaf interning)

extension Node {
    /// Creates a node with children. Childless nodes are automatically interned
    /// via `NodeCache.shared`.
    ///
    /// There is deliberately no `contents` parameter here, and no `children`
    /// parameter on ``create(kind:contents:)`` — see ``create(kind:text:)``.
    @inlinable
    public static func create(kind: Kind, children: [Node] = []) -> Node {
        NodeCache.shared.createInterned(kind: kind, children: children)
    }

    /// Creates an interned leaf carrying `contents`.
    @inlinable
    public static func create(kind: Kind, contents: Contents) -> Node {
        NodeCache.shared.createInterned(kind: kind, contents: contents)
    }

    /// Creates a node from inline children. Childless nodes are automatically interned.
    @inlinable
    public static func create(kind: Kind, inlineChildren: Children) -> Node {
        NodeCache.shared.createInterned(kind: kind, inlineChildren: inlineChildren)
    }

    @inlinable
    public static func create(kind: Kind, child: Node) -> Node {
        create(kind: kind, children: [child])
    }

    /// Creates an interned leaf carrying `text`.
    ///
    /// There is deliberately no `children` parameter: contents and children are
    /// mutually exclusive in `Payload` (as they are in upstream's `Node`, whose
    /// payload is a union of `Text`/`Index`/`OneChild`/`TwoChildren`/
    /// `ManyChildren`), so `mergedPayload` dropped `text` on the floor whenever
    /// children were present — silently, and through the subtree intern key,
    /// collapsing two differently-texted requests onto one shared instance.
    /// Every factory that accepted both is gone rather than
    /// precondition-guarded, so the invalid combination cannot be spelled
    /// (PR #7 review, finding 8).
    ///
    /// The first pass at this deleted only the `text:`/`index:` spellings and
    /// left the primary `contents:` + `children:` overload in place — while
    /// this very comment claimed the combination was unspellable. The rule is
    /// enforced by `DefectRegressionTests.nodeFactoriesCannotSpellContentsWithChildren`
    /// now, so the claim and the code cannot drift apart again.
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
    /// See ``create(kind:children:)`` for why contents and children cannot be
    /// passed together.
    public static func createTransient(kind: Kind, children: [Node] = []) -> Node {
        Node(kind: kind, contents: .none, children: children)
    }

    public static func createTransient(kind: Kind, contents: Contents) -> Node {
        Node(kind: kind, contents: contents, children: [])
    }

    public static func createTransient(kind: Kind, inlineChildren: Children) -> Node {
        Node(kind: kind, contents: .none, inlineChildren: inlineChildren)
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
    // No `contents:` parameter, for the same reason as everywhere else: this
    // builder exists to produce children, and children win in `mergedPayload`.
    // See ``create(kind:text:)``.
    @inlinable
    public static func create(kind: Kind, @ArrayBuilder<Node> childrenBuilder: () -> [Node]) -> Node {
        create(kind: kind, children: childrenBuilder())
    }
}
