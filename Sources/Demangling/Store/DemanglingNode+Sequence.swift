/// Tree traversal shared by every `DemanglingNode` representation.
///
/// These are the single implementations behind `Node`'s and
/// `NodeReference`'s `Sequence` conformances and the kind-lookup helpers
/// (`first(of:)`, `all(of:)`, `contains(_:)`) — one copy, both
/// representations, mirroring the derived-helper rule in
/// `DemanglingNode.swift`.
extension DemanglingNode {
    public func preorder() -> some Sequence<Self> {
        PreorderSequence(root: self)
    }

    public func inorder() -> some Sequence<Self> {
        InorderSequence(root: self)
    }

    public func postorder() -> some Sequence<Self> {
        PostorderSequence(root: self)
    }

    public func levelorder() -> some Sequence<Self> {
        LevelorderSequence(root: self)
    }
}

private struct PreorderSequence<SomeNode: DemanglingNode>: Sequence {
    struct Iterator: IteratorProtocol {
        private var stack: [SomeNode]

        fileprivate init(root: SomeNode) {
            self.stack = [root]
        }

        mutating func next() -> SomeNode? {
            guard !stack.isEmpty else { return nil }

            let current = stack.removeLast()

            // Add children in reverse order so we visit them left-to-right
            for child in current.children.reversed() {
                stack.append(child)
            }

            return current
        }
    }

    private let root: SomeNode

    fileprivate init(root: SomeNode) {
        self.root = root
    }

    func makeIterator() -> Iterator {
        Iterator(root: root)
    }
}

private struct InorderSequence<SomeNode: DemanglingNode>: Sequence {
    struct Iterator: IteratorProtocol {
        private var stack: [SomeNode]
        private var current: SomeNode?

        fileprivate init(root: SomeNode) {
            self.stack = []
            self.current = root
        }

        mutating func next() -> SomeNode? {
            while current != nil || !stack.isEmpty {
                // Go to the leftmost node
                while let node = current {
                    stack.append(node)
                    current = node.children.first
                }

                // Current must be nil at this point
                if let node = stack.popLast() {
                    current = node.children.count > 1 ? node.children[1] : nil
                    return node
                }
            }
            return nil
        }
    }

    private let root: SomeNode

    fileprivate init(root: SomeNode) {
        self.root = root
    }

    func makeIterator() -> Iterator {
        Iterator(root: root)
    }
}

private struct PostorderSequence<SomeNode: DemanglingNode>: Sequence {
    struct Iterator: IteratorProtocol {
        private var stack: [(node: SomeNode, visited: Bool)]

        fileprivate init(root: SomeNode) {
            self.stack = [(root, false)]
        }

        mutating func next() -> SomeNode? {
            while !stack.isEmpty {
                let (node, visited) = stack.removeLast()

                if visited {
                    return node
                } else {
                    // Mark as visited and push back
                    stack.append((node, true))

                    // Push children in reverse order
                    for child in node.children.reversed() {
                        stack.append((child, false))
                    }
                }
            }
            return nil
        }
    }

    private let root: SomeNode

    fileprivate init(root: SomeNode) {
        self.root = root
    }

    func makeIterator() -> Iterator {
        Iterator(root: root)
    }
}

private struct LevelorderSequence<SomeNode: DemanglingNode>: Sequence {
    struct Iterator: IteratorProtocol {
        private var queue: [SomeNode]

        fileprivate init(root: SomeNode) {
            self.queue = [root]
        }

        mutating func next() -> SomeNode? {
            guard !queue.isEmpty else { return nil }

            let current = queue.removeFirst()

            // Add all children to the queue
            queue.append(contentsOf: current.children)

            return current
        }
    }

    private let root: SomeNode

    fileprivate init(root: SomeNode) {
        self.root = root
    }

    func makeIterator() -> Iterator {
        Iterator(root: root)
    }
}

// MARK: - Kind lookup over any node sequence

extension Sequence where Element: DemanglingNode {
    @inlinable
    public func first(of kind: Node.Kind) -> Element? {
        first { $0.kind == kind }
    }

    @inlinable
    public func first(of kinds: Node.Kind...) -> Element? {
        first { kinds.contains($0.kind) }
    }

    @inlinable
    public func contains(_ kind: Node.Kind) -> Bool {
        contains { $0.kind == kind }
    }

    @inlinable
    public func contains(_ kinds: Node.Kind...) -> Bool {
        contains { kinds.contains($0.kind) }
    }

    @inlinable
    public func all(of kind: Node.Kind) -> [Element] {
        filter { $0.kind == kind }
    }

    @inlinable
    public func all(of kinds: Node.Kind...) -> [Element] {
        filter { kinds.contains($0.kind) }
    }

    @inlinable
    public func all(of kinds: [Node.Kind]) -> [Element] {
        filter { kinds.contains($0.kind) }
    }

    @inlinable
    public func filter(of kind: Node.Kind) -> some Sequence<Element> {
        filter { $0.kind == kind }
    }

    @inlinable
    public func filter(of kinds: Node.Kind...) -> some Sequence<Element> {
        filter { kinds.contains($0.kind) }
    }
}

// MARK: - Short-circuit kind queries over a whole subtree

extension DemanglingNode where Self: Sequence, Self.Element == Self {
    /// One identity-deduped preorder pass returning the first node whose kind
    /// the predicate accepts.
    ///
    /// Deduping is sound for *short-circuit* queries specifically: a repeat
    /// visit of a shared instance cannot contain anything its first visit did
    /// not, so "the first match in preorder" and "is there a match at all"
    /// have the same answer either way — while the walk costs the node count
    /// instead of the path count. The enumerating queries (`all(of:)`,
    /// `filter(of:)`, the `preorder()` family) deliberately do NOT get this:
    /// they enumerate the logical tree, where occurrence counts are the
    /// correct answer (`KnownIssues.md` N6).
    func firstNodeInDedupedPreorder(matching kindMatches: (Node.Kind) -> Bool) -> Self? {
        var pendingNodes: [Self] = [self]
        var visitedNodes: Set<PrintCacheIdentity> = []
        while let currentNode = pendingNodes.popLast() {
            guard visitedNodes.insert(currentNode.printCacheIdentity).inserted else { continue }
            if kindMatches(currentNode.kind) { return currentNode }
            // Reversed push keeps the pop order preorder (leftmost first).
            for child in currentNode.children.reversed() {
                pendingNodes.append(child)
            }
        }
        return nil
    }

    /// The first node of `kind` in preorder, or `nil`.
    ///
    /// Overrides the `Sequence` implementation for whole-subtree queries: on a
    /// shared DAG that one costs 2^N, and a *fruitless* query — the common
    /// case, since most kinds are absent from most subtrees — pays it in full
    /// because there is nothing to short-circuit on. Measured before this
    /// existed: 18.2s on a 22-level doubling DAG, ×4 per two levels.
    public func first(of kind: Node.Kind) -> Self? {
        firstNodeInDedupedPreorder { $0 == kind }
    }

    public func first(of kinds: Node.Kind...) -> Self? {
        firstNodeInDedupedPreorder { kinds.contains($0) }
    }

    public func contains(_ kind: Node.Kind) -> Bool {
        firstNodeInDedupedPreorder { $0 == kind } != nil
    }

    public func contains(_ kinds: Node.Kind...) -> Bool {
        firstNodeInDedupedPreorder { kinds.contains($0) } != nil
    }
}

// MARK: - Identifier extraction

extension DemanglingNode where Self: Sequence, Self.Element == Self {
    /// The declaration identifier carried by this subtree, if any.
    /// Mirrors the historical `Node.identifier` lookup order.
    ///
    /// One deduped preorder pass replaces the historical chain of three
    /// `first(of:)` scans: the traversal machinery is path-based by design, so
    /// on a shared DAG the (typically fruitless) operator scan alone cost the
    /// path count — 2^N — before the identifier scan even started. Visiting
    /// each unique node once preserves every "first match in preorder" answer,
    /// because a repeat visit of a shared instance cannot contain anything its
    /// first visit did not (evolution 0006).
    public var identifier: String? {
        if let node = children.at(1), node.kind == .identifier {
            return node.text
        } else if let node = children.at(1), node.kind == .privateDeclName {
            return node.children.at(1)?.text
        }

        var firstIdentifier: Self?
        var firstPrivateDeclName: Self?
        var pendingNodes: [Self] = [self]
        var visitedNodes: Set<PrintCacheIdentity> = []
        while let currentNode = pendingNodes.popLast() {
            guard visitedNodes.insert(currentNode.printCacheIdentity).inserted else { continue }

            switch currentNode.kind {
            case .prefixOperator, .postfixOperator, .infixOperator:
                // Highest-priority group: the historical lookup preferred any
                // operator anywhere over an identifier found earlier.
                return currentNode.text
            case .identifier:
                if firstIdentifier == nil { firstIdentifier = currentNode }
            case .privateDeclName:
                if firstPrivateDeclName == nil { firstPrivateDeclName = currentNode }
            default:
                break
            }

            // Reversed push keeps the pop order preorder (leftmost first).
            for child in currentNode.children.reversed() {
                pendingNodes.append(child)
            }
        }

        if let firstIdentifier { return firstIdentifier.text }
        if let firstPrivateDeclName { return firstPrivateDeclName.children.at(1)?.text }
        return nil
    }
}

// MARK: - NodeReference as Sequence (preorder, mirroring Node)

extension NodeReference: Sequence {
    public typealias Element = NodeReference

    public func makeIterator() -> some IteratorProtocol<NodeReference> {
        preorder().makeIterator()
    }
}
