/// A lightweight handle to a node stored in a `NodeStore`.
///
/// Sixteen bytes as a value: a store reference plus a node index.
///
/// ## Equality is per-arena, and that is the whole design
///
/// `==` compares store identity and index, so it answers in O(1). That is not
/// a weaker form of structural equality — **within one store it is exactly
/// structural equality up to the spelling of text**, because a
/// `NodeStoreBuilder` hash-conses on insert: two structurally identical trees
/// interned into the same arena resolve to the same index, and `Set` /
/// `Dictionary` deduplicate them (pinned by
/// `NodeReferenceInterningConvenienceTests.hashedCollectionsDeduplicateWithinOneArena`:
/// 100 copies of one symbol collapse to a one-element `Set`). Since bulk
/// indexing — the case this type exists for — puts every tree in one arena,
/// that is the case that matters.
///
/// The "up to the spelling of text" qualifier is the one exception, and it is
/// deliberate: text is interned by **exact UTF-8 bytes**, so two identifiers
/// that are Unicode-canonically equal but differently spelled (NFC `caf\u{e9}`
/// vs NFD `cafe\u{301}`) receive two indices in one arena — `Set<NodeReference>`
/// keeps both where `Set<Node>` collapses them, since `Node.contents` compares
/// through `String`. Byte exactness is what keeps the cross-representation
/// bridge transitive; see ``structurallyEquals(_:)-(Node)`` for the reasoning.
/// Reaching this requires the same identifier to appear in two spellings
/// within one process, which demangled input does not produce on its own.
///
/// Across *different* stores `==` is false even for identical trees, and this
/// is deliberate: making it structural would turn a pointer-and-integer
/// comparison into a two-tree walk on every hash bucket probe, which is the
/// cost this 16-byte handle exists to avoid. Reach for the explicit pair when
/// arenas differ:
///
/// - ``structurallyEquals(_:)-(NodeReference)`` / ``structurallyEquals(_:)-(Node)``
/// - ``structuralHash(into:)`` — agrees with `Node.hash(into:)`, so a value
///   type may key a dictionary by node structure while storing a reference.
///
/// So: same arena → use `==` freely; mixed arenas → use the structural pair.
/// A `Set` that fails to deduplicate is the signature of one arena per
/// element, which ``init(interning:)`` produces by design — see its note.
/// Rationale and measurements: `Documentations/NodeStoreArena.md`, in the
/// section on cross-representation equality and hashing.
public struct NodeReference: Sendable {
    public let store: NodeStore
    public let nodeIndex: NodeStore.NodeIndex

    @usableFromInline
    init(store: NodeStore, nodeIndex: NodeStore.NodeIndex) {
        self.store = store
        self.nodeIndex = nodeIndex
    }

    /// Interns a single `Node` tree into a **fresh private store** and
    /// references its root.
    ///
    /// This is the convenience path for holding one externally built tree
    /// (for example a transient demangle or a synthesized `Node`) in
    /// compact form: the reference keeps its private store alive, so the
    /// value is self-contained and `Sendable`.
    ///
    /// - Important: one call, one arena — so this is the wrong tool for a
    ///   batch. Deduplication and compactness are both properties *of an
    ///   arena*, and giving every tree its own arena forfeits both:
    ///
    ///   ```swift
    ///   // WRONG: N arenas, so no two elements are ever ==, and the Set
    ///   // keeps all N. Measured on 300 references over 3 unique symbols:
    ///   // 300 entries, 59,700 bytes retained.
    ///   let unique = Set(symbols.map { NodeReference(interning: try demangleAsNode($0)) })
    ///
    ///   // RIGHT: one arena, hash-consed on insert, so identical trees land
    ///   // on one index and `==` is structural. Same 300 trees: 3 entries,
    ///   // 541 bytes.
    ///   var builder = NodeStoreBuilder()
    ///   let indices = try symbols.map { try builder.demangle($0) }
    ///   let store = builder.freeze()
    ///   let unique = Set(indices.map { store.reference(at: $0) })
    ///   ```
    ///
    ///   If references from separate arenas genuinely have to be compared or
    ///   keyed together, use ``structurallyEquals(_:)-(NodeReference)`` and
    ///   ``structuralHash(into:)`` rather than `==` / `hash(into:)`. See the
    ///   note on ``NodeReference`` itself.
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
        store.textOfNode(at: nodeIndex.rawValue)
    }

    /// This node's text as a freshly copied UTF-8 byte array. Only covers
    /// text physically stored in the store's string table;
    /// `.dependentGenericParamType`'s synthesized name is not included
    /// (use `text` for the composed form).
    ///
    /// A **copying** accessor since the string table moved off
    /// `ContiguousArray` into self-managed storage (proposal 0010, step 1):
    /// every access allocates the returned array. This was `textUTF8:
    /// ArraySlice<UInt8>?` before, whose indices were *store-table* offsets
    /// on `main` but silently became 0-based when the implementation turned
    /// into a copy — the rename and the `Array` return type make both the
    /// copy and the 0-based indices part of the signature, so downstream
    /// code that related slice indices to the string table fails to compile
    /// instead of silently misreading (ReviewFindingsPR7 F10, maintainer
    /// decision: surface at compile time). New code should prefer
    /// ``withTextUTF8(_:)`` (or, on modern runtimes, ``textUTF8Span()``),
    /// which borrow the stored bytes without copying.
    public var textUTF8Bytes: [UInt8]? {
        let compact = compactNode
        guard case .text = compact.payloadKind else { return nil }
        return store.withTextUTF8(at: nodeIndex.rawValue) { spanBytes in
            var copiedBytes = [UInt8]()
            copiedBytes.reserveCapacity(spanBytes.count)
            for byteOffset in 0 ..< spanBytes.count {
                copiedBytes.append(spanBytes[byteOffset])
            }
            return copiedBytes
        }
    }

    /// Borrows this node's text as UTF-8 bytes in the store's string table
    /// (proposal 0008, B1) — the all-platform baseline form.
    ///
    /// Returns nil, without calling `body`, when the node stores no text.
    /// Like ``textUTF8Bytes``, this covers only text physically stored in the
    /// table; `.dependentGenericParamType`'s synthesized name is not stored
    /// text (use ``text`` for the composed form).
    public func withTextUTF8<Result>(_ body: (Span<UInt8>) throws -> Result) rethrows -> Result? {
        try store.withTextUTF8(at: nodeIndex.rawValue, body)
    }

    #if hasFeature(Lifetimes)
    /// Direct-return borrowed view of this node's stored text bytes
    /// (proposal 0008, B1).
    ///
    /// Dual-gated: the `@_lifetime` spelling needs the `Lifetimes` compiler
    /// feature, and the `.span` property the implementation reads needs the
    /// macOS 26 runtime — on older runtimes use ``withTextUTF8(_:)``. SPI
    /// consumers accept that this API surface may be absent on a compiler
    /// without the feature.
    @_spi(Internals)
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
    @_lifetime(borrow self)
    public borrowing func textUTF8Span() -> Span<UInt8>? {
        let compact = compactNode
        guard case .text = compact.payloadKind else { return nil }
        let start = Int(compact.payloadWord0)
        let length = Int(compact.payloadWord1)
        let resolvedView = store.currentView
        precondition(start + length <= resolvedView.textBytes.count, "Text range out of range for this store")
        // The span is formed over the raw storage; the override rebinds its
        // dependence to `self`, which keeps the store — and with it the
        // allocation — alive. See `NodeStore.textBytesSpan()` for the full
        // reasoning.
        let textBuffer = UnsafeBufferPointer(start: resolvedView.textBytes.baseAddress! + start, count: length)
        let span = textBuffer.span
        return _overrideLifetime(span, borrowing: self)
    }
    #endif

    /// Allocation-free witness: compares string-table bytes directly for
    /// ASCII needles (every kind/sugar check the printer performs), falling
    /// back to `String` comparison for non-ASCII to preserve Unicode
    /// canonical-equivalence semantics.
    public func isIdentifier(desired: String) -> Bool {
        guard kind == .identifier else { return false }
        return store.nodeTextMatches(at: nodeIndex.rawValue, expected: desired)
    }

    /// Allocation-free witness, same strategy as `isIdentifier(desired:)`.
    public var isSwiftModule: Bool {
        guard kind == .module else { return false }
        return store.nodeTextMatches(at: nodeIndex.rawValue, expected: stdlibName)
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
        store.contents(of: compactNode)
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
    ///
    /// - Important: identity is not stable across calls — every call returns
    ///   a new instance, so two materializations of the same reference are
    ///   never `===`, unlike the `Node` path where `NodeCache` interning
    ///   hands out one canonical instance. Key long-lived state by the
    ///   `NodeReference` itself (store identity + index) or by a structural
    ///   key (e.g. the remangled string) — never by `ObjectIdentifier` of a
    ///   materialized node.
    public func materialize() -> Node {
        store.materializeNode(at: nodeIndex.rawValue)
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
        store.withSpans { nodeSpan, edgeSpan, textSpan in
            struct VisitedPair: Hashable {
                let referenceIndex: UInt32
                let nodeIdentity: ObjectIdentifier
            }
            var visitedPairs = Set<VisitedPair>()
            var pendingPairs: [(rawIndex: UInt32, node: Node)] = [(nodeIndex.rawValue, node)]

            while let pair = pendingPairs.popLast() {
                // A pair seen once contributes nothing new: on a shared DAG the
                // same (index, instance) pair recurs once per *path*, and every
                // recurrence repeats the identical subtree comparison. Any
                // mismatch below a repeated pair aborts the whole walk the first
                // time, so skipping repeats never changes the outcome.
                let visitedPair = VisitedPair(
                    referenceIndex: pair.rawIndex,
                    nodeIdentity: ObjectIdentifier(pair.node)
                )
                guard visitedPairs.insert(visitedPair).inserted else { continue }

                let compact = nodeSpan[Int(pair.rawIndex)]
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
                    guard store.indexPayload(of: compact) == indexValue else { return false }
                case .text(let textValue):
                    guard case .text = compact.payloadKind else { return false }
                    // Exact bytes, not `String ==`: see the doc comment.
                    let textUTF8View = textValue.utf8
                    guard Int(compact.payloadWord1) == textUTF8View.count else { return false }
                    var byteOffset = Int(compact.payloadWord0)
                    for expectedByte in textUTF8View {
                        guard textSpan[byteOffset] == expectedByte else { return false }
                        byteOffset += 1
                    }
                }

                let nodeChildren = pair.node.children
                guard compact.childCount == nodeChildren.count else { return false }
                for childPosition in 0 ..< compact.childCount {
                    pendingPairs.append((
                        NodeStore.rawChildIndex(of: compact, at: childPosition, edges: edgeSpan),
                        nodeChildren[childPosition]
                    ))
                }
            }
            return true
        }
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
    /// The same-store case is answered before any walk starts: within one
    /// store, hash-consing makes index equality coincide with structural
    /// equality, and a reference's children always come from its own store,
    /// so a cross-store comparison has store A on the left and store B on the
    /// right at every level — the walk below never mixes.
    public func structurallyEquals(_ other: NodeReference) -> Bool {
        if store === other.store {
            return nodeIndex == other.nodeIndex
        }
        return store.withSpans { leftNodes, leftEdges, leftText in
            other.store.withSpans { rightNodes, rightEdges, rightText in
                struct VisitedPair: Hashable {
                    let leftIndex: UInt32
                    let rightIndex: UInt32
                }
                var visitedPairs = Set<VisitedPair>()
                var pendingPairs: [(leftIndex: UInt32, rightIndex: UInt32)] = [(nodeIndex.rawValue, other.nodeIndex.rawValue)]

                while let pair = pendingPairs.popLast() {
                    let visitedPair = VisitedPair(
                        leftIndex: pair.leftIndex,
                        rightIndex: pair.rightIndex
                    )
                    guard visitedPairs.insert(visitedPair).inserted else { continue }

                    let compact = leftNodes[Int(pair.leftIndex)]
                    let otherCompact = rightNodes[Int(pair.rightIndex)]
                    guard compact.kind == otherCompact.kind else { return false }

                    switch (compact.payloadKind, otherCompact.payloadKind) {
                    case (.text, .text):
                        // Exact bytes, not `String ==`: see the `Node` overload.
                        guard compact.payloadWord1 == otherCompact.payloadWord1 else { return false }
                        let leftStart = Int(compact.payloadWord0)
                        let rightStart = Int(otherCompact.payloadWord0)
                        for byteOffset in 0 ..< Int(compact.payloadWord1) {
                            guard leftText[leftStart + byteOffset] == rightText[rightStart + byteOffset] else { return false }
                        }
                    case (.index, .index):
                        guard compact.payloadWord0 == otherCompact.payloadWord0,
                              compact.payloadWord1 == otherCompact.payloadWord1
                        else { return false }
                    case (.text, _), (_, .text), (.index, _), (_, .index):
                        return false
                    default:
                        break
                    }

                    guard compact.childCount == otherCompact.childCount else { return false }
                    for childPosition in 0 ..< compact.childCount {
                        pendingPairs.append((
                            NodeStore.rawChildIndex(of: compact, at: childPosition, edges: leftEdges),
                            NodeStore.rawChildIndex(of: otherCompact, at: childPosition, edges: rightEdges)
                        ))
                    }
                }
                return true
            }
        }
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
    /// Store identity plus index — O(1), and **structural equality whenever
    /// both sides come from the same arena**, which is the intended use.
    ///
    /// A `NodeStoreBuilder` hash-conses on insert, so within one store
    /// "same index" and "same structure" are the same statement; `Set` and
    /// `Dictionary` therefore deduplicate normally there. This is not an
    /// oversight to be "fixed" by walking the trees: that would replace a
    /// pointer-and-integer compare with a full traversal on every bucket
    /// probe, in the type whose entire purpose is to be a 16-byte handle.
    ///
    /// Two references from *different* stores are unequal even when the trees
    /// are identical. Compare those with
    /// ``structurallyEquals(_:)-(NodeReference)`` and key them with
    /// ``structuralHash(into:)``. A `Set` that does not deduplicate means one
    /// arena per element — see ``init(interning:)``,
    /// `NodeReferenceInterningConvenienceTests.separateArenasAreUnequalButStructurallyEqual`
    /// for that boundary spelled out, and `Documentations/NodeStoreArena.md`
    /// for the rationale in full.
    public static func == (lhs: NodeReference, rhs: NodeReference) -> Bool {
        lhs.store === rhs.store && lhs.nodeIndex == rhs.nodeIndex
    }

    /// Matches ``==``: keyed by arena identity and index, not by structure.
    /// For structure-keyed hashing that agrees with `Node.hash(into:)`, use
    /// ``structuralHash(into:)``.
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
    ///
    /// Walks raw indices over span-borrowed buffers (proposal 0008, B2): the
    /// buffers are borrowed once at the entry, so the loop neither constructs
    /// a `NodeReference` per child (a store retain/release each) nor reloads
    /// the arrays through the class property on every access. Text contents
    /// still materialize through `store.contents(of:)` — hashing the same
    /// `String` values `Node.hash(into:)` hashes is what keeps the two
    /// digests interchangeable.
    func structuralDigest() -> UInt64 {
        let store = store
        return store.withSpans { nodeSpan, edgeSpan, _ in
            let rootCompact = nodeSpan[Int(nodeIndex.rawValue)]
            if rootCompact.childCount == 0 {
                let leafHasher = Node.seededDigestHasher(kind: rootCompact.kind, contents: store.contents(of: rootCompact), childCount: 0)
                return UInt64(bitPattern: Int64(leafHasher.finalize()))
            }

            struct DigestFrame {
                let rawIndex: UInt32
                let childCount: Int
                var hasher: Hasher
                var nextChildIndex: Int
            }

            var digestByIndex: [UInt32: UInt64] = [:]
            var frames: [DigestFrame] = [
                DigestFrame(
                    rawIndex: nodeIndex.rawValue,
                    childCount: rootCompact.childCount,
                    hasher: Node.seededDigestHasher(kind: rootCompact.kind, contents: store.contents(of: rootCompact), childCount: rootCompact.childCount),
                    nextChildIndex: 0
                ),
            ]
            var lastCompletedDigest: UInt64 = 0
            var pendingChildDigest: UInt64?

            while var frame = frames.popLast() {
                if let childDigest = pendingChildDigest {
                    frame.hasher.combine(childDigest)
                    pendingChildDigest = nil
                }

                let frameCompact = nodeSpan[Int(frame.rawIndex)]
                var descended = false
                while frame.nextChildIndex < frame.childCount {
                    let childIndex = NodeStore.rawChildIndex(of: frameCompact, at: frame.nextChildIndex, edges: edgeSpan)
                    frame.nextChildIndex += 1
                    let childCompact = nodeSpan[Int(childIndex)]
                    if let knownDigest = digestByIndex[childIndex] {
                        frame.hasher.combine(knownDigest)
                    } else if childCompact.childCount == 0 {
                        let leafHasher = Node.seededDigestHasher(kind: childCompact.kind, contents: store.contents(of: childCompact), childCount: 0)
                        let leafDigest = UInt64(bitPattern: Int64(leafHasher.finalize()))
                        digestByIndex[childIndex] = leafDigest
                        frame.hasher.combine(leafDigest)
                    } else {
                        frames.append(frame)
                        frames.append(DigestFrame(
                            rawIndex: childIndex,
                            childCount: childCompact.childCount,
                            hasher: Node.seededDigestHasher(kind: childCompact.kind, contents: store.contents(of: childCompact), childCount: childCompact.childCount),
                            nextChildIndex: 0
                        ))
                        descended = true
                        break
                    }
                }
                if descended { continue }

                let completedHasher = frame.hasher
                let digest = UInt64(bitPattern: Int64(completedHasher.finalize()))
                digestByIndex[frame.rawIndex] = digest
                lastCompletedDigest = digest
                pendingChildDigest = digest
            }

            // The last frame to complete is always the root.
            return lastCompletedDigest
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
            NodeReference(store: store, nodeIndex: store.nodeIndex(forRaw: store.rawChildIndex(of: compactNode, at: position)))
        }
    }
}
