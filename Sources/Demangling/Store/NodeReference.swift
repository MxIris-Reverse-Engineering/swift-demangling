/// A lightweight handle to a node stored in a `SymbolStore`.
///
/// Sixteen bytes as a value: a store reference plus a node index. Because
/// stores are fully hash-consed, equality is O(1) — two references are equal
/// exactly when they address the same index of the same store, which within
/// one store coincides with structural equality.
public struct NodeReference: Sendable {
    public let store: SymbolStore
    public let nodeIndex: SymbolStore.NodeIndex

    @usableFromInline
    init(store: SymbolStore, nodeIndex: SymbolStore.NodeIndex) {
        self.store = store
        self.nodeIndex = nodeIndex
    }

    @usableFromInline
    var compactNode: CompactNode {
        store.compactNode(at: nodeIndex.rawValue)
    }

    // MARK: - Accessors (mirroring Node)

    public var kind: Node.Kind {
        compactNode.kind
    }

    /// The text contents, if this node carries text.
    public var text: String? {
        let compact = compactNode
        guard case .text = compact.payloadKind else { return nil }
        return store.text(offset: compact.payloadWord0, length: compact.payloadWord1)
    }

    /// The index contents, if this node carries an index.
    public var index: UInt64? {
        let compact = compactNode
        guard case .index = compact.payloadKind else { return nil }
        return UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32)
    }

    public var children: ChildrenView {
        ChildrenView(store: store, compactNode: compactNode)
    }

    // MARK: - Interop with Node

    /// Rebuilds a standalone `Node` tree for this subtree.
    ///
    /// The returned tree is freshly constructed and does not interact with the
    /// global `NodeCache`; intern it explicitly if canonical instances are needed.
    public func materialize() -> Node {
        store.materializeNode(at: nodeIndex.rawValue)
    }

    /// Prints the demangled form of this subtree.
    ///
    /// Phase 1 materializes and delegates to `Node.print(using:)`; proposal
    /// 0001 Phase 2 replaces this with a zero-materialization printer path.
    public func print(using options: DemangleOptions = .default) -> String {
        materialize().print(using: options)
    }
}

// MARK: - Hashable

extension NodeReference: Hashable {
    public static func == (lhs: NodeReference, rhs: NodeReference) -> Bool {
        lhs.store === rhs.store && lhs.nodeIndex == rhs.nodeIndex
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(store))
        hasher.combine(nodeIndex)
    }
}

// MARK: - ChildrenView

extension NodeReference {
    /// Random-access view of a node's children, resolved lazily from the store.
    public struct ChildrenView: RandomAccessCollection, Sendable {
        public typealias Element = NodeReference
        public typealias Index = Int

        @usableFromInline
        let store: SymbolStore

        @usableFromInline
        let compactNode: CompactNode

        @usableFromInline
        init(store: SymbolStore, compactNode: CompactNode) {
            self.store = store
            self.compactNode = compactNode
        }

        public var startIndex: Int { 0 }

        public var endIndex: Int { compactNode.childCount }

        public subscript(position: Int) -> NodeReference {
            let rawChildIndex: UInt32
            switch compactNode.payloadKind {
            case .oneChild:
                precondition(position == 0, "Child index out of range")
                rawChildIndex = compactNode.payloadWord0
            case .twoChildren:
                switch position {
                case 0: rawChildIndex = compactNode.payloadWord0
                case 1: rawChildIndex = compactNode.payloadWord1
                default: preconditionFailure("Child index out of range")
                }
            case .manyChildren:
                precondition(position >= 0 && position < Int(compactNode.payloadWord1), "Child index out of range")
                rawChildIndex = store.edges[Int(compactNode.payloadWord0) + position]
            case .none, .index, .text:
                preconditionFailure("Child index out of range for a node without children")
            }
            return NodeReference(store: store, nodeIndex: SymbolStore.NodeIndex(rawValue: rawChildIndex))
        }
    }
}
