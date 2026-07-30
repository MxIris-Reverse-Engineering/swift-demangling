extension Node: CustomStringConvertible {
    /// Overridden method to allow simple printing with default options
    ///
    /// Runs inline on the calling thread: the dump below walks with an
    /// explicit stack, so it cannot overflow at any depth — and this property
    /// is what a debugger's `po` evaluates, where a thread hop would hang the
    /// expression.
    public var description: String {
        var string = ""
        appendDebugDescription(to: &string)
        if !string.isEmpty {
            string.removeLast() // Remove the last newline
        }
        return string
    }

    /// Prints `SwiftSymbol`s to a String with the full set of printing options.
    ///
    /// - Parameter options: an option set containing the different `DemangleOptions` from the Swift project.
    /// - Returns: `self` printed to a string according to the specified options.
    public func print(using options: DemangleOptions = .default) -> String {
        NodePrinter<String>.print(self, using: options)
    }

    /// Asynchronous variant of ``print(using:)``.
    ///
    /// Suspends the calling task instead of blocking a cooperative worker when
    /// the walk has to move to a large-stack thread.
    public func print(using options: DemangleOptions = .default) async -> String {
        await StackSafeExecutor.executeAsync {
            var printer = DemanglingPrinter<String, Node>(options: options)
            return printer.printRoot(self)
        }
    }

    /// Depth-first preorder dump, one line per node, indented by depth.
    ///
    /// Walked with an explicit stack: `description` is reachable from a
    /// debugger, a log statement or an assertion message on any tree from any
    /// thread, which is the one place a per-level frame is least affordable.
    ///
    /// Shared interior subtrees are expanded once and labeled: interning and
    /// substitution back-references make demangled trees DAGs, and re-expanding
    /// a subtree at every occurrence multiplies along nesting — a real 120
    /// character symbol with 64 unique nodes dumped as a 366MB string. The
    /// first occurrence of a multiply-referenced interior node is tagged
    /// `(shared #N)` and expanded; later occurrences print `(see #N)` and
    /// stop, so the dump costs the graph's size, not its path count. Leaves
    /// are always printed in place — one line either way, and eliding, say,
    /// every repeated `Swift` module node would only hurt readability.
    private func appendDebugDescription(to output: inout String) {
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
