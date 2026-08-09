/// An immutable, memory-compact symbol database produced by
/// `NodeStoreBuilder.freeze()`.
///
/// All nodes live in flat contiguous buffers — 12 bytes per node, 4 bytes per
/// child edge beyond two, and deduplicated UTF-8 text bytes — with no per-node
/// heap allocation, object header, or reference counting. The store is fully
/// hash-consed: within one store, structurally equal subtrees have equal
/// indices, so equality checks on `NodeReference` are O(1).
///
/// The store is deeply immutable after freezing, so it is `Sendable` and reads
/// take no locks. See evolution proposal 0001 for the overall design.
///
/// `@unchecked` only because the buffers are self-managed allocations
/// (proposal 0010, step 1) the compiler cannot see the immutability of: every
/// stored property is `let`, and published buffer contents are never written
/// again. A frozen store has no writer at all (freezing consumes the
/// builder). A store serving as a `SharedNodeStore`'s identity anchor
/// (proposal 0010, step 4) has a writer, but it only ever appends past the
/// published counts and republishes the descriptor through the locked slot in
/// `SharedViewState` — elements a reader can reach through any published view
/// are write-once.
public final class NodeStore: @unchecked Sendable {
    /// A stable identifier of a node within its store.
    ///
    /// Indices are minted by `NodeStoreBuilder` and remain valid in the
    /// frozen store. They are only meaningful for the store they came from.
    public struct NodeIndex: Hashable, Sendable {
        @usableFromInline
        let rawValue: UInt32

        #if DEBUG
        /// Debug-only issuance tag (proposal 0009): identifies the builder
        /// (and the store frozen from it) that minted this index.
        /// ``NodeStore/reference(at:)`` and
        /// `NodeStoreBuilder.intern(kind:children:)` compare it against
        /// their own tag, turning the worst cross-store misuse — an
        /// in-range foreign index silently resolving to an unrelated
        /// subtree — into a deterministic precondition failure during
        /// development. Release builds compile the field out entirely:
        /// layout and behavior are unchanged there, and the check is a
        /// development-time diagnostic, not a security boundary.
        ///
        /// Hashing and equality include the tag in debug: same-store
        /// comparisons are unaffected, cross-store ones fail earlier —
        /// semantics only tighten.
        @usableFromInline
        let storeTag: UInt16

        @usableFromInline
        init(rawValue: UInt32, storeTag: UInt16) {
            self.rawValue = rawValue
            self.storeTag = storeTag
        }
        #else
        @usableFromInline
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
        #endif
    }

    // Storage handed over from the builder at freeze (proposal 0010, step 1):
    // the `StoreBuffer` allocations move here by reference, no element copy.
    // Counts are the initialized prefixes; capacity beyond them is the
    // reservation slack `freeze()` deliberately keeps.

    @usableFromInline
    let nodesStorage: StoreBuffer<CompactNode>

    @usableFromInline
    let edgesStorage: StoreBuffer<UInt32>

    @usableFromInline
    let textStorage: StoreBuffer<UInt8>

    /// The frozen store's constant view descriptor (proposal 0010, step 3):
    /// built once at init from the handed-over buffers, resolved by every
    /// read through ``withView(_:)``. For a shared store this holds the empty
    /// initial view and is never read past init — ``withView(_:)`` resolves
    /// through ``sharedViewState`` instead.
    @usableFromInline
    let view: BufferView

    /// Present exactly when this store is the identity anchor of a
    /// `SharedNodeStore` (proposal 0010, step 4): the mutable view slot plus
    /// the buffer keepalive chain. `nil` for every frozen store.
    @usableFromInline
    let sharedViewState: SharedViewState?

    /// Issuance tag inherited from the minting builder; see
    /// `NodeIndex.storeTag`. Stored in every configuration (2 bytes per
    /// store, so `init` keeps one signature); read only in debug.
    @usableFromInline
    let storeTag: UInt16

    /// Snapshot of ``DemanglingRuntimePath/forcesLegacyPath`` at store
    /// creation, copied into every view this store publishes — the store
    /// side of the dual-path seam (ReviewFindingsPR7 F11). A per-access
    /// read would put a `Mutex` acquisition on every text materialization;
    /// the supported way to force the legacy leg is the process-wide env
    /// var, which predates every store the process creates.
    @usableFromInline
    let usesLegacyTextMaterialization: Bool

    init(
        nodesStorage: StoreBuffer<CompactNode>, nodeCount: Int,
        edgesStorage: StoreBuffer<UInt32>, edgeCount: Int,
        textStorage: StoreBuffer<UInt8>, textByteCount: Int,
        textTableIsKnownASCII: Bool,
        storeTag: UInt16
    ) {
        let usesLegacyTextMaterialization = DemanglingRuntimePath.forcesLegacyPath
        self.nodesStorage = nodesStorage
        self.edgesStorage = edgesStorage
        self.textStorage = textStorage
        self.view = BufferView(
            nodes: UnsafeBufferPointer(start: nodesStorage.baseAddress, count: nodeCount),
            edges: UnsafeBufferPointer(start: edgesStorage.baseAddress, count: edgeCount),
            textBytes: UnsafeBufferPointer(start: textStorage.baseAddress, count: textByteCount),
            textTableIsKnownASCII: textTableIsKnownASCII,
            usesLegacyTextMaterialization: usesLegacyTextMaterialization
        )
        self.sharedViewState = nil
        self.usesLegacyTextMaterialization = usesLegacyTextMaterialization
        self.storeTag = storeTag
    }

    /// The shared-store identity anchor (proposal 0010, step 4): starts over
    /// the builder's initial (empty) buffers; every subsequent read resolves
    /// the current descriptor through `sharedViewState`.
    init(
        sharedViewState: SharedViewState,
        nodesStorage: StoreBuffer<CompactNode>,
        edgesStorage: StoreBuffer<UInt32>,
        textStorage: StoreBuffer<UInt8>,
        storeTag: UInt16
    ) {
        let usesLegacyTextMaterialization = DemanglingRuntimePath.forcesLegacyPath
        self.nodesStorage = nodesStorage
        self.edgesStorage = edgesStorage
        self.textStorage = textStorage
        self.view = BufferView(
            nodes: UnsafeBufferPointer(start: nodesStorage.baseAddress, count: 0),
            edges: UnsafeBufferPointer(start: edgesStorage.baseAddress, count: 0),
            textBytes: UnsafeBufferPointer(start: textStorage.baseAddress, count: 0),
            textTableIsKnownASCII: true,
            usesLegacyTextMaterialization: usesLegacyTextMaterialization
        )
        self.sharedViewState = sharedViewState
        self.usesLegacyTextMaterialization = usesLegacyTextMaterialization
        self.storeTag = storeTag
    }

    /// Resolves the current view descriptor and runs `body` over it — the
    /// single read gate every accessor and every walk entry goes through.
    ///
    /// For a frozen store this is a plain load of the constant descriptor
    /// behind one predicted-nil branch. For a shared store it copies the
    /// published descriptor out of the mutable slot (a locked 48-byte copy;
    /// see `SharedViewState`) — walks pin the resolved view once for their
    /// whole duration, per-access reads resolve fresh each time. Stale views
    /// stay safe: retired buffer generations are kept alive, and the
    /// bottom-up invariant (step 2) means any view covering a root index
    /// covers the root's whole subtree.
    @usableFromInline
    func withView<Result>(_ body: (BufferView) throws -> Result) rethrows -> Result {
        if let sharedViewState {
            return try body(sharedViewState.currentView())
        }
        return try body(view)
    }

    /// The resolved view as a value, for direct-return borrows that cannot
    /// take a closure (the `@_lifetime` span accessors).
    @usableFromInline
    var currentView: BufferView {
        withView { $0 }
    }

    /// Wraps a raw index produced by in-store navigation (child resolution)
    /// as a `NodeIndex` carrying this store's issuance tag. Internal on
    /// purpose: raw indices only come from walking this store's own buffers,
    /// which cannot produce a foreign index.
    @usableFromInline
    func nodeIndex(forRaw rawIndex: UInt32) -> NodeIndex {
        #if DEBUG
        return NodeIndex(rawValue: rawIndex, storeTag: storeTag)
        #else
        return NodeIndex(rawValue: rawIndex)
        #endif
    }

    // MARK: - Statistics

    /// Number of unique nodes in the store.
    public var nodeCount: Int { withView { $0.nodes.count } }

    /// Number of child-edge slots used by nodes with three or more children.
    public var edgeCount: Int { withView { $0.edges.count } }

    /// Number of deduplicated UTF-8 text bytes.
    public var textByteCount: Int { withView { $0.textBytes.count } }

    /// Total payload bytes of the flat buffers (excluding the buffers'
    /// own headers and growth slack).
    public var storageByteCount: Int {
        withView { resolvedView in
            resolvedView.nodes.count * MemoryLayout<CompactNode>.stride
                + resolvedView.edges.count * MemoryLayout<UInt32>.stride
                + resolvedView.textBytes.count
        }
    }

    // MARK: - Access

    /// Returns a reference to the node at the given index.
    ///
    /// References minted here are directly comparable with `==` and usable as
    /// `Set` / `Dictionary` keys: this store is hash-consed, so equal indices
    /// mean equal structure. That equivalence is per-store — for references
    /// spanning stores use `structurallyEquals(_:)` / `structuralHash(into:)`.
    ///
    /// - Precondition: `nodeIndex` was minted by this store's builder and is
    ///   within bounds. Debug builds verify the minting store through the
    ///   index's issuance tag (proposal 0009), so a foreign index fails this
    ///   precondition deterministically during development.
    ///
    ///   In release the tag does not exist and a `NodeIndex` is a bare
    ///   offset, so only the bound can be checked; keeping indices with
    ///   their store is the caller's job. There, passing a foreign index is
    ///   undefined behavior, not a checked error, and it has two shapes. If
    ///   it lands in range it resolves to whatever node lives at that offset
    ///   — silently wrong, but well-formed. It can also *trap*: the node it
    ///   resolves to carries edge and text offsets minted against the other
    ///   store, and those are not bounds-checked, so reading its children or
    ///   text can index past this store's buffers. Do not write recovery
    ///   code against the silent case alone.
    public func reference(at nodeIndex: NodeIndex) -> NodeReference {
        #if DEBUG
        precondition(
            nodeIndex.storeTag == storeTag,
            "NodeIndex was minted by a different builder/store — an index is only valid in the store whose builder issued it"
        )
        #endif
        // One view resolution, not two: the public `nodeCount` opens its own
        // `withView`, which on a shared store is a second locked descriptor
        // copy per minted reference (ReviewFindingsPR7 F14).
        withView { resolvedView in
            precondition(Int(nodeIndex.rawValue) < resolvedView.nodes.count, "NodeIndex out of range for this store")
        }
        return NodeReference(store: self, nodeIndex: nodeIndex)
    }

    @usableFromInline
    func compactNode(at rawIndex: UInt32) -> CompactNode {
        withView { $0.compactNode(at: rawIndex) }
    }

    @usableFromInline
    func text(offset: UInt32, length: UInt32) -> String {
        withView { $0.text(offset: offset, length: length) }
    }

    // MARK: - Shared node accessors

    // The single implementations live on `BufferView` (proposal 0010,
    // step 3); these delegators keep the store-level entry points for
    // per-access consumers (`NodeReference` and its children view). Walks pin
    // a view once at their entry instead of coming through here per node.

    /// Raw index of the `position`-th child of `compact`.
    @usableFromInline
    func rawChildIndex(of compact: CompactNode, at position: Int) -> UInt32 {
        withView { $0.rawChildIndex(of: compact, at: position) }
    }

    /// Span-reading counterpart of ``rawChildIndex(of:at:)`` for walks that
    /// borrowed the buffers up front (`withSpans(_:)`). Keep the two switches
    /// in lockstep — they are the same resolution rule over two buffer
    /// representations.
    @usableFromInline
    static func rawChildIndex(of compact: CompactNode, at position: Int, edges edgeSpan: Span<UInt32>) -> UInt32 {
        switch compact.payloadKind {
        case .oneChild:
            precondition(position == 0, "Child index out of range")
            return compact.payloadWord0
        case .twoChildren:
            switch position {
            case 0: return compact.payloadWord0
            case 1: return compact.payloadWord1
            default: preconditionFailure("Child index out of range")
            }
        case .manyChildren:
            precondition(position >= 0 && position < Int(compact.payloadWord1), "Child index out of range")
            return edgeSpan[Int(compact.payloadWord0) + position]
        case .none, .index, .text:
            preconditionFailure("Child index out of range for a node without children")
        }
    }

    /// The index payload of `compact`, if it carries one.
    @usableFromInline
    func indexPayload(of compact: CompactNode) -> UInt64? {
        withView { $0.indexPayload(of: compact) }
    }

    /// The contents of `compact` in exactly the form ``Node/contents``
    /// reports them; see `BufferView.contents(of:)`.
    @usableFromInline
    func contents(of compact: CompactNode) -> Node.Contents {
        withView { $0.contents(of: compact) }
    }

    /// Text of the node at `rawIndex` in exactly the form `Node.text` reports
    /// it; see `BufferView.textOfNode(at:)`.
    func textOfNode(at rawIndex: UInt32) -> String? {
        withView { $0.textOfNode(at: rawIndex) }
    }

    /// Borrows the stored text bytes of the node at `rawIndex` (proposal
    /// 0008, B1); see `BufferView.withTextUTF8(at:_:)`.
    func withTextUTF8<Result>(at rawIndex: UInt32, _ body: (Span<UInt8>) throws -> Result) rethrows -> Result? {
        try withView { try $0.withTextUTF8(at: rawIndex, body) }
    }

    /// Allocation-free text comparison against an ASCII needle; see
    /// `BufferView.nodeTextMatches(at:expected:)`.
    func nodeTextMatches(at rawIndex: UInt32, expected: String) -> Bool {
        withView { $0.nodeTextMatches(at: rawIndex, expected: expected) }
    }

    // MARK: - Buffer borrows (proposal 0008, B2)

    /// Borrows the three flat buffers at once for a tight read loop, hoisting
    /// the class-property loads out of the loop.
    ///
    /// Single-path since the buffers became self-managed (proposal 0010,
    /// step 1): `UnsafeBufferPointer.span` is available on every supported
    /// runtime, so the 0008 dual path this method used to carry — modern
    /// `.span` properties versus nested `withUnsafeBufferPointer` bridges —
    /// collapsed into one spelling. `self` anchors the storage for the whole
    /// call; the locals anchor the spans' borrows.
    func withSpans<Result>(_ body: (Span<CompactNode>, Span<UInt32>, Span<UInt8>) throws -> Result) rethrows -> Result {
        try withView { resolvedView in
            let nodesBuffer = resolvedView.nodes
            let edgesBuffer = resolvedView.edges
            let textBuffer = resolvedView.textBytes
            return try body(nodesBuffer.span, edgesBuffer.span, textBuffer.span)
        }
    }

    #if hasFeature(Lifetimes)
    /// Direct-return borrowed view of the string table (proposal 0008).
    ///
    /// Dual-gated on purpose: the `@_lifetime` spelling needs the `Lifetimes`
    /// compiler feature, and the `.span` property the implementation returns
    /// needs the macOS 26 runtime — on older runtimes use ``withSpans(_:)``
    /// or the closure-style accessors. `nodesSpan()`/`edgesSpan()` stay
    /// internal because `CompactNode` is not public API.
    @_spi(Internals)
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
    @_lifetime(borrow self)
    public borrowing func textBytesSpan() -> Span<UInt8> {
        // The span is formed over the raw buffer and would otherwise be
        // scoped to the local `UnsafeBufferPointer`; the override rebinds its
        // dependence to `self`, which owns the allocation through the stored
        // `StoreBuffer` (for a shared store, through the retirement chain) —
        // exactly the contract `@_lifetime(borrow self)` states.
        let textBuffer = currentView.textBytes
        let span = textBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }

    /// Internal direct-return borrow of the node buffer; see
    /// ``textBytesSpan()`` for the gating and the lifetime-override
    /// reasoning.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
    @_lifetime(borrow self)
    borrowing func nodesSpan() -> Span<CompactNode> {
        let nodesBuffer = currentView.nodes
        let span = nodesBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }

    /// Internal direct-return borrow of the edge buffer; see
    /// ``textBytesSpan()`` for the gating and the lifetime-override
    /// reasoning.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
    @_lifetime(borrow self)
    borrowing func edgesSpan() -> Span<UInt32> {
        let edgesBuffer = currentView.edges
        let span = edgesBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }
    #endif

    // MARK: - Materialization

    /// Rebuilds a standalone `Node` tree for one store index; see
    /// `BufferView.materializeNode(at:)` for the walk and its
    /// sharing-preservation contract.
    func materializeNode(at rawIndex: UInt32) -> Node {
        withView { $0.materializeNode(at: rawIndex) }
    }
}
