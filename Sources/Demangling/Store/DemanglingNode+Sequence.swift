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

// MARK: - Identifier extraction

extension DemanglingNode where Self: Sequence, Self.Element == Self {
    /// The declaration identifier carried by this subtree, if any.
    /// Mirrors the historical `Node.identifier` lookup order.
    public var identifier: String? {
        if let node = children.at(1), node.kind == .identifier {
            return node.text
        } else if let node = children.at(1), node.kind == .privateDeclName {
            return node.children.at(1)?.text
        } else if let node = first(of: .prefixOperator, .postfixOperator, .infixOperator) {
            return node.text
        } else if let node = first(of: .identifier) {
            return node.text
        } else if let node = first(of: .privateDeclName) {
            return node.children.at(1)?.text
        } else {
            return nil
        }
    }
}

// MARK: - NodeReference as Sequence (preorder, mirroring Node)

extension NodeReference: Sequence {
    public typealias Element = NodeReference

    public func makeIterator() -> some IteratorProtocol<NodeReference> {
        preorder().makeIterator()
    }
}
