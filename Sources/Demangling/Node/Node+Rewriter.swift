/// One node's in-progress rewrite.
private struct RewriteFrame {
    let originalNode: Node
    var nextChildIndex: Int = 0
    var rewrittenChildren: [Node] = []
    var hasChildrenChanged: Bool = false
}

extension Node {
    open class Rewriter {
        public init() {}

        /// Rewrites the subtree bottom-up, calling ``visit(_:)`` on each node
        /// after its children have been rewritten.
        ///
        /// ``visit(_:)`` is invoked **once per unique node instance**, not once
        /// per occurrence: interning and substitution back-references make
        /// demangled trees DAGs, and a subtree instance referenced from several
        /// parents is rewritten once with the result reused at every occurrence
        /// (without the memo, a 58-node shared graph from a real symbol drove
        /// 720,891 `visit` calls). `visit` must therefore be a pure
        /// transformation of its input — an override that counts occurrences or
        /// varies its result by position was never well-defined on shared trees.
        ///
        /// Walked with an explicit stack. This is public API over a tree of
        /// arbitrary depth, it is not routed through a large-stack worker, and
        /// no engine budget covers it — recursion here took the process down at
        /// around 600 levels on the 512KB stack a `Task` runs on. Making it
        /// iterative changes nothing a subclass can observe: `rewrite` is
        /// `final`, only ``visit(_:)`` is `open`, and the visit order is the
        /// same post-order it always was.
        public final func rewrite(_ node: Node) -> Node {
            var rewrittenNodesBySourceIdentity: [ObjectIdentifier: Node] = [:]
            var frames: [RewriteFrame] = [RewriteFrame(originalNode: node)]
            frames[0].rewrittenChildren.reserveCapacity(node.children.count)
            var completedNode: Node?

            while var frame = frames.popLast() {
                if let rewrittenChild = completedNode {
                    let originalChild = frame.originalNode.children[frame.nextChildIndex - 1]
                    frame.rewrittenChildren.append(rewrittenChild)
                    if rewrittenChild !== originalChild {
                        frame.hasChildrenChanged = true
                    }
                    completedNode = nil
                }

                let originalChildren = frame.originalNode.children
                if frame.nextChildIndex < originalChildren.count {
                    let nextChild = originalChildren[frame.nextChildIndex]
                    frame.nextChildIndex += 1
                    frames.append(frame)
                    if let alreadyRewrittenChild = rewrittenNodesBySourceIdentity[ObjectIdentifier(nextChild)] {
                        completedNode = alreadyRewrittenChild
                    } else {
                        var childFrame = RewriteFrame(originalNode: nextChild)
                        childFrame.rewrittenChildren.reserveCapacity(nextChild.children.count)
                        frames.append(childFrame)
                    }
                    continue
                }

                let nodeToVisit: Node
                if frame.hasChildrenChanged {
                    nodeToVisit = Node(
                        kind: frame.originalNode.kind,
                        contents: frame.originalNode.contents,
                        children: frame.rewrittenChildren
                    )
                } else {
                    nodeToVisit = frame.originalNode
                }
                let visitedNode = visit(nodeToVisit)
                rewrittenNodesBySourceIdentity[ObjectIdentifier(frame.originalNode)] = visitedNode
                completedNode = visitedNode
            }

            // The loop only ends once the root frame has been visited.
            return completedNode ?? node
        }

        open func visit(_ node: Node) -> Node {
            return node
        }
    }
}
