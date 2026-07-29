extension Node: CustomStringConvertible {
    /// Overridden method to allow simple printing with default options
    public var description: String {
        StackSafeExecutor.execute {
            var string = ""
            self.appendDebugDescription(to: &string)
            if !string.isEmpty {
                string.removeLast() // Remove the last newline
            }
            return string
        }
    }

    /// Prints `SwiftSymbol`s to a String with the full set of printing options.
    ///
    /// - Parameter options: an option set containing the different `DemangleOptions` from the Swift project.
    /// - Returns: `self` printed to a string according to the specified options.
    public func print(using options: DemangleOptions = .default) -> String {
        StackSafeExecutor.execute {
            var printer = NodePrinter<String>(options: options)
            return printer.printRoot(self)
        }
    }

    /// Asynchronous variant of ``print(using:)``.
    ///
    /// Always runs on a dedicated 8MB-stack `Thread` and suspends the calling
    /// task via a continuation, so Swift Concurrency cooperative workers are
    /// not blocked while printing deeply nested types.
    public func print(using options: DemangleOptions = .default) async -> String {
        await StackSafeExecutor.executeAsync {
            var printer = NodePrinter<String>(options: options)
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
