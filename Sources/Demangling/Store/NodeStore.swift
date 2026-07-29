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
    ///
    /// - Precondition: `nodeIndex` is within this store's bounds. A
    ///   `NodeIndex` is a bare offset with no record of which store minted it,
    ///   so an index from a *different* store that happens to be in range
    ///   resolves silently to whatever node lives there. Only the bound can be
    ///   checked; keeping indices with their store is the caller's job.
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
    /// Child indices of the node at `rawIndex`, in order.
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
