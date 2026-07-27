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

        @usableFromInline
        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
    }

    @usableFromInline
    let nodes: ContiguousArray<CompactNode>

    @usableFromInline
    let edges: ContiguousArray<UInt32>

    @usableFromInline
    let textBytes: ContiguousArray<UInt8>

    init(
        nodes: ContiguousArray<CompactNode>,
        edges: ContiguousArray<UInt32>,
        textBytes: ContiguousArray<UInt8>
    ) {
        self.nodes = nodes
        self.edges = edges
        self.textBytes = textBytes
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
    public func reference(at nodeIndex: NodeIndex) -> NodeReference {
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
        return String(decoding: textBytes[start ..< end], as: UTF8.self)
    }

    // MARK: - Materialization

    /// Rebuilds a `Node` tree for the subtree rooted at the given raw index.
    ///
    /// The returned tree is freshly constructed and does not interact with the
    /// global `NodeCache`. The store is hash-consed, so a subtree referenced
    /// from multiple parents is a single index; the memo rebuilds each index
    /// once and reuses the instance, preserving the store's DAG shape.
    /// Expanding instead would multiply node count for symbols with heavy
    /// substitution sharing and defeat the printer's per-instance memoization.
    func materializeNode(at rawIndex: UInt32) -> Node {
        var materializedByIndex: [UInt32: Node] = [:]
        return materializeNode(at: rawIndex, materializedByIndex: &materializedByIndex)
    }

    private func materializeNode(at rawIndex: UInt32, materializedByIndex: inout [UInt32: Node]) -> Node {
        if let shared = materializedByIndex[rawIndex] {
            return shared
        }
        let compact = compactNode(at: rawIndex)
        let node: Node
        switch compact.payloadKind {
        case .none:
            node = Node(kind: compact.kind)
        case .index:
            node = Node(kind: compact.kind, index: UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32))
        case .text:
            node = Node(kind: compact.kind, text: text(offset: compact.payloadWord0, length: compact.payloadWord1))
        case .oneChild:
            node = Node(kind: compact.kind, children: [materializeNode(at: compact.payloadWord0, materializedByIndex: &materializedByIndex)])
        case .twoChildren:
            node = Node(kind: compact.kind, children: [
                materializeNode(at: compact.payloadWord0, materializedByIndex: &materializedByIndex),
                materializeNode(at: compact.payloadWord1, materializedByIndex: &materializedByIndex),
            ])
        case .manyChildren:
            let edgesStart = Int(compact.payloadWord0)
            let childCount = Int(compact.payloadWord1)
            var children = [Node]()
            children.reserveCapacity(childCount)
            for edgeOffset in edgesStart ..< (edgesStart + childCount) {
                children.append(materializeNode(at: edges[edgeOffset], materializedByIndex: &materializedByIndex))
            }
            node = Node(kind: compact.kind, children: children)
        }
        materializedByIndex[rawIndex] = node
        return node
    }
}
