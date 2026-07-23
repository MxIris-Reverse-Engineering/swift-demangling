/// Append-only builder that constructs a `SymbolStore`.
///
/// The builder is noncopyable: exactly one owner may build at a time, and
/// `freeze()` consumes the builder, so "immutable after freezing" is enforced
/// by the type system rather than by locks or documentation.
///
/// Every inserted node is hash-consed on entry: structurally equal subtrees
/// receive the same `SymbolStore.NodeIndex`. Interior-node keys use child
/// indices, which is exact because children are always interned before their
/// parent (the same bottom-up scheme as `NodeCache.internTreeUnsafe`).
public struct SymbolStoreBuilder: ~Copyable, Sendable {
    private var nodes: ContiguousArray<CompactNode> = []
    private var edges: ContiguousArray<UInt32> = []
    private var textBytes: ContiguousArray<UInt8> = []

    /// Interning table for nodes whose 12-byte representation is already
    /// canonical: leaves (text offsets are canonical because text is interned
    /// first) and nodes with one or two children (child indices are canonical).
    private var uniqueNodeIndices: [CompactNode: UInt32] = [:]

    /// Interning table for nodes with three or more children, whose edges
    /// offset is allocation-dependent and therefore cannot serve as a key.
    private var uniqueManyChildrenIndices: [ManyChildrenKey: UInt32] = [:]

    /// Interning table for text contents.
    private var uniqueTextLocations: [String: TextLocation] = [:]

    private struct ManyChildrenKey: Hashable {
        let kindAndPayloadKind: UInt16
        let childIndices: [UInt32]
    }

    private struct TextLocation {
        let offset: UInt32
        let length: UInt32
    }

    public init() {}

    // MARK: - Building

    /// Interns an existing `Node` tree, returning the canonical index of its root.
    public mutating func intern(_ node: Node) -> SymbolStore.NodeIndex {
        var visitedIndices = [ObjectIdentifier: UInt32]()
        return SymbolStore.NodeIndex(rawValue: internRecursively(node, visitedIndices: &visitedIndices))
    }

    /// Demangles a mangled symbol and interns the resulting tree in one step.
    ///
    /// The intermediate `Node` tree is transient, so the global `NodeCache`
    /// subtree interning is skipped — nothing accumulates outside this builder.
    public mutating func demangle(_ mangled: String, isType: Bool = false) throws(DemanglingError) -> SymbolStore.NodeIndex {
        let tree = try demangleAsNode(mangled, isType: isType, internsSubtrees: false)
        return intern(tree)
    }

    /// Freezes the builder into an immutable, `Sendable` store.
    ///
    /// Consumes the builder; interning tables are dropped, only the flat
    /// buffers survive. Indices minted by this builder remain valid in the
    /// frozen store.
    public consuming func freeze() -> SymbolStore {
        SymbolStore(nodes: nodes, edges: edges, textBytes: textBytes)
    }

    // MARK: - Statistics

    /// Number of unique nodes interned so far.
    public var nodeCount: Int { nodes.count }

    // MARK: - Interning

    private mutating func internRecursively(_ node: Node, visitedIndices: inout [ObjectIdentifier: UInt32]) -> UInt32 {
        let identifier = ObjectIdentifier(node)
        if let existingIndex = visitedIndices[identifier] {
            return existingIndex
        }

        let children = node.children
        let internedIndex: UInt32
        if children.isEmpty {
            internedIndex = internLeaf(kind: node.kind, contents: node.contents)
        } else {
            var childIndices = [UInt32]()
            childIndices.reserveCapacity(children.count)
            for child in children {
                childIndices.append(internRecursively(child, visitedIndices: &visitedIndices))
            }
            internedIndex = internInterior(kind: node.kind, childIndices: childIndices)
        }

        visitedIndices[identifier] = internedIndex
        return internedIndex
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
            let key = ManyChildrenKey(
                kindAndPayloadKind: CompactNode(kind: kind, payloadKind: .manyChildren, payloadWord0: 0, payloadWord1: 0).kindAndPayloadKind,
                childIndices: childIndices
            )
            if let existingIndex = uniqueManyChildrenIndices[key] {
                return existingIndex
            }
            precondition(edges.count + childIndices.count <= Int(UInt32.max), "SymbolStore edges buffer exceeded UInt32 index space")
            let edgesOffset = UInt32(edges.count)
            edges.append(contentsOf: childIndices)
            let newIndex = appendNode(CompactNode(
                kind: kind,
                payloadKind: .manyChildren,
                payloadWord0: edgesOffset,
                payloadWord1: UInt32(childIndices.count)
            ))
            uniqueManyChildrenIndices[key] = newIndex
            return newIndex
        }
    }

    private mutating func internCanonicalCompact(_ compact: CompactNode) -> UInt32 {
        if let existingIndex = uniqueNodeIndices[compact] {
            return existingIndex
        }
        let newIndex = appendNode(compact)
        uniqueNodeIndices[compact] = newIndex
        return newIndex
    }

    private mutating func appendNode(_ compact: CompactNode) -> UInt32 {
        precondition(nodes.count < Int(UInt32.max), "SymbolStore node buffer exceeded UInt32 index space")
        let newIndex = UInt32(nodes.count)
        nodes.append(compact)
        return newIndex
    }

    private mutating func internText(_ textValue: String) -> TextLocation {
        if let existingLocation = uniqueTextLocations[textValue] {
            return existingLocation
        }
        let utf8Bytes = Array(textValue.utf8)
        precondition(textBytes.count + utf8Bytes.count <= Int(UInt32.max), "SymbolStore text buffer exceeded UInt32 offset space")
        let location = TextLocation(offset: UInt32(textBytes.count), length: UInt32(utf8Bytes.count))
        textBytes.append(contentsOf: utf8Bytes)
        uniqueTextLocations[textValue] = location
        return location
    }
}
