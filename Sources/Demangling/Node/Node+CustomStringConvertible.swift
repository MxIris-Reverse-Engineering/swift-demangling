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
    private func appendDebugDescription(to output: inout String) {
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
            output.append("\n")
            // Reversed so the stack pops them back into source order.
            for child in pending.node.children.reversed() {
                pendingNodes.append((child, pending.depth + 1))
            }
        }
    }
}
