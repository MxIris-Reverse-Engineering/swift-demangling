// Public interface functions for remangling Swift symbols
//
// These convenience functions provide a simple API for remangling demangled nodes
// back into mangled symbol strings.

/// Remangle a node tree with custom options
///
/// - Parameters:
///   - node: The root node of the demangled tree
///   - usePunycode: Whether to use Punycode encoding for non-ASCII identifiers
/// - Returns: The mangled string, or nil if remangling failed
public func mangleAsString(_ node: Node, usePunycode: Bool = true) throws(ManglingError) -> String {
    let mangleBlock: @Sendable () throws(ManglingError) -> String = {
        var remangler = Remangler(usePunycode: usePunycode)
        return try remangler.mangle(node)
    }
    return try StackSafeExecutor.execute(mangleBlock)
}

/// Asynchronous variant of ``mangleAsString(_:usePunycode:)``.
///
/// Always runs on a dedicated 8MB-stack `Thread` and suspends the calling task
/// via a continuation, so Swift Concurrency cooperative workers are not blocked
/// while remangling deeply nested types. Prefer this overload in high-throughput
/// async pipelines.
public func mangleAsString(_ node: Node, usePunycode: Bool = true) async throws(ManglingError) -> String {
    let mangleBlock: @Sendable () throws(ManglingError) -> String = {
        var remangler = Remangler(usePunycode: usePunycode)
        return try remangler.mangle(node)
    }
    return try await StackSafeExecutor.executeAsync(mangleBlock)
}

// MARK: - Validation Helpers

/// Check if a node tree can be successfully remangled
///
/// - Parameter node: The node to check
/// - Returns: True if the node can be remangled
public func canMangle(_ node: Node) -> Bool {
    return (try? mangleAsString(node)) != nil
}
