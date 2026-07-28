extension Node: Hashable {
    /// Hashes the whole subtree.
    ///
    /// Walked with an explicit stack: `Node` is a tree of arbitrary depth and
    /// this is public API, so a caller holding a deeply nested type would
    /// otherwise recurse once per level on whatever thread it happens to be on.
    ///
    /// The visit order differs from a recursive implementation, but the
    /// hash/equality contract only requires that equal trees hash equally, and
    /// two equal trees produce an identical sequence of `combine` calls here.
    public func hash(into hasher: inout Hasher) {
        // Leaves are the overwhelming majority of nodes and the common case for
        // a dictionary key, so they must not pay for a work list.
        hasher.combine(kind)
        hasher.combine(contents)
        let rootChildren = children
        hasher.combine(rootChildren.count)
        if rootChildren.isEmpty {
            return
        }

        var pendingNodes: [Node] = Array(rootChildren)
        while let node = pendingNodes.popLast() {
            hasher.combine(node.kind)
            hasher.combine(node.contents)
            let childrenView = node.children
            hasher.combine(childrenView.count)
            for child in childrenView {
                pendingNodes.append(child)
            }
        }
    }

    /// Structural equality over the whole subtree.
    ///
    /// Walked with an explicit work list for the same reason as
    /// ``hash(into:)``. Identical nodes short-circuit on identity, which makes
    /// this cheap for the interned trees ``NodeCache`` hands out.
    public static func == (lhs: Node, rhs: Node) -> Bool {
        // Interned trees compare by identity almost always, and leaves have no
        // children to walk; neither may pay for a work list.
        if lhs === rhs { return true }
        guard lhs.kind == rhs.kind, lhs.contents == rhs.contents else { return false }
        let rootLeftChildren = lhs.children
        let rootRightChildren = rhs.children
        guard rootLeftChildren.count == rootRightChildren.count else { return false }
        if rootLeftChildren.isEmpty { return true }

        var pendingPairs: [(left: Node, right: Node)] = Array(zip(rootLeftChildren, rootRightChildren).map { ($0, $1) })

        while let pair = pendingPairs.popLast() {
            if pair.left === pair.right { continue }
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
