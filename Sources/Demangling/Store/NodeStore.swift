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
public final class NodeStore: Sendable {
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

    @usableFromInline
    let nodes: ContiguousArray<CompactNode>

    @usableFromInline
    let edges: ContiguousArray<UInt32>

    @usableFromInline
    let textBytes: ContiguousArray<UInt8>

    /// Issuance tag inherited from the minting builder; see
    /// `NodeIndex.storeTag`. Stored in every configuration (2 bytes per
    /// store, so `init` keeps one signature); read only in debug.
    @usableFromInline
    let storeTag: UInt16

    init(
        nodes: ContiguousArray<CompactNode>,
        edges: ContiguousArray<UInt32>,
        textBytes: ContiguousArray<UInt8>,
        storeTag: UInt16
    ) {
        self.nodes = nodes
        self.edges = edges
        self.textBytes = textBytes
        self.storeTag = storeTag
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
    public var nodeCount: Int { nodes.count }

    /// Number of child-edge slots used by nodes with three or more children.
    public var edgeCount: Int { edges.count }

    /// Number of deduplicated UTF-8 text bytes.
    public var textByteCount: Int { textBytes.count }

    /// Total payload bytes of the flat buffers (excluding the containers'
    /// own headers and growth slack).
    public var storageByteCount: Int {
        nodes.count * MemoryLayout<CompactNode>.stride
            + edges.count * MemoryLayout<UInt32>.stride
            + textBytes.count
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
        precondition(Int(nodeIndex.rawValue) < nodes.count, "NodeIndex out of range for this store")
        return NodeReference(store: self, nodeIndex: nodeIndex)
    }

    @usableFromInline
    func compactNode(at rawIndex: UInt32) -> CompactNode {
        nodes[Int(rawIndex)]
    }

    @usableFromInline
    func text(offset: UInt32, length: UInt32) -> String {
        let start = Int(offset)
        let end = start + Int(length)
        // Every stored text was interned from a whole `String.utf8` payload,
        // so any (offset, length) a node payload produces is a complete valid
        // UTF-8 text — unchecked materialization skips only the revalidation
        // scan (proposal 0008, B1). Legacy runtimes keep the validating
        // decode.
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
            return textBytes[start ..< end].withUnsafeBufferPointer { buffer in
                String(copying: UTF8Span(unchecked: buffer.span))
            }
        }
        return String(decoding: textBytes[start ..< end], as: UTF8.self)
    }

    // MARK: - Shared node accessors

    // The single implementations behind both handle types (`NodeReference`
    // and the walk-internal `UnretainedNodeReference`) — a parallel copy on
    // either handle would silently drift (proposal 0008, B2).

    /// Raw index of the `position`-th child of `compact`.
    @usableFromInline
    func rawChildIndex(of compact: CompactNode, at position: Int) -> UInt32 {
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
            return edges[Int(compact.payloadWord0) + position]
        case .none, .index, .text:
            preconditionFailure("Child index out of range for a node without children")
        }
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
        guard case .index = compact.payloadKind else { return nil }
        return UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32)
    }

    /// The contents of `compact` in exactly the form ``Node/contents``
    /// reports them — the single re-encoding point shared by
    /// `NodeReference.nodeContents` and the structural-digest walk, kept
    /// single so it cannot drift from `Node.hash(into:)`'s encoding.
    ///
    /// Deliberately reports `.none` for `.dependentGenericParamType` (whose
    /// name ``textOfNode(at:)`` synthesizes): `Node` stores depth and index
    /// as children there, so its `contents` is `.none` and so must this.
    @usableFromInline
    func contents(of compact: CompactNode) -> Node.Contents {
        switch compact.payloadKind {
        case .text:
            return .text(text(offset: compact.payloadWord0, length: compact.payloadWord1))
        case .index:
            return .index(UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32))
        case .none, .oneChild, .twoChildren, .manyChildren:
            return .none
        }
    }

    /// Text of the node at `rawIndex` in exactly the form `Node.text` reports
    /// it: stored text for `.text` payloads, plus the synthesized generic
    /// parameter name for `.dependentGenericParamType` (which stores depth and
    /// index as children; the printer relies on the synthesis).
    func textOfNode(at rawIndex: UInt32) -> String? {
        let compact = compactNode(at: rawIndex)
        if case .text = compact.payloadKind {
            return text(offset: compact.payloadWord0, length: compact.payloadWord1)
        }
        if compact.kind == .dependentGenericParamType {
            guard compact.childCount >= 2,
                  let depth = indexPayload(of: compactNode(at: rawChildIndex(of: compact, at: 0))),
                  let parameterIndex = indexPayload(of: compactNode(at: rawChildIndex(of: compact, at: 1)))
            else { return nil }
            return genericParameterName(depth: depth, index: parameterIndex)
        }
        return nil
    }

    /// Borrows the stored text bytes of the node at `rawIndex` (proposal
    /// 0008, B1). Returns nil — without calling `body` — when the node stores
    /// no text; `.dependentGenericParamType`'s synthesized name is not stored
    /// text (use ``textOfNode(at:)`` for the composed form).
    func withTextUTF8<Result>(at rawIndex: UInt32, _ body: (Span<UInt8>) throws -> Result) rethrows -> Result? {
        let compact = compactNode(at: rawIndex)
        guard case .text = compact.payloadKind else { return nil }
        let start = Int(compact.payloadWord0)
        let end = start + Int(compact.payloadWord1)
        return try textBytes[start ..< end].withUnsafeBufferPointer { buffer in
            try body(buffer.span)
        }
    }

    /// Allocation-free text comparison against an ASCII needle, with the
    /// `String`-comparison fallback for non-ASCII needles (Unicode canonical
    /// equivalence) and for nodes whose text is synthesized rather than
    /// stored.
    func nodeTextMatches(at rawIndex: UInt32, expected: String) -> Bool {
        let expectedUTF8 = expected.utf8
        guard expectedUTF8.allSatisfy({ $0 < 0x80 }) else {
            return textOfNode(at: rawIndex) == expected
        }
        let storedByteComparison = withTextUTF8(at: rawIndex) { spanBytes -> Bool in
            guard spanBytes.count == expectedUTF8.count else { return false }
            var byteOffset = 0
            for expectedByte in expectedUTF8 {
                guard spanBytes[byteOffset] == expectedByte else { return false }
                byteOffset += 1
            }
            return true
        }
        return storedByteComparison ?? (textOfNode(at: rawIndex) == expected)
    }

    // MARK: - Buffer borrows (proposal 0008, B2)

    /// Borrows the three flat buffers at once for a tight read loop, hoisting
    /// the class-property loads out of the loop. Axis-1 dual path: modern
    /// runtimes take the `.span` properties directly, older ones bridge
    /// through `withUnsafeBufferPointer`.
    func withSpans<Result>(_ body: (Span<CompactNode>, Span<UInt32>, Span<UInt8>) throws -> Result) rethrows -> Result {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
            // Local CoW copies (three retains, no element copies) anchor the
            // buffers for the spans' scope — a span taken straight off a
            // class property is scoped to the property access and cannot even
            // reach the `body` call.
            let nodesBuffer = nodes
            let edgesBuffer = edges
            let textBytesBuffer = textBytes
            return try body(nodesBuffer.span, edgesBuffer.span, textBytesBuffer.span)
        }
        return try nodes.withUnsafeBufferPointer { nodeBuffer in
            try edges.withUnsafeBufferPointer { edgeBuffer in
                try textBytes.withUnsafeBufferPointer { textBuffer in
                    try body(nodeBuffer.span, edgeBuffer.span, textBuffer.span)
                }
            }
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
        // A span taken straight off the class property is scoped to that
        // property access and may not leave the method; the local CoW copy
        // (one retain, no element copies) anchors the shared buffer while the
        // span is formed, and the override rebinds its dependence to `self`,
        // which owns the same buffer through the immutable stored property —
        // exactly the contract `@_lifetime(borrow self)` states.
        let sharedBuffer = textBytes
        let span = sharedBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }

    /// Internal direct-return borrow of the node buffer; see
    /// ``textBytesSpan()`` for the gating and the lifetime-override
    /// reasoning.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
    @_lifetime(borrow self)
    borrowing func nodesSpan() -> Span<CompactNode> {
        let sharedBuffer = nodes
        let span = sharedBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }

    /// Internal direct-return borrow of the edge buffer; see
    /// ``textBytesSpan()`` for the gating and the lifetime-override
    /// reasoning.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
    @_lifetime(borrow self)
    borrowing func edgesSpan() -> Span<UInt32> {
        let sharedBuffer = edges
        let span = sharedBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }
    #endif

    // MARK: - Materialization

    /// Child indices of the given node, in order.
    private func childIndices(of compact: CompactNode) -> [UInt32] {
        switch compact.payloadKind {
        case .none, .index, .text:
            return []
        case .oneChild:
            return [compact.payloadWord0]
        case .twoChildren:
            return [compact.payloadWord0, compact.payloadWord1]
        case .manyChildren:
            let edgesStart = Int(compact.payloadWord0)
            let childCount = Int(compact.payloadWord1)
            return (edgesStart ..< (edgesStart + childCount)).map { edges[$0] }
        }
    }

    /// Builds the `Node` for one store index from already-materialized children.
    private func makeNode(from compact: CompactNode, children: [Node]) -> Node {
        switch compact.payloadKind {
        case .none:
            return Node(kind: compact.kind)
        case .index:
            return Node(kind: compact.kind, index: UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32))
        case .text:
            return Node(kind: compact.kind, text: text(offset: compact.payloadWord0, length: compact.payloadWord1))
        case .oneChild, .twoChildren, .manyChildren:
            return Node(kind: compact.kind, children: children)
        }
    }

    /// One suspended level of ``materializeNode(at:)``'s walk.
    private struct MaterializeFrame {
        let rawIndex: UInt32
        let compact: CompactNode
        let childIndices: [UInt32]
        var nextChildPosition: Int
        var materializedChildren: [Node]
    }

    /// Rebuilds a standalone `Node` tree for one store index.
    ///
    /// The returned tree is freshly constructed and does not interact with the
    /// global `NodeCache`. The store is hash-consed, so a subtree referenced
    /// from multiple parents is a single index; the memo rebuilds each index
    /// once and reuses the instance, preserving the store's DAG shape.
    /// Expanding instead would multiply node count for symbols with heavy
    /// substitution sharing and defeat the printer's per-instance memoization.
    ///
    /// Walked with an explicit stack. This is reached from the remangling
    /// bridge and from rich printer targets, both of which hand the result
    /// straight to another whole-tree walk, so a recursive version would stack
    /// two full-depth traversals of the deepest trees the store holds.
    func materializeNode(at rawIndex: UInt32) -> Node {
        var materializedByIndex: [UInt32: Node] = [:]
        var frames: [MaterializeFrame] = []
        var completedChild: Node?

        func pushFrame(for index: UInt32) {
            let compact = compactNode(at: index)
            let indices = childIndices(of: compact)
            var frame = MaterializeFrame(
                rawIndex: index,
                compact: compact,
                childIndices: indices,
                nextChildPosition: 0,
                materializedChildren: []
            )
            frame.materializedChildren.reserveCapacity(indices.count)
            frames.append(frame)
        }

        pushFrame(for: rawIndex)

        while var frame = frames.popLast() {
            if let child = completedChild {
                frame.materializedChildren.append(child)
                completedChild = nil
            }

            if frame.nextChildPosition < frame.childIndices.count {
                let childIndex = frame.childIndices[frame.nextChildPosition]
                frame.nextChildPosition += 1
                frames.append(frame)

                // The store is hash-consed, so a subtree referenced from several
                // parents is one index; the memo rebuilds it once and reuses the
                // instance, preserving the store's DAG shape.
                if let shared = materializedByIndex[childIndex] {
                    completedChild = shared
                } else {
                    pushFrame(for: childIndex)
                }
                continue
            }

            let node = makeNode(from: frame.compact, children: frame.materializedChildren)
            materializedByIndex[frame.rawIndex] = node
            if frames.isEmpty {
                return node
            }
            completedChild = node
        }

        // Unreachable: the loop returns as soon as the root frame completes.
        return Node(kind: compactNode(at: rawIndex).kind)
    }
}
