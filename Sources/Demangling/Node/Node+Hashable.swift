extension Node: Hashable {
    /// Hashes the whole subtree in one `combine` of its structural digest.
    ///
    /// The digest is computed bottom-up with a per-call memo keyed by node
    /// identity, so a maximally shared DAG — which hash-consed demangling and
    /// `NodeStore` materialization both produce — costs its *node* count, not
    /// its *path* count. A per-path walk here was measured at 615,165×
    /// amplification on a 137-character symbol, with no bound on deeper ones.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(structuralDigest())
    }

    /// Hashes this subtree by structure, the `Node` half of the pair whose
    /// other half is ``NodeReference/structuralHash(into:)``.
    ///
    /// `Node`'s own `hash(into:)` is already structural, so this is a spelling
    /// that makes the symmetry visible at the call site: a dictionary keyed by
    /// node structure can hash `Node` and `NodeReference` keys the same way and
    /// look one up with the other.
    @inlinable
    public func structuralHash(into hasher: inout Hasher) {
        hash(into: &hasher)
    }

    /// Seeds the per-node hasher with everything a node contributes besides
    /// its children. ``NodeReference`` seeds with the identical sequence —
    /// that shared shape is what keeps the two digests in agreement.
    static func seededDigestHasher(kind: Node.Kind, contents: Node.Contents, childCount: Int) -> Hasher {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(contents)
        hasher.combine(childCount)
        return hasher
    }

    /// The structural digest: a per-node 64-bit value folding kind, contents,
    /// child count and the *digests* of the children. Stable within a process
    /// (it inherits `Hasher`'s per-process seed), never across processes.
    ///
    /// Computed with an explicit frame stack — this is public API over trees
    /// of arbitrary depth — and a memo keyed by node identity, so every
    /// distinct node is digested exactly once per call.
    func structuralDigest() -> UInt64 {
        // Leaves are the overwhelming majority of nodes and the common case
        // for a dictionary key; they must pay for neither a memo nor a stack.
        let rootChildren = children
        if rootChildren.isEmpty {
            let hasher = Self.seededDigestHasher(kind: kind, contents: contents, childCount: 0)
            return UInt64(bitPattern: Int64(hasher.finalize()))
        }

        struct DigestFrame {
            let node: Node
            var hasher: Hasher
            var nextChildIndex: Int
        }

        var digestByIdentity: [ObjectIdentifier: UInt64] = [:]
        var frames: [DigestFrame] = [
            DigestFrame(
                node: self,
                hasher: Self.seededDigestHasher(kind: kind, contents: contents, childCount: rootChildren.count),
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

            let childrenView = frame.node.children
            var descended = false
            while frame.nextChildIndex < childrenView.count {
                let child = childrenView[frame.nextChildIndex]
                frame.nextChildIndex += 1
                let childIdentity = ObjectIdentifier(child)
                if let knownDigest = digestByIdentity[childIdentity] {
                    frame.hasher.combine(knownDigest)
                } else if child.children.isEmpty {
                    let leafHasher = Self.seededDigestHasher(kind: child.kind, contents: child.contents, childCount: 0)
                    let leafDigest = UInt64(bitPattern: Int64(leafHasher.finalize()))
                    digestByIdentity[childIdentity] = leafDigest
                    frame.hasher.combine(leafDigest)
                } else {
                    frames.append(frame)
                    frames.append(DigestFrame(
                        node: child,
                        hasher: Self.seededDigestHasher(kind: child.kind, contents: child.contents, childCount: child.children.count),
                        nextChildIndex: 0
                    ))
                    descended = true
                    break
                }
            }
            if descended { continue }

            let completedHasher = frame.hasher
            let digest = UInt64(bitPattern: Int64(completedHasher.finalize()))
            digestByIdentity[ObjectIdentifier(frame.node)] = digest
            lastCompletedDigest = digest
            pendingChildDigest = digest
        }

        // The last frame to complete is always the root.
        return lastCompletedDigest
    }

    /// Structural equality over the whole subtree.
    ///
    /// Walked with an explicit work list — public API, arbitrary depth.
    /// Identical nodes short-circuit on identity, which makes this cheap for
    /// the interned trees ``NodeCache`` hands out. Long walks additionally
    /// memoize visited pairs, so comparing two separately built DAGs costs
    /// their node counts rather than their path counts; the memo is created
    /// lazily because the overwhelmingly common comparisons — leaves, and
    /// canonicalized trees whose children `===`-match immediately — should not
    /// allocate for it.
    public static func == (lhs: Node, rhs: Node) -> Bool {
        // Interned trees compare by identity almost always, and leaves have no
        // children to walk; neither may pay for a work list.
        if lhs === rhs { return true }
        guard lhs.kind == rhs.kind, lhs.contents == rhs.contents else { return false }
        let rootLeftChildren = lhs.children
        let rootRightChildren = rhs.children
        guard rootLeftChildren.count == rootRightChildren.count else { return false }
        if rootLeftChildren.isEmpty { return true }

        struct VisitedPair: Hashable {
            let leftIdentity: ObjectIdentifier
            let rightIdentity: ObjectIdentifier
        }
        /// Walk length at which the pair memo switches on: real comparisons
        /// between demangler-shaped trees finish long before this, while a
        /// path-exploding DAG blows past it immediately.
        let visitedPairTrackingThreshold = 256
        var visitedPairs: Set<VisitedPair>?
        var processedPairCount = 0

        var pendingPairs: [(left: Node, right: Node)] = Array(zip(rootLeftChildren, rootRightChildren).map { ($0, $1) })

        while let pair = pendingPairs.popLast() {
            if pair.left === pair.right { continue }

            processedPairCount += 1
            if processedPairCount > visitedPairTrackingThreshold, visitedPairs == nil {
                visitedPairs = []
            }
            if visitedPairs != nil {
                let visitedPair = VisitedPair(
                    leftIdentity: ObjectIdentifier(pair.left),
                    rightIdentity: ObjectIdentifier(pair.right)
                )
                // A repeated pair repeats the identical subtree comparison,
                // and any mismatch below it already aborted the whole walk
                // the first time.
                guard visitedPairs!.insert(visitedPair).inserted else { continue }
            }

            guard pair.left.kind == pair.right.kind, pair.left.contents == pair.right.contents else {
                return false
            }
            let leftChildren = pair.left.children
            let rightChildren = pair.right.children
            guard leftChildren.count == rightChildren.count else { return false }
            for (leftChild, rightChild) in zip(leftChildren, rightChildren) {
                pendingPairs.append((leftChild, rightChild))
            }
        }

        return true
    }
}
