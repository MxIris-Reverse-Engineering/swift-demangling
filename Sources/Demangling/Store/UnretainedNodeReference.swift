/// Engine-internal walk handle for store-backed printing (proposal 0008, B2):
/// `NodeReference` minus the retain. The store is held `unowned(unsafe)`, so
/// copying the handle — which a walk does once per visited child — moves
/// sixteen bytes with zero ARC traffic. This is the same layering as
/// swift-syntax's `RawSyntaxArenaRef`: the public value (`NodeReference`)
/// keeps its strong store reference; the engine-internal handle does not, and
/// never leaves the engine.
///
/// ## Safety contract
///
/// Sound only while something outside the walk keeps the store strongly
/// alive. Every entry point that mints one anchors the store for the whole
/// walk — `withExtendedLifetime(store)` around the synchronous walk, a strong
/// closure capture across the asynchronous executor hop — and handles never
/// escape the walk: the rich-target hooks and `NodePrintContext` deliver
/// `materializedNode` products (standalone `Node` trees), never handles.
/// Do not store one beyond the scope that anchored its store.
@usableFromInline
struct UnretainedNodeReference: Hashable {
    /// `unowned(unsafe)` is the point of the type: no ARC on load or copy.
    @usableFromInline
    unowned(unsafe) let store: NodeStore

    @usableFromInline
    let rawIndex: UInt32

    @usableFromInline
    init(store: NodeStore, rawIndex: UInt32) {
        self.store = store
        self.rawIndex = rawIndex
    }

    @usableFromInline
    var compactNode: CompactNode {
        store.compactNode(at: rawIndex)
    }

    @usableFromInline
    static func == (left: UnretainedNodeReference, right: UnretainedNodeReference) -> Bool {
        left.store === right.store && left.rawIndex == right.rawIndex
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(store))
        hasher.combine(rawIndex)
    }
}

/// `DemanglingNode` requires `Sendable`. The handle is a bare pointer plus an
/// index over a deeply immutable `Sendable` class; `@unchecked` only because
/// the compiler cannot see that `unowned(unsafe)` storage is kept alive and
/// unmutated externally (the safety contract above).
extension UnretainedNodeReference: @unchecked Sendable {}

extension UnretainedNodeReference: DemanglingNode {
    @usableFromInline
    var kind: Node.Kind {
        compactNode.kind
    }

    @usableFromInline
    var text: String? {
        store.textOfNode(at: rawIndex)
    }

    @usableFromInline
    var index: UInt64? {
        store.indexPayload(of: compactNode)
    }

    @usableFromInline
    var hasIndex: Bool {
        if case .index = compactNode.payloadKind { return true }
        return false
    }

    @usableFromInline
    var children: ChildrenView {
        ChildrenView(store: store, compactNode: compactNode)
    }

    /// The handle itself: hashes as store identity plus index, exactly the
    /// per-store node identity the printer's fragment cache keys on.
    @usableFromInline
    var printCacheIdentity: UnretainedNodeReference { self }

    @usableFromInline
    var materializedNode: Node {
        store.materializeNode(at: rawIndex)
    }

    @usableFromInline
    func isIdentifier(desired: String) -> Bool {
        guard kind == .identifier else { return false }
        return store.nodeTextMatches(at: rawIndex, expected: desired)
    }

    @usableFromInline
    var isSwiftModule: Bool {
        guard kind == .module else { return false }
        return store.nodeTextMatches(at: rawIndex, expected: stdlibName)
    }

    /// Mirror of `NodeReference.ChildrenView` yielding unretained handles:
    /// the subscript that used to pay one store retain/release per child
    /// access now copies a bare pointer and an index. Child resolution is the
    /// shared `NodeStore.rawChildIndex(of:at:)`.
    @usableFromInline
    struct ChildrenView: RandomAccessCollection {
        @usableFromInline
        typealias Element = UnretainedNodeReference

        @usableFromInline
        typealias Index = Int

        @usableFromInline
        unowned(unsafe) let store: NodeStore

        @usableFromInline
        let compactNode: CompactNode

        @usableFromInline
        init(store: NodeStore, compactNode: CompactNode) {
            self.store = store
            self.compactNode = compactNode
        }

        @usableFromInline
        var startIndex: Int { 0 }

        @usableFromInline
        var endIndex: Int { compactNode.childCount }

        @usableFromInline
        subscript(position: Int) -> UnretainedNodeReference {
            UnretainedNodeReference(store: store, rawIndex: store.rawChildIndex(of: compactNode, at: position))
        }
    }
}

/// See the `Sendable` note on the handle; the view is the same shape.
extension UnretainedNodeReference.ChildrenView: @unchecked Sendable {}

extension UnretainedNodeReference.ChildrenView: DemanglingNodeChildren {}
