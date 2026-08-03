extension Node: CustomStringConvertible {
    /// Upper bound on the bytes ``description`` emits before it stops and marks
    /// the dump truncated.
    ///
    /// Interning and substitution back-references make demangled trees DAGs, so
    /// expanding every occurrence costs the graph's path count rather than its
    /// node count: a 120 character symbol with 64 unique nodes expands to a
    /// 366MB string. This bound keeps such a tree from exhausting memory in a
    /// debugger or a log statement, without altering the format of anything
    /// below it. Measured across the full dyld shared cache corpus (4,522,325
    /// symbols) the largest expanded dump is 496,018 bytes — no real symbol
    /// comes within 16x of the limit, so nothing in practice is truncated.
    private static var maximumDescriptionByteCount: Int { 8 * 1024 * 1024 }

    /// Overridden method to allow simple printing with default options
    ///
    /// Runs inline on the calling thread: the dump below walks with an
    /// explicit stack, so it cannot overflow at any depth — and this property
    /// is what a debugger's `po` evaluates, where a thread hop would hang the
    /// expression.
    ///
    /// Every occurrence of a shared subtree is expanded, which is what the
    /// Swift runtime's own node dump does and what the corpus conformance
    /// oracle compares against byte for byte. Pathological DAGs are bounded by
    /// ``maximumDescriptionByteCount`` rather than by changing the format; for
    /// a dump priced by the graph's size instead of its path count, use
    /// ``sharedStructureDescription``.
    public var description: String {
        var string = ""
        appendExpandedDescription(to: &string)
        if !string.isEmpty {
            string.removeLast() // Remove the last newline
        }
        return string
    }

    /// Debug tree dump that expands each multiply-referenced interior subtree
    /// once, labeling the first occurrence `(shared #N)` and printing
    /// `(see #N)` at later ones.
    ///
    /// Costs the graph's size rather than its path count, so it stays readable
    /// and bounded on trees where ``description`` would be dominated by
    /// repetition. The two differ only in how sharing is rendered — the node
    /// lines themselves are identical — so this is the view to reach for when
    /// the question is which subtrees are shared, not what the tree contains.
    @_spi(Internals)
    public var sharedStructureDescription: String {
        var string = ""
        appendSharedStructureDescription(to: &string)
        if !string.isEmpty {
            string.removeLast() // Remove the last newline
        }
        return string
    }

    /// Depth-first preorder dump, one line per node, indented by depth, with
    /// every occurrence of a shared subtree expanded in place.
    ///
    /// Walked with an explicit stack: `description` is reachable from a
    /// debugger, a log statement or an assertion message on any tree from any
    /// thread, which is the one place a per-level frame is least affordable.
    /// The pending stack holds at most one entry per level per branch, so it is
    /// bounded by the tree's shape even where the output is not.
    ///
    /// Output — not the walk — is what a DAG multiplies, so the guard is a byte
    /// budget on the former. Once ``maximumDescriptionByteCount`` is reached
    /// the dump stops and says so, leaving everything already emitted exactly
    /// as it would have been.
    private func appendExpandedDescription(to output: inout String) {
        var emittedByteCount = 0
        var pendingNodes: [(node: Node, depth: Int)] = [(self, 0)]

        while let pending = pendingNodes.popLast() {
            if emittedByteCount >= Self.maximumDescriptionByteCount {
                output.append("... (truncated: dump exceeded \(Self.maximumDescriptionByteCount) bytes)\n")
                break
            }
            // Built per node so its length can be accounted in one step; the
            // fragments are short, so the total cost stays linear in the output.
            var line = String(repeating: " ", count: pending.depth * 2)
            line.append("kind=\(pending.node.kind)")
            switch pending.node.contents {
            case .none:
                break
            case .index(let index):
                line.append(", index=\(index)")
            case .text(let name):
                line.append(", text=\"\(name)\"")
            }
            line.append("\n")
            emittedByteCount += line.utf8.count
            output.append(line)
            // Reversed so the stack pops them back into source order.
            for child in pending.node.children.reversed() {
                pendingNodes.append((child, pending.depth + 1))
            }
        }
    }

    /// Depth-first preorder dump that expands each multiply-referenced interior
    /// subtree once, labeling it `(shared #N)` and printing `(see #N)` at later
    /// occurrences, so the dump costs the graph's size and not its path count.
    ///
    /// Leaves are always printed in place — one line either way, and eliding,
    /// say, every repeated `Swift` module node would only hurt readability.
    /// Iterative for the same reason as ``appendExpandedDescription(to:)``.
    private func appendSharedStructureDescription(to output: inout String) {
        // First pass: count how many parent slots reference each instance,
        // walking each unique node once.
        var referenceCounts: [ObjectIdentifier: Int] = [:]
        var countedNodes: Set<ObjectIdentifier> = []
        var uncountedNodes: [Node] = [self]
        while let node = uncountedNodes.popLast() {
            guard countedNodes.insert(ObjectIdentifier(node)).inserted else { continue }
            for child in node.children {
                referenceCounts[ObjectIdentifier(child), default: 0] += 1
                uncountedNodes.append(child)
            }
        }

        // Second pass: the dump itself.
        var sharedLabels: [ObjectIdentifier: Int] = [:]
        var nextSharedLabel = 1
        var pendingNodes: [(node: Node, depth: Int)] = [(self, 0)]

        while let pending = pendingNodes.popLast() {
            output.append(String(repeating: " ", count: pending.depth * 2))
            output.append("kind=\(pending.node.kind)")
            switch pending.node.contents {
            case .none:
                break
            case .index(let index):
                output.append(", index=\(index)")
            case .text(let name):
                output.append(", text=\"\(name)\"")
            }
            let identifier = ObjectIdentifier(pending.node)
            if !pending.node.children.isEmpty, referenceCounts[identifier, default: 0] > 1 {
                if let existingLabel = sharedLabels[identifier] {
                    output.append(" (see #\(existingLabel))\n")
                    continue // Already expanded at its first occurrence.
                }
                sharedLabels[identifier] = nextSharedLabel
                output.append(" (shared #\(nextSharedLabel))")
                nextSharedLabel += 1
            }
            output.append("\n")
            // Reversed so the stack pops them back into source order.
            for child in pending.node.children.reversed() {
                pendingNodes.append((child, pending.depth + 1))
            }
        }
    }
}
