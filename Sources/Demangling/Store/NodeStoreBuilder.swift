import SwiftStdlibToolbox

/// Append-only builder that constructs a `NodeStore`.
///
/// The builder is noncopyable: exactly one owner may build at a time, and
/// `freeze()` consumes the builder, so "immutable after freezing" is enforced
/// by the type system rather than by locks or documentation.
///
/// Every inserted node is hash-consed on entry: structurally equal subtrees
/// receive the same `NodeStore.NodeIndex`. Interior-node keys use child
/// indices, which is exact because children are always interned before their
/// parent (the same bottom-up scheme as `NodeCache.internTreeUnsafe`).
///
/// "Structurally equal" here means equal **byte for byte** in any text a node
/// carries — `internText` compares raw UTF-8, not canonical equivalence, so
/// NFC and NFD spellings of one identifier are two entries. That is deliberate
/// (it is what keeps `NodeReference`'s cross-representation equality
/// transitive) and is the single place where an index compare is stricter than
/// `Node.==`. See ``NodeReference`` for the full boundary.
///
/// That invariant is what makes `NodeReference.==` — a store-identity and
/// index compare — **structural equality within one arena**, and therefore
/// what makes `Set` / `Dictionary` of references deduplicate. Batch every tree
/// through one builder and that holds; give each tree its own arena (which is
/// what `NodeReference(interning:)` does per call) and it cannot. See
/// ``NodeReference`` for the boundary and `Documentations/NodeStoreArena.md`
/// for the measurements.
public struct NodeStoreBuilder: ~Copyable, Sendable {
    // The three flat buffers live in self-managed `StoreBuffer` allocations
    // (proposal 0010, step 1): `freeze()` hands them to the frozen store as an
    // ownership transfer, and the shared store (step 4) controls growth
    // retirement explicitly. The builder being `~Copyable` is load-bearing
    // here — a copied builder would alias the class-backed storage with a
    // divergent count, which `ContiguousArray`'s CoW used to make impossible.
    private var nodes = GrowableStoreBuffer<CompactNode>()
    private var edges = GrowableStoreBuffer<UInt32>()
    private var textBytes = GrowableStoreBuffer<UInt8>()

    // Interning tables are open-addressing slot arrays that store only node
    // (or text) indices — 4 bytes per slot, no separate key storage. Keys are
    // recovered from the flat buffers on comparison, so the tables add ~2 MB
    // for a whole-framework build instead of the ~10 MB the dictionary-keyed
    // scheme cost (proposal 0001, Phase 3 intern-table slimming).

    /// Slot sentinel for an empty open-addressing slot.
    private static let emptySlot: UInt32 = .max

    /// Interning table for nodes whose 12-byte representation is already
    /// canonical: leaves (text offsets are canonical because text is interned
    /// first) and nodes with one or two children (child indices are canonical).
    /// Slots hold node indices; the key is `nodes[slot]` itself.
    private var compactSlots = ContiguousArray<UInt32>(repeating: emptySlot, count: 4096)
    private var compactCount = 0

    /// Interning table for nodes with three or more children, whose edges
    /// offset is allocation-dependent and therefore cannot serve as a key.
    /// Slots hold node indices; comparison walks the `edges` range.
    private var manyChildrenSlots = ContiguousArray<UInt32>(repeating: emptySlot, count: 1024)
    private var manyChildrenCount = 0

    /// Interning table for text contents. Slots index into `uniqueTexts`;
    /// comparison reads the `textBytes` range.
    private var textSlots = ContiguousArray<UInt32>(repeating: emptySlot, count: 1024)
    private var uniqueTexts: ContiguousArray<TextLocation> = []

    private struct TextLocation {
        let offset: UInt32
        let length: UInt32
    }

    /// Issuance tag for this builder's indices (proposal 0009): debug builds
    /// embed it in every minted `NodeIndex` and validate it wherever an index
    /// crosses back in, so an index from another builder fails fast instead
    /// of silently resolving in-range. Stored in every configuration (2
    /// bytes, so `freeze()` keeps one signature); read only in debug.
    private let storeTag: UInt16

    #if DEBUG
    /// Tag source: a random starting point from system entropy, then
    /// monotonic — adjacent builders (exactly the plausible misuse pairing)
    /// always receive distinct tags, and a collision needs 65,536 builders
    /// created in between.
    private static let nextStoreTag = Mutex<UInt16>(UInt16.random(in: .min ... .max))
    #endif

    private static func mintStoreTag() -> UInt16 {
        #if DEBUG
        return nextStoreTag.withLockUnchecked { storedTagValue in
            storedTagValue &+= 1
            return storedTagValue
        }
        #else
        return 0
        #endif
    }

    /// Wraps a raw index as a `NodeIndex` carrying this builder's issuance
    /// tag (the tag field exists only in debug builds).
    private func mintIndex(_ rawValue: UInt32) -> NodeStore.NodeIndex {
        #if DEBUG
        return NodeStore.NodeIndex(rawValue: rawValue, storeTag: storeTag)
        #else
        return NodeStore.NodeIndex(rawValue: rawValue)
        #endif
    }

    public init() {
        storeTag = Self.mintStoreTag()
    }

    // MARK: - Building

    /// Interns an existing `Node` tree, returning the canonical index of its root.
    public mutating func intern(_ node: Node) -> NodeStore.NodeIndex {
        var visitedIndices = [ObjectIdentifier: UInt32]()
        return mintIndex(internTree(node, visitedIndices: &visitedIndices))
    }

    /// Demangles a mangled symbol and interns the resulting tree in one step.
    ///
    /// The intermediate `Node` tree is transient and fully cache-free: neither
    /// leaves nor subtrees touch `NodeCache.shared`, so bulk demangling leaves
    /// no trace in global state (proposal 0001, Phase 3).
    ///
    /// - Parameter symbolicReferenceResolver: resolves symbolic references
    ///   (`\u{01}`–`\u{0C}` markers) encountered in `mangled`. Bulk indexing of
    ///   metadata mangled names — this method's target use — is exactly where
    ///   those occur; without a resolver such symbols throw.
    public mutating func demangle(
        _ mangled: String,
        isType: Bool = false,
        symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil
    ) throws(DemanglingError) -> NodeStore.NodeIndex {
        let tree = try demangleAsNodeTransient(mangled, isType: isType, symbolicReferenceResolver: symbolicReferenceResolver)
        return intern(tree)
    }

    // MARK: - Direct Construction

    /// Interns a parameterless node.
    public mutating func intern(kind: Node.Kind) -> NodeStore.NodeIndex {
        mintIndex(internLeaf(kind: kind, contents: .none))
    }

    /// Interns a text-carrying leaf node.
    public mutating func intern(kind: Node.Kind, text: String) -> NodeStore.NodeIndex {
        mintIndex(internLeaf(kind: kind, contents: .text(text)))
    }

    /// Interns an index-carrying leaf node.
    public mutating func intern(kind: Node.Kind, index: UInt64) -> NodeStore.NodeIndex {
        mintIndex(internLeaf(kind: kind, contents: .index(index)))
    }

    /// Interns an interior node over already-interned children — e.g. a
    /// `.type` wrapper around a stored subtree, the pattern index builders
    /// use for dictionary keys. Children must be indices minted by this
    /// builder; an empty child list interns a parameterless node.
    ///
    /// Hash-consing is shared with every other insertion route: constructing
    /// a node directly and interning a structurally equal `Node` tree yield
    /// the same index.
    /// - Precondition: every child index was minted by this builder and is
    ///   within its bounds. Debug builds verify the minting builder through
    ///   the index's issuance tag (proposal 0009) and trap deterministically
    ///   on a foreign index. In release the tag does not exist, so — as with
    ///   ``NodeStore/reference(at:)`` — an in-range index from another
    ///   builder resolves silently to a different node and only the bound is
    ///   checked.
    public mutating func intern(kind: Node.Kind, children: [NodeStore.NodeIndex]) -> NodeStore.NodeIndex {
        let childIndices = children.map { childIndex in
            #if DEBUG
            precondition(
                childIndex.storeTag == storeTag,
                "NodeIndex was minted by a different builder — an index is only valid in the builder (or the store frozen from it) that issued it"
            )
            #endif
            precondition(Int(childIndex.rawValue) < nodes.count, "Child index out of range for this builder")
            return childIndex.rawValue
        }
        if childIndices.isEmpty {
            return mintIndex(internLeaf(kind: kind, contents: .none))
        }
        return mintIndex(internInterior(kind: kind, childIndices: childIndices))
    }

    // MARK: - Shared-store wiring (proposal 0010, step 4)

    // The internal seams `SharedNodeStore` builds on: it owns a builder for
    // the store's whole lifetime (never freezing, so the interning tables —
    // the source of persistent dedup — are never dropped), publishes a fresh
    // view after every intern, and keeps grown-out buffer generations alive
    // for readers pinned to older views.

    /// The issuance tag this builder mints indices with; the shared store's
    /// `NodeStore` identity is created with the same tag so debug-build
    /// provenance checks work unchanged.
    var issuedStoreTag: UInt16 { storeTag }

    /// The current buffer generations and their initialized counts — what a
    /// shared store publishes as its readers' view descriptor after an
    /// intern.
    var bufferSnapshot: (
        nodesStorage: StoreBuffer<CompactNode>, nodeCount: Int,
        edgesStorage: StoreBuffer<UInt32>, edgeCount: Int,
        textStorage: StoreBuffer<UInt8>, textByteCount: Int
    ) {
        (nodes.storage, nodes.count, edges.storage, edges.count, textBytes.storage, textBytes.count)
    }

    /// Installs the grown-generation keepalive hook on all three flat
    /// buffers; see `GrowableStoreBuffer.retirementSink`.
    mutating func installRetirementSink(_ sink: @escaping @Sendable (AnyObject) -> Void) {
        nodes.retirementSink = sink
        edges.retirementSink = sink
        textBytes.retirementSink = sink
    }

    /// Freezes the builder into an immutable, `Sendable` store.
    ///
    /// Consumes the builder; interning tables are dropped, only the flat
    /// buffers survive — as an ownership handover of the underlying
    /// allocations, not a copy (proposal 0010, step 1). Indices minted by
    /// this builder remain valid in the frozen store.
    public consuming func freeze() -> NodeStore {
        NodeStore(
            nodesStorage: nodes.storage, nodeCount: nodes.count,
            edgesStorage: edges.storage, edgeCount: edges.count,
            textStorage: textBytes.storage, textByteCount: textBytes.count,
            storeTag: storeTag
        )
    }

    // MARK: - Statistics

    /// Number of unique nodes interned so far.
    public var nodeCount: Int { nodes.count }

    // MARK: - Capacity Reservation (proposal 0009)

    /// Per-symbol buffer-sizing coefficients, measured on the dyld-cache
    /// bulk-build corpus (454,094 unique exported Swift symbols across
    /// AppKit / UIKitCore / SwiftUI / SwiftUICore / AttributeGraph /
    /// Foundation / Combine, macOS 26 shared cache; calibration run
    /// 2026-08-08, recorded in evolution 0009's decision log — measured:
    /// 2.791 unique nodes, 0.280 many-children nodes, 0.935 edge slots,
    /// 2.108 text bytes, 0.0815 unique texts per symbol). Each value is the
    /// measured ratio rounded up a few percent, so a corpus matching the
    /// calibration shape lands just under the reservation. Re-check against
    /// ``capacityUtilization`` when the corpus shape drifts.
    private enum ReservationCoefficients {
        static let uniqueNodesPerSymbol: Double = 2.9
        static let manyChildrenNodesPerSymbol: Double = 0.3
        static let edgeSlotsPerSymbol: Double = 1.0
        static let textBytesPerSymbol: Double = 2.2
        static let uniqueTextsPerSymbol: Double = 0.09
    }

    /// Pre-sizes the three flat buffers and the three interning tables for
    /// an expected number of interned symbols.
    ///
    /// Building a whole-framework store from the default capacities pays
    /// roughly a dozen full-buffer regrowth copies per buffer, each of which
    /// transiently keeps the old and the new buffer alive (a ~2× spike on
    /// that buffer). One reservation up front removes both. Estimates use
    /// per-symbol coefficients measured on the dyld-cache corpus
    /// (`ReservationCoefficients`); an undersized reservation degrades to
    /// the normal growth behavior, an oversized one keeps the slack — for
    /// the builder's lifetime and into the frozen store, because `freeze()`
    /// deliberately does not shrink (until mmap serialization lands, a
    /// shrink would be one more full copy to save capacity that dies with
    /// the store).
    ///
    /// Callable at any point and growing only (a reservation at or below
    /// current capacity is a no-op). Reserving never changes interning
    /// results: indices, buffer contents, and the frozen store are identical
    /// with or without it.
    public mutating func reserveCapacity(expectedSymbolCount: Int) {
        guard expectedSymbolCount > 0 else { return }
        let expectedUniqueNodes = Self.estimatedCount(expectedSymbolCount, ReservationCoefficients.uniqueNodesPerSymbol)
        let expectedManyChildrenNodes = Self.estimatedCount(expectedSymbolCount, ReservationCoefficients.manyChildrenNodesPerSymbol)
        let expectedCompactNodes = max(0, expectedUniqueNodes - expectedManyChildrenNodes)
        let expectedUniqueTexts = Self.estimatedCount(expectedSymbolCount, ReservationCoefficients.uniqueTextsPerSymbol)
        nodes.reserveCapacity(expectedUniqueNodes)
        edges.reserveCapacity(Self.estimatedCount(expectedSymbolCount, ReservationCoefficients.edgeSlotsPerSymbol))
        textBytes.reserveCapacity(Self.estimatedCount(expectedSymbolCount, ReservationCoefficients.textBytesPerSymbol))
        uniqueTexts.reserveCapacity(expectedUniqueTexts)
        resizeCompactSlots(to: Self.slotCount(holding: expectedCompactNodes, growingFrom: compactSlots.count))
        resizeManyChildrenSlots(to: Self.slotCount(holding: expectedManyChildrenNodes, growingFrom: manyChildrenSlots.count))
        resizeTextSlots(to: Self.slotCount(holding: expectedUniqueTexts, growingFrom: textSlots.count))
    }

    /// Used-versus-reserved snapshot for re-calibrating the reservation
    /// coefficients (proposal 0009); not a hot-path API.
    ///
    /// For the three interning tables `usedCount` is occupied slots, and a
    /// well-sized open-addressing table reads between 37.5% and 75% — they
    /// grow at a 3/4 load factor in power-of-two steps, which bounds the
    /// achievable utilization. The flat buffers can approach 100%.
    public var capacityUtilization: CapacityUtilization {
        CapacityUtilization(
            nodes: CapacityUtilization.BufferUtilization(usedCount: nodes.count, capacity: nodes.capacity),
            edges: CapacityUtilization.BufferUtilization(usedCount: edges.count, capacity: edges.capacity),
            textBytes: CapacityUtilization.BufferUtilization(usedCount: textBytes.count, capacity: textBytes.capacity),
            compactInternSlots: CapacityUtilization.BufferUtilization(usedCount: compactCount, capacity: compactSlots.count),
            manyChildrenInternSlots: CapacityUtilization.BufferUtilization(usedCount: manyChildrenCount, capacity: manyChildrenSlots.count),
            textInternSlots: CapacityUtilization.BufferUtilization(usedCount: uniqueTexts.count, capacity: textSlots.count),
            uniqueTexts: CapacityUtilization.BufferUtilization(usedCount: uniqueTexts.count, capacity: uniqueTexts.capacity)
        )
    }

    /// Capacity-utilization report across every internal buffer; see
    /// ``capacityUtilization``.
    public struct CapacityUtilization: Sendable {
        /// used/capacity of one internal buffer or interning table.
        public struct BufferUtilization: Sendable {
            /// Elements in use (flat buffers) or occupied slots (tables).
            public let usedCount: Int
            /// Allocated capacity, in elements or slots.
            public let capacity: Int
            /// `usedCount / capacity`; 0 while nothing is allocated.
            public var utilization: Double {
                capacity == 0 ? 0 : Double(usedCount) / Double(capacity)
            }
        }

        public let nodes: BufferUtilization
        public let edges: BufferUtilization
        public let textBytes: BufferUtilization
        public let compactInternSlots: BufferUtilization
        public let manyChildrenInternSlots: BufferUtilization
        public let textInternSlots: BufferUtilization
        public let uniqueTexts: BufferUtilization
    }

    /// Rounds a per-symbol estimate up to a whole count, clamped to 2^30 so
    /// an absurd caller value degrades to a huge reservation instead of
    /// trapping on the `Int` conversion (which a `Double` above `Int.max`
    /// would — and on watchOS `Int.max` is only 2^31 − 1).
    private static func estimatedCount(_ symbolCount: Int, _ coefficientPerSymbol: Double) -> Int {
        let estimated = (Double(symbolCount) * coefficientPerSymbol).rounded(.up)
        return Int(min(estimated, 1_073_741_824))
    }

    /// Smallest power-of-two slot count, at least `currentSlotCount`, that
    /// keeps `expectedEntryCount` entries under the 3/4 load-factor
    /// threshold the insertion paths grow at. The comparison runs in
    /// `UInt64` so the arithmetic cannot overflow a 32-bit `Int` (see
    /// ``mix(_:_:)`` for the width-pinning rationale); the table is capped
    /// at 2^30 slots.
    private static func slotCount(holding expectedEntryCount: Int, growingFrom currentSlotCount: Int) -> Int {
        var proposedSlotCount = currentSlotCount
        while proposedSlotCount < 1 << 30,
              (UInt64(expectedEntryCount) + 1) * 4 >= UInt64(proposedSlotCount) * 3 {
            proposedSlotCount *= 2
        }
        return proposedSlotCount
    }

    // MARK: - Interning

    /// One suspended level of ``internTree(_:visitedIndices:)``'s walk.
    private struct InternFrame {
        let node: Node
        let identifier: ObjectIdentifier
        var nextChildIndex: Int
        var childIndices: [UInt32]
    }

    /// Interns a `Node` tree into the arena bottom-up.
    ///
    /// Walked with an explicit stack. ``demangle(_:isType:)`` runs the transient
    /// demangle through ``StackSafeExecutor`` but calls this afterwards, on
    /// whatever thread the caller is on — typically a 512KB cooperative worker
    /// during bulk indexing, which is exactly where the deepest generic types
    /// arrive. Recursion here would therefore sit outside every stack guard the
    /// library has; measured before this was made iterative, it took the process
    /// down at 500 levels of nesting in debug and 1200 in release.
    private mutating func internTree(_ node: Node, visitedIndices: inout [ObjectIdentifier: UInt32]) -> UInt32 {
        var frames: [InternFrame] = []
        var completedChildIndex: UInt32?

        func makeFrame(for node: Node) -> InternFrame {
            var frame = InternFrame(
                node: node,
                identifier: ObjectIdentifier(node),
                nextChildIndex: 0,
                childIndices: []
            )
            frame.childIndices.reserveCapacity(node.children.count)
            return frame
        }

        if let existingIndex = visitedIndices[ObjectIdentifier(node)] {
            return existingIndex
        }
        if node.children.isEmpty {
            let leafIndex = internLeaf(kind: node.kind, contents: node.contents)
            visitedIndices[ObjectIdentifier(node)] = leafIndex
            return leafIndex
        }
        frames.append(makeFrame(for: node))

        while var frame = frames.popLast() {
            if let childIndex = completedChildIndex {
                frame.childIndices.append(childIndex)
                completedChildIndex = nil
            }

            if frame.nextChildIndex < frame.node.children.count {
                let child = frame.node.children[frame.nextChildIndex]
                frame.nextChildIndex += 1
                frames.append(frame)

                let childIdentifier = ObjectIdentifier(child)
                if let existingIndex = visitedIndices[childIdentifier] {
                    completedChildIndex = existingIndex
                } else if child.children.isEmpty {
                    let leafIndex = internLeaf(kind: child.kind, contents: child.contents)
                    visitedIndices[childIdentifier] = leafIndex
                    completedChildIndex = leafIndex
                } else {
                    frames.append(makeFrame(for: child))
                }
                continue
            }

            let internedIndex = internInterior(kind: frame.node.kind, childIndices: frame.childIndices)
            visitedIndices[frame.identifier] = internedIndex
            if frames.isEmpty {
                return internedIndex
            }
            completedChildIndex = internedIndex
        }

        // Unreachable: the loop returns as soon as the root frame completes.
        return internLeaf(kind: node.kind, contents: node.contents)
    }

    private mutating func internLeaf(kind: Node.Kind, contents: Node.Contents) -> UInt32 {
        let compact: CompactNode
        switch contents {
        case .none:
            compact = CompactNode(kind: kind, payloadKind: .none, payloadWord0: 0, payloadWord1: 0)
        case .index(let indexValue):
            compact = CompactNode(
                kind: kind,
                payloadKind: .index,
                payloadWord0: UInt32(truncatingIfNeeded: indexValue),
                payloadWord1: UInt32(truncatingIfNeeded: indexValue >> 32)
            )
        case .text(let textValue):
            let location = internText(textValue)
            compact = CompactNode(
                kind: kind,
                payloadKind: .text,
                payloadWord0: location.offset,
                payloadWord1: location.length
            )
        }
        return internCanonicalCompact(compact)
    }

    private mutating func internInterior(kind: Node.Kind, childIndices: [UInt32]) -> UInt32 {
        // The bottom-up hash-consing invariant, pinned (proposal 0010,
        // step 2): every child is interned before its parent, so each child
        // index is smaller than the index this node already holds (table hit)
        // or is about to receive (append at `nodes.count`). The shared
        // store's stale-view safety (step 4) rests on exactly this — a
        // published view that covers a root index covers the root's whole
        // subtree, so a reader pinned to an older view can never chase an
        // edge past its view's bounds.
        // `precondition`, not `assert`: the stale-view safety argument above
        // is a release-configuration memory-safety claim, so its enforcement
        // must survive release — a future insertion path that violates the
        // invariant would otherwise ship silently and turn "read a stale
        // view" into "read past a retired generation's bounds". This is the
        // single minting funnel for interior nodes (one/two/many-child paths
        // converge here before any edge is written), and the many-children
        // path walks `childIndices` anyway, so the check is near-free
        // (ReviewFindingsPR7 F7).
        precondition(
            childIndices.allSatisfy { Int($0) < nodes.count },
            "interior node interned before one of its children — the bottom-up invariant is broken"
        )
        switch childIndices.count {
        case 1:
            return internCanonicalCompact(CompactNode(
                kind: kind,
                payloadKind: .oneChild,
                payloadWord0: childIndices[0],
                payloadWord1: 0
            ))
        case 2:
            return internCanonicalCompact(CompactNode(
                kind: kind,
                payloadKind: .twoChildren,
                payloadWord0: childIndices[0],
                payloadWord1: childIndices[1]
            ))
        default:
            return internManyChildren(kind: kind, childIndices: childIndices)
        }
    }

    private mutating func appendNode(_ compact: CompactNode) -> UInt32 {
        // Heterogeneous comparison, deliberately: spelled `Int(UInt32.max)`,
        // this guard overflowed at constant-folding time wherever `Int` is
        // 32 bits (watchOS arm64_32/armv7k) and the compiler reduced this
        // whole function body to an unconditional trap — with the build
        // staying green. `Int` vs `UInt32` compares mathematically on every
        // word size; on 32-bit it is vacuously true, which is correct, since
        // a count bounded by `Int.max` cannot exceed the UInt32 index space
        // there. Same for the edges/text guards below.
        precondition(nodes.count < UInt32.max, "NodeStore node buffer exceeded UInt32 index space")
        let newIndex = UInt32(nodes.count)
        nodes.append(compact)
        return newIndex
    }

    // MARK: - Open-Addressing Interning Tables

    /// Mixing runs in explicit `UInt64`, not `Int`.
    ///
    /// The constants here and in ``hashOfTextBytes(_:)`` do not fit a 32-bit
    /// `Int`, and this package ships for watchOS, where `Int` is 32 bits — as
    /// `Int` literals they are a hard compile error there (`integer literal
    /// overflows when stored into 'Int'`), which a 64-bit host build never
    /// surfaces. Widths are therefore pinned rather than left to the platform,
    /// and the digest is truncated back to `Int` only at the end. Every
    /// consumer masks with a power-of-two table mask, so truncation — and the
    /// negative values it can produce — is harmless, and slot distribution is
    /// identical on both word sizes.
    private static func mix(_ currentHash: UInt64, _ value: UInt64) -> UInt64 {
        (currentHash &* 0x9E3779B1) &+ value
    }

    private static func hash(of compact: CompactNode) -> Int {
        var combined = UInt64(compact.kindAndPayloadKind)
        combined = mix(combined, UInt64(compact.payloadWord0))
        combined = mix(combined, UInt64(compact.payloadWord1))
        return Int(truncatingIfNeeded: mix(combined, 0))
    }

    private mutating func internCanonicalCompact(_ compact: CompactNode) -> UInt32 {
        if (compactCount &+ 1) &* 4 >= compactSlots.count &* 3 {
            growCompactSlots()
        }
        let mask = compactSlots.count - 1
        var slot = Self.hash(of: compact) & mask
        while true {
            let existing = compactSlots[slot]
            if existing == Self.emptySlot {
                let newIndex = appendNode(compact)
                compactSlots[slot] = newIndex
                compactCount += 1
                return newIndex
            }
            if nodes[Int(existing)] == compact {
                return existing
            }
            slot = (slot + 1) & mask
        }
    }

    private mutating func growCompactSlots() {
        resizeCompactSlots(to: compactSlots.count * 2)
    }

    /// Rehashes the compact-node table into `newSlotCount` slots (a power of
    /// two). Growing only: a target at or below the current size is a no-op.
    private mutating func resizeCompactSlots(to newSlotCount: Int) {
        guard newSlotCount > compactSlots.count else { return }
        var grownSlots = ContiguousArray<UInt32>(repeating: Self.emptySlot, count: newSlotCount)
        let mask = grownSlots.count - 1
        for existing in compactSlots where existing != Self.emptySlot {
            var slot = Self.hash(of: nodes[Int(existing)]) & mask
            while grownSlots[slot] != Self.emptySlot {
                slot = (slot + 1) & mask
            }
            grownSlots[slot] = existing
        }
        compactSlots = grownSlots
    }

    private static func hashOfManyChildren(kindAndPayloadKind: UInt16, childIndices: some Sequence<UInt32>) -> Int {
        var combined = UInt64(kindAndPayloadKind)
        for childIndex in childIndices {
            combined = Self.mix(combined, UInt64(childIndex))
        }
        return Int(truncatingIfNeeded: Self.mix(combined, 0))
    }

    private func manyChildrenNodeMatches(_ existingIndex: UInt32, kindAndPayloadKind: UInt16, childIndices: [UInt32]) -> Bool {
        let existing = nodes[Int(existingIndex)]
        guard existing.kindAndPayloadKind == kindAndPayloadKind,
              Int(existing.payloadWord1) == childIndices.count else {
            return false
        }
        let edgesStart = Int(existing.payloadWord0)
        return edges.withBuffer(in: edgesStart ..< edgesStart + childIndices.count) { edgeBuffer in
            edgeBuffer.elementsEqual(childIndices)
        }
    }

    private mutating func internManyChildren(kind: Node.Kind, childIndices: [UInt32]) -> UInt32 {
        if (manyChildrenCount &+ 1) &* 4 >= manyChildrenSlots.count &* 3 {
            growManyChildrenSlots()
        }
        let kindAndPayloadKind = CompactNode(kind: kind, payloadKind: .manyChildren, payloadWord0: 0, payloadWord1: 0).kindAndPayloadKind
        let mask = manyChildrenSlots.count - 1
        var slot = Self.hashOfManyChildren(kindAndPayloadKind: kindAndPayloadKind, childIndices: childIndices) & mask
        while true {
            let existing = manyChildrenSlots[slot]
            if existing == Self.emptySlot {
                precondition(edges.count + childIndices.count <= UInt32.max, "NodeStore edges buffer exceeded UInt32 index space")
                let edgesOffset = UInt32(edges.count)
                edges.append(contentsOf: childIndices)
                let newIndex = appendNode(CompactNode(
                    kind: kind,
                    payloadKind: .manyChildren,
                    payloadWord0: edgesOffset,
                    payloadWord1: UInt32(childIndices.count)
                ))
                manyChildrenSlots[slot] = newIndex
                manyChildrenCount += 1
                return newIndex
            }
            if manyChildrenNodeMatches(existing, kindAndPayloadKind: kindAndPayloadKind, childIndices: childIndices) {
                return existing
            }
            slot = (slot + 1) & mask
        }
    }

    private mutating func growManyChildrenSlots() {
        resizeManyChildrenSlots(to: manyChildrenSlots.count * 2)
    }

    /// Rehashes the many-children table into `newSlotCount` slots (a power
    /// of two). Growing only: a target at or below the current size is a
    /// no-op.
    private mutating func resizeManyChildrenSlots(to newSlotCount: Int) {
        guard newSlotCount > manyChildrenSlots.count else { return }
        var grownSlots = ContiguousArray<UInt32>(repeating: Self.emptySlot, count: newSlotCount)
        let mask = grownSlots.count - 1
        for existing in manyChildrenSlots where existing != Self.emptySlot {
            let compact = nodes[Int(existing)]
            let edgesStart = Int(compact.payloadWord0)
            let childCount = Int(compact.payloadWord1)
            var slot = edges.withBuffer(in: edgesStart ..< edgesStart + childCount) { edgeBuffer in
                Self.hashOfManyChildren(
                    kindAndPayloadKind: compact.kindAndPayloadKind,
                    childIndices: edgeBuffer
                )
            } & mask
            while grownSlots[slot] != Self.emptySlot {
                slot = (slot + 1) & mask
            }
            grownSlots[slot] = existing
        }
        manyChildrenSlots = grownSlots
    }

    private static func hashOfTextBytes(_ bytes: some Sequence<UInt8>) -> Int {
        // FNV-1a, in explicit UInt64 — see ``mix(_:_:)`` for why the width is
        // pinned rather than left as `Int`.
        var combined: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            combined = (combined ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return Int(truncatingIfNeeded: combined)
    }

    /// FNV-1a over a string's UTF-8 without materializing an array: native
    /// `String`s (large and small) vend contiguous storage, so the fast path
    /// hashes a borrowed buffer; only non-contiguous (bridged) strings fall
    /// back to iterating the view (proposal 0008, B3).
    private static func hashOfText(_ textValue: String) -> Int {
        let utf8View = textValue.utf8
        if let contiguousHash = utf8View.withContiguousStorageIfAvailable({ buffer in
            hashOfTextBytes(buffer)
        }) {
            return contiguousHash
        }
        return hashOfTextBytes(utf8View)
    }

    private func textLocationMatches(_ location: TextLocation, textValue: String) -> Bool {
        let length = Int(location.length)
        guard length == textValue.utf8.count else { return false }
        let start = Int(location.offset)
        return textBytes.withBuffer(in: start ..< start + length) { textBuffer in
            let storedBytes = textBuffer
            if let contiguousResult = textValue.utf8.withContiguousStorageIfAvailable({ buffer in
                storedBytes.elementsEqual(buffer)
            }) {
                return contiguousResult
            }
            return storedBytes.elementsEqual(textValue.utf8)
        }
    }

    private mutating func internText(_ textValue: String) -> TextLocation {
        if (uniqueTexts.count &+ 1) &* 4 >= textSlots.count &* 3 {
            growTextSlots()
        }
        let utf8Length = textValue.utf8.count
        let mask = textSlots.count - 1
        var slot = Self.hashOfText(textValue) & mask
        while true {
            let existing = textSlots[slot]
            if existing == Self.emptySlot {
                precondition(textBytes.count + utf8Length <= UInt32.max, "NodeStore text buffer exceeded UInt32 offset space")
                let location = TextLocation(offset: UInt32(textBytes.count), length: UInt32(utf8Length))
                appendTextBytes(textValue)
                textSlots[slot] = UInt32(uniqueTexts.count)
                uniqueTexts.append(location)
                return location
            }
            let existingLocation = uniqueTexts[Int(existing)]
            if textLocationMatches(existingLocation, textValue: textValue) {
                return existingLocation
            }
            slot = (slot + 1) & mask
        }
    }

    /// Appends a string's UTF-8 to the text buffer: native `String`s vend
    /// contiguous storage (one bulk copy); only non-contiguous (bridged)
    /// strings fall back to the per-byte loop (same strategy as
    /// ``hashOfText(_:)``).
    private mutating func appendTextBytes(_ textValue: String) {
        let utf8View = textValue.utf8
        let contiguouslyAppended: Void? = utf8View.withContiguousStorageIfAvailable { buffer in
            textBytes.append(contentsOf: buffer)
        }
        if contiguouslyAppended == nil {
            for byte in utf8View {
                textBytes.append(byte)
            }
        }
    }

    private mutating func growTextSlots() {
        resizeTextSlots(to: textSlots.count * 2)
    }

    /// Rehashes the text table into `newSlotCount` slots (a power of two).
    /// Growing only: a target at or below the current size is a no-op.
    private mutating func resizeTextSlots(to newSlotCount: Int) {
        guard newSlotCount > textSlots.count else { return }
        var grownSlots = ContiguousArray<UInt32>(repeating: Self.emptySlot, count: newSlotCount)
        let mask = grownSlots.count - 1
        for existing in textSlots where existing != Self.emptySlot {
            let location = uniqueTexts[Int(existing)]
            let start = Int(location.offset)
            var slot = textBytes.withBuffer(in: start ..< start + Int(location.length)) { textBuffer in
                Self.hashOfTextBytes(textBuffer)
            } & mask
            while grownSlots[slot] != Self.emptySlot {
                slot = (slot + 1) & mask
            }
            grownSlots[slot] = existing
        }
        textSlots = grownSlots
    }
}
