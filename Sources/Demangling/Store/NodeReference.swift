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
    ///
    /// Mirrors `Node.text`: for `.dependentGenericParamType` (which stores
    /// `[depth, index]` as children rather than text) the generic parameter
    /// name is synthesized, matching what the printer expects.
    public var text: String? {
        let compact = compactNode
        if case .text = compact.payloadKind {
            return store.text(offset: compact.payloadWord0, length: compact.payloadWord1)
        }
        if compact.kind == .dependentGenericParamType {
            let childrenView = children
            guard let depth = childrenView.at(0)?.index, let parameterIndex = childrenView.at(1)?.index else { return nil }
            return genericParameterName(depth: depth, index: parameterIndex)
        }
        return nil
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

    /// Prints the demangled form of this subtree directly from the store,
    /// without materializing a `Node` tree (proposal 0001, Phase 2).
    public func print(using options: DemangleOptions = .default) -> String {
        StackSafeExecutor.execute {
            var printer = DemanglingPrinter<String, NodeReference>(options: options)
            return printer.printRoot(self)
        }
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
