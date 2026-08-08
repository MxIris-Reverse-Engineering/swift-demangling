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
/// stored property is `let`, the `StoreBuffer` contents are written only by
/// the builder this store was frozen from, and freezing consumes the builder,
/// so no writer exists once the store does.
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

    /// Number of unique nodes in the store.
    public let nodeCount: Int

    /// Number of child-edge slots used by nodes with three or more children.
    public let edgeCount: Int

    /// Number of deduplicated UTF-8 text bytes.
    public let textByteCount: Int

    /// Issuance tag inherited from the minting builder; see
    /// `NodeIndex.storeTag`. Stored in every configuration (2 bytes per
    /// store, so `init` keeps one signature); read only in debug.
    @usableFromInline
    let storeTag: UInt16

    init(
        nodesStorage: StoreBuffer<CompactNode>, nodeCount: Int,
        edgesStorage: StoreBuffer<UInt32>, edgeCount: Int,
        textStorage: StoreBuffer<UInt8>, textByteCount: Int,
        storeTag: UInt16
    ) {
        self.nodesStorage = nodesStorage
        self.nodeCount = nodeCount
        self.edgesStorage = edgesStorage
        self.edgeCount = edgeCount
        self.textStorage = textStorage
        self.textByteCount = textByteCount
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

    /// Total payload bytes of the flat buffers (excluding the buffers'
    /// own headers and growth slack).
    public var storageByteCount: Int {
        nodeCount * MemoryLayout<CompactNode>.stride
            + edgeCount * MemoryLayout<UInt32>.stride
            + textByteCount
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
        precondition(Int(nodeIndex.rawValue) < nodeCount, "NodeIndex out of range for this store")
        return NodeReference(store: self, nodeIndex: nodeIndex)
    }

    @usableFromInline
    func compactNode(at rawIndex: UInt32) -> CompactNode {
        // Bounds-checked in release too, matching the `ContiguousArray`
        // subscript this replaced: an out-of-range index traps instead of
        // reading past the allocation.
        precondition(Int(rawIndex) < nodeCount, "Node index out of range for this store")
        return nodesStorage.baseAddress[Int(rawIndex)]
    }

    @usableFromInline
    func text(offset: UInt32, length: UInt32) -> String {
        let start = Int(offset)
        let end = start + Int(length)
        precondition(end <= textByteCount, "Text range out of range for this store")
        let textBuffer = UnsafeBufferPointer(start: textStorage.baseAddress + start, count: Int(length))
        // Every stored text was interned from a whole `String.utf8` payload,
        // so any (offset, length) a node payload produces is a complete valid
        // UTF-8 text — unchecked materialization skips only the revalidation
        // scan (proposal 0008, B1). Legacy runtimes keep the validating
        // decode.
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
            return String(copying: UTF8Span(unchecked: textBuffer.span))
        }
        return String(decoding: textBuffer, as: UTF8.self)
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
            let edgeIndex = Int(compact.payloadWord0) + position
            precondition(edgeIndex < edgeCount, "Edge index out of range for this store")
            return edgesStorage.baseAddress[edgeIndex]
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
        let length = Int(compact.payloadWord1)
        precondition(start + length <= textByteCount, "Text range out of range for this store")
        let textBuffer = UnsafeBufferPointer(start: textStorage.baseAddress + start, count: length)
        return try body(textBuffer.span)
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
    /// the class-property loads out of the loop.
    ///
    /// Single-path since the buffers became self-managed (proposal 0010,
    /// step 1): `UnsafeBufferPointer.span` is available on every supported
    /// runtime, so the 0008 dual path this method used to carry — modern
    /// `.span` properties versus nested `withUnsafeBufferPointer` bridges —
    /// collapsed into one spelling. `self` anchors the storage for the whole
    /// call; the locals anchor the spans' borrows.
    func withSpans<Result>(_ body: (Span<CompactNode>, Span<UInt32>, Span<UInt8>) throws -> Result) rethrows -> Result {
        let nodesBuffer = UnsafeBufferPointer(start: nodesStorage.baseAddress, count: nodeCount)
        let edgesBuffer = UnsafeBufferPointer(start: edgesStorage.baseAddress, count: edgeCount)
        let textBuffer = UnsafeBufferPointer(start: textStorage.baseAddress, count: textByteCount)
        return try body(nodesBuffer.span, edgesBuffer.span, textBuffer.span)
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
        // dependence to `self`, which owns the allocation through the
        // immutable stored `StoreBuffer` — exactly the contract
        // `@_lifetime(borrow self)` states.
        let textBuffer = UnsafeBufferPointer(start: textStorage.baseAddress, count: textByteCount)
        let span = textBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }

    /// Internal direct-return borrow of the node buffer; see
    /// ``textBytesSpan()`` for the gating and the lifetime-override
    /// reasoning.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
    @_lifetime(borrow self)
    borrowing func nodesSpan() -> Span<CompactNode> {
        let nodesBuffer = UnsafeBufferPointer(start: nodesStorage.baseAddress, count: nodeCount)
        let span = nodesBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }

    /// Internal direct-return borrow of the edge buffer; see
    /// ``textBytesSpan()`` for the gating and the lifetime-override
    /// reasoning.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
    @_lifetime(borrow self)
    borrowing func edgesSpan() -> Span<UInt32> {
        let edgesBuffer = UnsafeBufferPointer(start: edgesStorage.baseAddress, count: edgeCount)
        let span = edgesBuffer.span
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
            precondition(edgesStart + childCount <= edgeCount, "Edge range out of range for this store")
            return (edgesStart ..< (edgesStart + childCount)).map { edgesStorage.baseAddress[$0] }
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
