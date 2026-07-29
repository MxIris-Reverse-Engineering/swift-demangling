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
        DemanglingPrinter<String, NodeReference>.print(self, options: options)
    }

    /// Whether this subtree is structurally equal to a `Node` tree
    /// (kind + contents + children, recursively) without materializing
    /// anything.
    ///
    /// This is the bridge for callers that hold an externally demangled
    /// `Node` (for example from `demangleAsNode`) and need to find it among
    /// `NodeReference` dictionary keys: reference-to-reference equality stays
    /// O(1) via hash-consing, while reference-to-`Node` equality walks both
    /// trees.
    ///
    /// - Important: Text payloads compare by exact UTF-8 bytes — the unit the
    ///   store interns by — which is *stricter* than `Node.==`'s `String`
    ///   comparison (Unicode canonical equivalence). The store can hold the
    ///   NFC and NFD spellings of the same name as two distinct indices; a
    ///   canonical-equivalence bridge would make those unequal references both
    ///   equal one `Node`, and equality would stop being transitive. A `Node`
    ///   built from the same mangled bytes always matches; one built from a
    ///   differently normalized spelling deliberately does not.
    ///
    /// Walked with an explicit work list rather than by recursion: this is
    /// public API over trees of arbitrary depth, called from whatever thread
    /// the consumer's dictionary lookup happens to be on. Pairs already proven
    /// equal are skipped, so a maximally shared DAG costs its node count, not
    /// its path count.
    public func structurallyEquals(_ node: Node) -> Bool {
        struct VisitedPair: Hashable {
            let referenceIndex: UInt32
            let nodeIdentity: ObjectIdentifier
        }
        var visitedPairs = Set<VisitedPair>()
        var pendingPairs: [(reference: NodeReference, node: Node)] = [(self, node)]

        while let pair = pendingPairs.popLast() {
            // A pair seen once contributes nothing new: on a shared DAG the
            // same (index, instance) pair recurs once per *path*, and every
            // recurrence repeats the identical subtree comparison. Any
            // mismatch below a repeated pair aborts the whole walk the first
            // time, so skipping repeats never changes the outcome.
            let visitedPair = VisitedPair(
                referenceIndex: pair.reference.nodeIndex.rawValue,
                nodeIdentity: ObjectIdentifier(pair.node)
            )
            guard visitedPairs.insert(visitedPair).inserted else { continue }

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
                // Exact bytes, not `String ==`: see the doc comment.
                guard let bytes = pair.reference.textUTF8, bytes.elementsEqual(textValue.utf8) else { return false }
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
    /// subtrees. Text payloads compare by exact string-table bytes — see
    /// the `Node` overload for why canonical-equivalence fallback would
    /// break transitivity.
    /// Walked with an explicit work list rather than by recursion, for the same
    /// reason as the `Node` overload, and with the same proven-pair skip so a
    /// shared DAG costs its node count rather than its path count.
    ///
    /// The same-store test sits inside the loop, but it can only ever fire on
    /// the first pair: a reference's children always come from its own store, so
    /// a cross-store comparison has store A on the left and store B on the right
    /// at every level. It is kept in the loop only so the root case reads as one
    /// rule rather than two.
    public func structurallyEquals(_ other: NodeReference) -> Bool {
        struct VisitedPair: Hashable {
            let leftIndex: UInt32
            let rightIndex: UInt32
        }
        var visitedPairs = Set<VisitedPair>()
        var pendingPairs: [(left: NodeReference, right: NodeReference)] = [(self, other)]

        while let pair = pendingPairs.popLast() {
            if pair.left.store === pair.right.store {
                guard pair.left.nodeIndex == pair.right.nodeIndex else { return false }
                continue
            }
            let visitedPair = VisitedPair(
                leftIndex: pair.left.nodeIndex.rawValue,
                rightIndex: pair.right.nodeIndex.rawValue
            )
            guard visitedPairs.insert(visitedPair).inserted else { continue }

            let compact = pair.left.compactNode
            let otherCompact = pair.right.compactNode
            guard compact.kind == otherCompact.kind else { return false }

            switch (compact.payloadKind, otherCompact.payloadKind) {
            case (.text, .text):
                // Exact bytes, not `String ==`: see the `Node` overload.
                guard let bytes = pair.left.textUTF8, let otherBytes = pair.right.textUTF8,
                      bytes.elementsEqual(otherBytes)
                else { return false }
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
    /// elsewhere. Both sides combine one structural digest whose per-node
    /// seeding is the shared `Node.seededDigestHasher`, so the two encodings
    /// cannot drift apart.
    ///
    /// The digest is computed bottom-up with a per-call memo keyed by store
    /// index — a store is maximally shared by construction, so a per-path walk
    /// here quadrupled its visit count with every shared level (measured
    /// 615,165× amplification on a 137-character symbol). Memoized, the cost
    /// is the store's node count. Walked with an explicit frame stack: public
    /// API, arbitrary depth.
    public func structuralHash(into hasher: inout Hasher) {
        hasher.combine(structuralDigest())
    }

    /// The reference half of the structural digest; see ``Node/structuralDigest()``.
    func structuralDigest() -> UInt64 {
        let rootCompact = compactNode
        let rootChildren = children
        if rootChildren.isEmpty {
            let leafHasher = Node.seededDigestHasher(kind: rootCompact.kind, contents: nodeContents, childCount: 0)
            return UInt64(bitPattern: Int64(leafHasher.finalize()))
        }

        struct DigestFrame {
            let reference: NodeReference
            var hasher: Hasher
            var nextChildIndex: Int
        }

        func seededHasher(for reference: NodeReference) -> Hasher {
            Node.seededDigestHasher(
                kind: reference.kind,
                contents: reference.nodeContents,
                childCount: reference.children.count
            )
        }

        var digestByIndex: [UInt32: UInt64] = [:]
        var frames: [DigestFrame] = [
            DigestFrame(reference: self, hasher: seededHasher(for: self), nextChildIndex: 0),
        ]
        var lastCompletedDigest: UInt64 = 0
        var pendingChildDigest: UInt64?

        while var frame = frames.popLast() {
            if let childDigest = pendingChildDigest {
                frame.hasher.combine(childDigest)
                pendingChildDigest = nil
            }

            let childrenView = frame.reference.children
            var descended = false
            while frame.nextChildIndex < childrenView.count {
                let child = childrenView[frame.nextChildIndex]
                frame.nextChildIndex += 1
                let childIndex = child.nodeIndex.rawValue
                if let knownDigest = digestByIndex[childIndex] {
                    frame.hasher.combine(knownDigest)
                } else if child.children.isEmpty {
                    let leafHasher = seededHasher(for: child)
                    let leafDigest = UInt64(bitPattern: Int64(leafHasher.finalize()))
                    digestByIndex[childIndex] = leafDigest
                    frame.hasher.combine(leafDigest)
                } else {
                    frames.append(frame)
                    frames.append(DigestFrame(reference: child, hasher: seededHasher(for: child), nextChildIndex: 0))
                    descended = true
                    break
                }
            }
            if descended { continue }

            let completedHasher = frame.hasher
            let digest = UInt64(bitPattern: Int64(completedHasher.finalize()))
            digestByIndex[frame.reference.nodeIndex.rawValue] = digest
            lastCompletedDigest = digest
            pendingChildDigest = digest
        }

        // The last frame to complete is always the root.
        return lastCompletedDigest
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
