/// A lightweight handle to a node stored in a `NodeStore`.
///
/// Sixteen bytes as a value: a store reference plus a node index. Because
/// stores are fully hash-consed, equality is O(1) — two references are equal
/// exactly when they address the same index of the same store, which within
/// one store coincides with structural equality.
public struct NodeReference: Sendable {
    public let store: NodeStore
    public let nodeIndex: NodeStore.NodeIndex

    @usableFromInline
    init(store: NodeStore, nodeIndex: NodeStore.NodeIndex) {
        self.store = store
        self.nodeIndex = nodeIndex
    }

    /// Interns a single `Node` tree into a fresh private store and
    /// references its root.
    ///
    /// This is the convenience path for holding one externally built tree
    /// (for example a transient demangle or a synthesized `Node`) in
    /// compact form: the reference keeps its private store alive, so the
    /// value is self-contained and `Sendable`. For bulk interning, drive a
    /// `NodeStoreBuilder` directly so trees share one arena and its
    /// deduplication.
    public init(interning node: Node) {
        var builder = NodeStoreBuilder()
        let rootNodeIndex = builder.intern(node)
        self = builder.freeze().reference(at: rootNodeIndex)
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

    /// Zero-copy view of this node's text as UTF-8 bytes in the store's
    /// string table. Only covers text physically stored in the table;
    /// `.dependentGenericParamType`'s synthesized name is not included
    /// (use `text` for the composed form).
    public var textUTF8: ArraySlice<UInt8>? {
        let compact = compactNode
        guard case .text = compact.payloadKind else { return nil }
        let start = Int(compact.payloadWord0)
        return store.textBytes[start ..< start + Int(compact.payloadWord1)]
    }

    /// Allocation-free witness: compares string-table bytes directly for
    /// ASCII needles (every kind/sugar check the printer performs), falling
    /// back to `String` comparison for non-ASCII to preserve Unicode
    /// canonical-equivalence semantics.
    public func isIdentifier(desired: String) -> Bool {
        guard kind == .identifier else { return false }
        return textMatches(desired)
    }

    /// Allocation-free witness, same strategy as `isIdentifier(desired:)`.
    public var isSwiftModule: Bool {
        guard kind == .module else { return false }
        return textMatches(stdlibName)
    }

    private func textMatches(_ expected: String) -> Bool {
        guard let bytes = textUTF8 else {
            return text == expected
        }
        let expectedUTF8 = expected.utf8
        guard expectedUTF8.allSatisfy({ $0 < 0x80 }) else {
            return text == expected
        }
        return bytes.elementsEqual(expectedUTF8)
    }

    /// The contents in exactly the form ``Node/contents`` reports them.
    ///
    /// Sharing `Node.Contents` rather than re-encoding the payload by hand is
    /// what keeps ``structuralHash(into:)`` in step with ``Node/hash(into:)``:
    /// the two hand-written encodings disagreed on the discriminator values, so
    /// structurally equal trees hashed differently and the documented
    /// dictionary-lookup use of ``structurallyEquals(_:)-(Node)`` could never
    /// find anything.
    ///
    /// Note this deliberately does not use ``text``, which synthesizes a name
    /// for `.dependentGenericParamType`; that node stores its depth and index
    /// as children, so `Node` reports `.none` for it and so must this.
    @usableFromInline
    var nodeContents: Node.Contents {
        let compact = compactNode
        switch compact.payloadKind {
        case .text:
            return .text(store.text(offset: compact.payloadWord0, length: compact.payloadWord1))
        case .index:
            return .index(UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32))
        case .none, .oneChild, .twoChildren, .manyChildren:
            return .none
        }
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

    /// Whether this subtree is structurally equal to a `Node` tree, matching
    /// the semantics of `Node.==` (kind + contents + children, recursively)
    /// without materializing anything.
    ///
    /// This is the bridge for callers that hold an externally demangled
    /// `Node` (for example from `demangleAsNode`) and need to find it among
    /// `NodeReference` dictionary keys: reference-to-reference equality stays
    /// O(1) via hash-consing, while reference-to-`Node` equality walks both
    /// trees. Text payloads compare by string-table bytes first and fall back
    /// to `String` equality so Unicode canonical equivalence matches `Node.==`.
    /// Walked with an explicit work list rather than by recursion: this is
    /// public API over trees of arbitrary depth, called from whatever thread
    /// the consumer's dictionary lookup happens to be on.
    public func structurallyEquals(_ node: Node) -> Bool {
        var pendingPairs: [(reference: NodeReference, node: Node)] = [(self, node)]

        while let pair = pendingPairs.popLast() {
            let compact = pair.reference.compactNode
            guard compact.kind == pair.node.kind else { return false }

            switch pair.node.contents {
            case .none:
                switch compact.payloadKind {
                case .index, .text:
                    return false
                case .none, .oneChild, .twoChildren, .manyChildren:
                    break
                }
            case .index(let indexValue):
                guard pair.reference.index == indexValue else { return false }
            case .text(let textValue):
                guard case .text = compact.payloadKind else { return false }
                guard let bytes = pair.reference.textUTF8 else { return false }
                if !bytes.elementsEqual(textValue.utf8) {
                    guard pair.reference.text == textValue else { return false }
                }
            }

            let referenceChildren = pair.reference.children
            let nodeChildren = pair.node.children
            guard referenceChildren.count == nodeChildren.count else { return false }
            for (referenceChild, nodeChild) in zip(referenceChildren, nodeChildren) {
                pendingPairs.append((referenceChild, nodeChild))
            }
        }
        return true
    }

    /// Whether this subtree is structurally equal to another reference's
    /// subtree, matching `Node.==` semantics across stores.
    ///
    /// Within one store this is O(1): hash-consing makes index equality
    /// coincide with structural equality. Across two stores it walks both
    /// subtrees. Text payloads compare by string-table bytes first and
    /// fall back to `String` equality so Unicode canonical equivalence
    /// matches `Node.==`.
    /// Walked with an explicit work list rather than by recursion, for the same
    /// reason as the `Node` overload.
    ///
    /// The same-store test sits inside the loop, but it can only ever fire on
    /// the first pair: a reference's children always come from its own store, so
    /// a cross-store comparison has store A on the left and store B on the right
    /// at every level. It is kept in the loop only so the root case reads as one
    /// rule rather than two.
    public func structurallyEquals(_ other: NodeReference) -> Bool {
        var pendingPairs: [(left: NodeReference, right: NodeReference)] = [(self, other)]

        while let pair = pendingPairs.popLast() {
            if pair.left.store === pair.right.store {
                guard pair.left.nodeIndex == pair.right.nodeIndex else { return false }
                continue
            }
            let compact = pair.left.compactNode
            let otherCompact = pair.right.compactNode
            guard compact.kind == otherCompact.kind else { return false }

            switch (compact.payloadKind, otherCompact.payloadKind) {
            case (.text, .text):
                guard let bytes = pair.left.textUTF8, let otherBytes = pair.right.textUTF8 else { return false }
                if !bytes.elementsEqual(otherBytes) {
                    guard pair.left.text == pair.right.text else { return false }
                }
            case (.index, .index):
                guard pair.left.index == pair.right.index else { return false }
            case (.text, _), (_, .text), (.index, _), (_, .index):
                return false
            default:
                break
            }

            let selfChildren = pair.left.children
            let otherChildren = pair.right.children
            guard selfChildren.count == otherChildren.count else { return false }
            for (selfChild, otherChild) in zip(selfChildren, otherChildren) {
                pendingPairs.append((selfChild, otherChild))
            }
        }
        return true
    }
}

// MARK: - CustomStringConvertible

extension NodeReference: CustomStringConvertible {
    /// Debug tree dump matching `Node.description`. Bridges through
    /// materialization — a debugging convenience, not a hot path.
    public var description: String {
        materialize().description
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

    /// Hashes this subtree by structure (kind + contents + children,
    /// recursively), consistent with `structurallyEquals(_:)` across
    /// stores: structurally equal references — even from different stores —
    /// produce the same hash.
    ///
    /// It agrees with ``Node/hash(into:)`` as well, which is what the
    /// documented use requires: a value type keying a dictionary by node
    /// structure while storing a `NodeReference` (whose intrinsic `Hashable` is
    /// store-identity based) has to be findable with a `Node` demangled
    /// elsewhere. Both sides feed the hasher a `Node.Contents`, so the two can
    /// no longer drift apart the way two hand-written payload encodings did.
    ///
    /// Walked with an explicit stack, mirroring ``Node/hash(into:)``. The visit
    /// order differs from a recursive implementation, but structurally equal
    /// subtrees still produce an identical sequence of `combine` calls, which
    /// is all the hash/equality contract requires.
    public func structuralHash(into hasher: inout Hasher) {
        var pendingReferences: [NodeReference] = [self]

        while let reference = pendingReferences.popLast() {
            hasher.combine(reference.kind)
            hasher.combine(reference.nodeContents)
            let childrenView = reference.children
            hasher.combine(childrenView.count)
            for child in childrenView {
                pendingReferences.append(child)
            }
        }
    }
}

// MARK: - ChildrenView

extension NodeReference {
    /// Random-access view of a node's children, resolved lazily from the store.
    public struct ChildrenView: RandomAccessCollection, Sendable {
        public typealias Element = NodeReference
        public typealias Index = Int

        @usableFromInline
        let store: NodeStore

        @usableFromInline
        let compactNode: CompactNode

        @usableFromInline
        init(store: NodeStore, compactNode: CompactNode) {
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
            return NodeReference(store: store, nodeIndex: NodeStore.NodeIndex(rawValue: rawChildIndex))
        }
    }
}
