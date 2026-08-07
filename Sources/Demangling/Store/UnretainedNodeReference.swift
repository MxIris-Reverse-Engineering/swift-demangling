/// Engine-internal walk handle for store-backed printing (proposal 0008, B2):
/// `NodeReference` minus the retain. The store is held as `Unmanaged` and
/// every access goes through `_withUnsafeGuaranteedRef`, so copying the
/// handle — which a walk does once per visited child — and calling store
/// methods through it produce zero ARC traffic. This is the same layering as
/// swift-syntax's `RawSyntaxArenaRef`: the public value (`NodeReference`)
/// keeps its strong store reference; the engine-internal handle does not, and
/// never leaves the engine.
///
/// `unowned(unsafe)` storage was the first shape here and turned out not to
/// be enough: reading the property yields a value the compiler then guards
/// with a retain/release pair around every method call on it, which the
/// acceptance harness measured at roughly one pair per visited node.
/// `Unmanaged` + `_withUnsafeGuaranteedRef` (a long-stable underscored stdlib
/// primitive, `@_transparent` to a bare pointer use) is the spelling that
/// actually compiles to zero ARC.
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
    @usableFromInline
    let storeReference: Unmanaged<NodeStore>

    @usableFromInline
    let rawIndex: UInt32

    @usableFromInline
    init(store: NodeStore, rawIndex: UInt32) {
        self.storeReference = Unmanaged.passUnretained(store)
        self.rawIndex = rawIndex
    }

    @usableFromInline
    init(storeReference: Unmanaged<NodeStore>, rawIndex: UInt32) {
        self.storeReference = storeReference
        self.rawIndex = rawIndex
    }

    /// The single access path to the store: guaranteed (+0) for the duration
    /// of `body`, no retain/release emitted. Sound under the safety contract
    /// above — the walk entry anchors the store for longer than any `body`.
    @usableFromInline
    func withStore<Result>(_ body: (NodeStore) -> Result) -> Result {
        storeReference._withUnsafeGuaranteedRef(body)
    }

    @usableFromInline
    var compactNode: CompactNode {
        withStore { $0.compactNode(at: rawIndex) }
    }

    @usableFromInline
    static func == (left: UnretainedNodeReference, right: UnretainedNodeReference) -> Bool {
        left.storeReference.toOpaque() == right.storeReference.toOpaque() && left.rawIndex == right.rawIndex
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        hasher.combine(storeReference.toOpaque())
        hasher.combine(rawIndex)
    }
}

/// `DemanglingNode` requires `Sendable`. The handle is a bare pointer plus an
/// index over a deeply immutable `Sendable` class; `@unchecked` only because
/// the compiler cannot see that the unmanaged reference is kept alive and
/// unmutated externally (the safety contract above).
extension UnretainedNodeReference: @unchecked Sendable {}

extension UnretainedNodeReference: DemanglingNode {
    @usableFromInline
    var kind: Node.Kind {
        compactNode.kind
    }

    @usableFromInline
    var text: String? {
        withStore { $0.textOfNode(at: rawIndex) }
    }

    @usableFromInline
    var index: UInt64? {
        withStore { $0.indexPayload(of: $0.compactNode(at: rawIndex)) }
    }

    @usableFromInline
    var hasIndex: Bool {
        if case .index = compactNode.payloadKind { return true }
        return false
    }

    @usableFromInline
    var children: ChildrenView {
        ChildrenView(storeReference: storeReference, compactNode: compactNode)
    }

    /// The handle itself: hashes as store identity plus index, exactly the
    /// per-store node identity the printer's fragment cache keys on.
    @usableFromInline
    var printCacheIdentity: UnretainedNodeReference { self }

    @usableFromInline
    var materializedNode: Node {
        withStore { $0.materializeNode(at: rawIndex) }
    }

    @usableFromInline
    func isIdentifier(desired: String) -> Bool {
        guard kind == .identifier else { return false }
        return withStore { $0.nodeTextMatches(at: rawIndex, expected: desired) }
    }

    @usableFromInline
    var isSwiftModule: Bool {
        guard kind == .module else { return false }
        return withStore { $0.nodeTextMatches(at: rawIndex, expected: stdlibName) }
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
        let storeReference: Unmanaged<NodeStore>

        @usableFromInline
        let compactNode: CompactNode

        @usableFromInline
        init(storeReference: Unmanaged<NodeStore>, compactNode: CompactNode) {
            self.storeReference = storeReference
            self.compactNode = compactNode
        }

        @usableFromInline
        var startIndex: Int { 0 }

        @usableFromInline
        var endIndex: Int { compactNode.childCount }

        @usableFromInline
        subscript(position: Int) -> UnretainedNodeReference {
            UnretainedNodeReference(
                storeReference: storeReference,
                rawIndex: storeReference._withUnsafeGuaranteedRef { $0.rawChildIndex(of: compactNode, at: position) }
            )
        }
    }
}

/// See the `Sendable` note on the handle; the view is the same shape.
extension UnretainedNodeReference.ChildrenView: @unchecked Sendable {}

extension UnretainedNodeReference.ChildrenView: DemanglingNodeChildren {}
