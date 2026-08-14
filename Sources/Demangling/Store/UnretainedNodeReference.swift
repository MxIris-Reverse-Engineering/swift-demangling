/// Engine-internal walk handle for store-backed printing (proposal 0008 B2,
/// re-based on the view descriptor by proposal 0010 step 3): a raw pointer to
/// the walk's pinned `NodeStore.BufferView` plus a node index. Copying the
/// handle — which a walk does once per visited child — and resolving nodes
/// through it are pure pointer operations: zero ARC traffic by construction.
///
/// The 0008 shape held an `Unmanaged<NodeStore>` and resolved every access
/// through `_withUnsafeGuaranteedRef` to suppress the retain/release the
/// compiler otherwise inserts per store method call. Pinning the buffer view
/// once at the walk entry retires that ceremony: the handle no longer touches
/// the store object at all, and — equally important for the shared store — a
/// whole walk reads one consistent view no matter how the store grows
/// underneath it.
///
/// ## Safety contract
///
/// Sound only inside a scope that (a) keeps the store strongly alive — which
/// keeps every buffer the view addresses alive, including retired generations
/// of a shared store — and (b) keeps the pointed-to view value alive
/// (`withUnsafePointer(to:)` at the walk entry; the frame stays live across a
/// `StackSafeExecutor` hop because the submitting call blocks on it). Every
/// mint site anchors both for the whole walk, and handles never escape the
/// walk: the rich-target hooks and `NodePrintContext` deliver
/// `materializedNode` products (standalone `Node` trees), never handles.
/// Do not store one beyond the scope that anchored it.
@usableFromInline
struct UnretainedNodeReference: Hashable {
    @usableFromInline
    let viewPointer: UnsafePointer<NodeStore.BufferView>

    @usableFromInline
    let rawIndex: UInt32

    @usableFromInline
    init(viewPointer: UnsafePointer<NodeStore.BufferView>, rawIndex: UInt32) {
        self.viewPointer = viewPointer
        self.rawIndex = rawIndex
    }

    @usableFromInline
    var compactNode: CompactNode {
        viewPointer.pointee.compactNode(at: rawIndex)
    }

    /// One walk pins one view, so within a walk the pointer is constant and
    /// identity reduces to the index — exactly the per-store node identity
    /// the printer's fragment cache keys on.
    @usableFromInline
    static func == (left: UnretainedNodeReference, right: UnretainedNodeReference) -> Bool {
        left.viewPointer == right.viewPointer && left.rawIndex == right.rawIndex
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        hasher.combine(viewPointer)
        hasher.combine(rawIndex)
    }
}

/// `DemanglingNode` requires `Sendable`. The handle is a bare pointer plus an
/// index over immutable published buffers; `@unchecked` only because the
/// compiler cannot see that the pointed-to view and the buffers it addresses
/// are kept alive and unmutated externally (the safety contract above).
extension UnretainedNodeReference: @unchecked Sendable {}

extension UnretainedNodeReference: DemanglingNode {
    /// Overrides the protocol's asynchronous default, which suspends on a
    /// continuation instead of blocking.
    ///
    /// The handle's safety contract requires the `withUnsafePointer(to:)`
    /// scope that minted it to outlive the walk. That holds across the
    /// synchronous executor hop because the submitting call blocks on it; it
    /// does not hold across a suspension, where the submitting frame — and
    /// with it the anchoring scope — can unwind while the closure is still
    /// pending, leaving the walk to dereference a dead stack slot. There is
    /// no legal way to await one of these handles, so run the same blocking
    /// walk rather than leaving an inherited spelling that compiles.
    ///
    /// Spelled as the engine call rather than as `runPrintWalk(using:)`,
    /// which would resolve to this asynchronous overload and recurse.
    @usableFromInline
    func runPrintWalk(using options: DemangleOptions) async -> String {
        DemanglingPrinter<String, UnretainedNodeReference>.print(self, options: options)
    }

    @usableFromInline
    var kind: Node.Kind {
        compactNode.kind
    }

    @usableFromInline
    var text: String? {
        viewPointer.pointee.textOfNode(at: rawIndex)
    }

    @usableFromInline
    var index: UInt64? {
        viewPointer.pointee.indexPayload(of: compactNode)
    }

    @usableFromInline
    var hasIndex: Bool {
        if case .index = compactNode.payloadKind { return true }
        return false
    }

    @usableFromInline
    var children: ChildrenView {
        ChildrenView(viewPointer: viewPointer, compactNode: compactNode)
    }

    /// The handle itself; see the `==` note — per-walk view constancy makes
    /// this the per-store node identity.
    @usableFromInline
    var printCacheIdentity: UnretainedNodeReference { self }

    @usableFromInline
    var materializedNode: Node {
        viewPointer.pointee.materializeNode(at: rawIndex)
    }

    @usableFromInline
    func isIdentifier(desired: String) -> Bool {
        guard kind == .identifier else { return false }
        return viewPointer.pointee.nodeTextMatches(at: rawIndex, expected: desired)
    }

    @usableFromInline
    var isSwiftModule: Bool {
        guard kind == .module else { return false }
        return viewPointer.pointee.nodeTextMatches(at: rawIndex, expected: stdlibName)
    }

    /// Mirror of `NodeReference.ChildrenView` yielding view-pinned handles:
    /// child resolution is `BufferView.rawChildIndex(of:at:)` through the
    /// walk's pinned view, and the subscript copies a bare pointer and an
    /// index.
    @usableFromInline
    struct ChildrenView: RandomAccessCollection {
        @usableFromInline
        typealias Element = UnretainedNodeReference

        @usableFromInline
        typealias Index = Int

        @usableFromInline
        let viewPointer: UnsafePointer<NodeStore.BufferView>

        @usableFromInline
        let compactNode: CompactNode

        @usableFromInline
        init(viewPointer: UnsafePointer<NodeStore.BufferView>, compactNode: CompactNode) {
            self.viewPointer = viewPointer
            self.compactNode = compactNode
        }

        @usableFromInline
        var startIndex: Int { 0 }

        @usableFromInline
        var endIndex: Int { compactNode.childCount }

        @usableFromInline
        subscript(position: Int) -> UnretainedNodeReference {
            UnretainedNodeReference(
                viewPointer: viewPointer,
                rawIndex: viewPointer.pointee.rawChildIndex(of: compactNode, at: position)
            )
        }
    }
}

/// See the `Sendable` note on the handle; the view is the same shape.
extension UnretainedNodeReference.ChildrenView: @unchecked Sendable {}

extension UnretainedNodeReference.ChildrenView: DemanglingNodeChildren {}
