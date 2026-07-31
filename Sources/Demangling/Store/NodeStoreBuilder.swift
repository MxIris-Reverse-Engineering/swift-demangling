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
/// That invariant is what makes `NodeReference.==` — a store-identity and
/// index compare — **structural equality within one arena**, and therefore
/// what makes `Set` / `Dictionary` of references deduplicate. Batch every tree
/// through one builder and that holds; give each tree its own arena (which is
/// what `NodeReference(interning:)` does per call) and it cannot. See
/// ``NodeReference`` for the boundary and `Documentations/NodeStoreArena.md`
/// for the measurements.
public struct NodeStoreBuilder: ~Copyable, Sendable {
    private var nodes: ContiguousArray<CompactNode> = []
    private var edges: ContiguousArray<UInt32> = []
    private var textBytes: ContiguousArray<UInt8> = []

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

    public init() {}

    // MARK: - Building

    /// Interns an existing `Node` tree, returning the canonical index of its root.
    public mutating func intern(_ node: Node) -> NodeStore.NodeIndex {
        var visitedIndices = [ObjectIdentifier: UInt32]()
        return NodeStore.NodeIndex(rawValue: internTree(node, visitedIndices: &visitedIndices))
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
        NodeStore.NodeIndex(rawValue: internLeaf(kind: kind, contents: .none))
    }

    /// Interns a text-carrying leaf node.
    public mutating func intern(kind: Node.Kind, text: String) -> NodeStore.NodeIndex {
        NodeStore.NodeIndex(rawValue: internLeaf(kind: kind, contents: .text(text)))
    }

    /// Interns an index-carrying leaf node.
    public mutating func intern(kind: Node.Kind, index: UInt64) -> NodeStore.NodeIndex {
        NodeStore.NodeIndex(rawValue: internLeaf(kind: kind, contents: .index(index)))
    }

    /// Interns an interior node over already-interned children — e.g. a
    /// `.type` wrapper around a stored subtree, the pattern index builders
    /// use for dictionary keys. Children must be indices minted by this
    /// builder; an empty child list interns a parameterless node.
    ///
    /// Hash-consing is shared with every other insertion route: constructing
    /// a node directly and interning a structurally equal `Node` tree yield
    /// the same index.
    /// - Precondition: every child index is within this builder's bounds. As
    ///   with ``NodeStore/reference(at:)`` a `NodeIndex` carries no record of
    ///   which builder minted it, so an in-range index from another builder
    ///   resolves silently to a different node; only the bound can be checked.
    public mutating func intern(kind: Node.Kind, children: [NodeStore.NodeIndex]) -> NodeStore.NodeIndex {
        let childIndices = children.map { childIndex in
            precondition(Int(childIndex.rawValue) < nodes.count, "Child index out of range for this builder")
            return childIndex.rawValue
        }
        if childIndices.isEmpty {
            return NodeStore.NodeIndex(rawValue: internLeaf(kind: kind, contents: .none))
        }
        return NodeStore.NodeIndex(rawValue: internInterior(kind: kind, childIndices: childIndices))
    }

    /// Freezes the builder into an immutable, `Sendable` store.
    ///
    /// Consumes the builder; interning tables are dropped, only the flat
    /// buffers survive. Indices minted by this builder remain valid in the
    /// frozen store.
    public consuming func freeze() -> NodeStore {
        NodeStore(nodes: nodes, edges: edges, textBytes: textBytes)
    }

    // MARK: - Statistics

    /// Number of unique nodes interned so far.
    public var nodeCount: Int { nodes.count }

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
        precondition(nodes.count < Int(UInt32.max), "NodeStore node buffer exceeded UInt32 index space")
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
        var grownSlots = ContiguousArray<UInt32>(repeating: Self.emptySlot, count: compactSlots.count * 2)
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
        return edges[edgesStart ..< edgesStart + childIndices.count].elementsEqual(childIndices)
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
                precondition(edges.count + childIndices.count <= Int(UInt32.max), "NodeStore edges buffer exceeded UInt32 index space")
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
        var grownSlots = ContiguousArray<UInt32>(repeating: Self.emptySlot, count: manyChildrenSlots.count * 2)
        let mask = grownSlots.count - 1
        for existing in manyChildrenSlots where existing != Self.emptySlot {
            let compact = nodes[Int(existing)]
            let edgesStart = Int(compact.payloadWord0)
            let childCount = Int(compact.payloadWord1)
            var slot = Self.hashOfManyChildren(
                kindAndPayloadKind: compact.kindAndPayloadKind,
                childIndices: edges[edgesStart ..< edgesStart + childCount]
            ) & mask
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

    private func textLocationMatches(_ location: TextLocation, utf8Bytes: [UInt8]) -> Bool {
        guard Int(location.length) == utf8Bytes.count else { return false }
        let start = Int(location.offset)
        return textBytes[start ..< start + utf8Bytes.count].elementsEqual(utf8Bytes)
    }

    private mutating func internText(_ textValue: String) -> TextLocation {
        if (uniqueTexts.count &+ 1) &* 4 >= textSlots.count &* 3 {
            growTextSlots()
        }
        let utf8Bytes = Array(textValue.utf8)
        let mask = textSlots.count - 1
        var slot = Self.hashOfTextBytes(utf8Bytes) & mask
        while true {
            let existing = textSlots[slot]
            if existing == Self.emptySlot {
                precondition(textBytes.count + utf8Bytes.count <= Int(UInt32.max), "NodeStore text buffer exceeded UInt32 offset space")
                let location = TextLocation(offset: UInt32(textBytes.count), length: UInt32(utf8Bytes.count))
                textBytes.append(contentsOf: utf8Bytes)
                textSlots[slot] = UInt32(uniqueTexts.count)
                uniqueTexts.append(location)
                return location
            }
            let existingLocation = uniqueTexts[Int(existing)]
            if textLocationMatches(existingLocation, utf8Bytes: utf8Bytes) {
                return existingLocation
            }
            slot = (slot + 1) & mask
        }
    }

    private mutating func growTextSlots() {
        var grownSlots = ContiguousArray<UInt32>(repeating: Self.emptySlot, count: textSlots.count * 2)
        let mask = grownSlots.count - 1
        for existing in textSlots where existing != Self.emptySlot {
            let location = uniqueTexts[Int(existing)]
            let start = Int(location.offset)
            var slot = Self.hashOfTextBytes(textBytes[start ..< start + Int(location.length)]) & mask
            while grownSlots[slot] != Self.emptySlot {
                slot = (slot + 1) & mask
            }
            grownSlots[slot] = existing
        }
        textSlots = grownSlots
    }
}
