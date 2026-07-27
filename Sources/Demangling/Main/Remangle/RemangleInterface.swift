// Public interface functions for remangling Swift symbols
//
// These convenience functions provide a simple API for remangling demangled nodes
// back into mangled symbol strings.

/// Remangle a node tree with custom options
///
/// - Parameters:
///   - node: The root node of the demangled tree
///   - usePunycode: Whether to use Punycode encoding for non-ASCII identifiers
///   - flavor: The mangling flavor (default Swift, or embedded Swift)
/// - Returns: The mangled string, or nil if remangling failed
public func mangleAsString(_ node: Node, usePunycode: Bool = true, flavor: ManglingFlavor = .default) throws(ManglingError) -> String {
    let mangleBlock: @Sendable () throws(ManglingError) -> String = {
        var remangler = Remangler(usePunycode: usePunycode, flavor: flavor)
        return try remangler.mangle(node)
    }
    return try StackSafeExecutor.execute(mangleBlock)
}

/// Asynchronous variant of ``mangleAsString(_:usePunycode:flavor:)``.
///
/// Always runs on a dedicated 8MB-stack `Thread` and suspends the calling task
/// via a continuation, so Swift Concurrency cooperative workers are not blocked
/// while remangling deeply nested types. Prefer this overload in high-throughput
/// async pipelines.
public func mangleAsString(_ node: Node, usePunycode: Bool = true, flavor: ManglingFlavor = .default) async throws(ManglingError) -> String {
    let mangleBlock: @Sendable () throws(ManglingError) -> String = {
        var remangler = Remangler(usePunycode: usePunycode, flavor: flavor)
        return try remangler.mangle(node)
    }
    return try await StackSafeExecutor.executeAsync(mangleBlock)
}

// MARK: - Store-Backed Remangling

/// Remangle any `DemanglingNode` representation — in particular a
/// `NodeReference` pointing into a `NodeStore`.
///
/// The remangling algorithm constructs transient helper nodes while walking
/// (unspecialized nominals, SIL box layout wrappers), exactly like the C++
/// `Remangler` does with its `NodeFactory` — it is not a read-only consumer,
/// so it runs on the class representation. This entry bridges by
/// materializing the subtree once (subtree sharing preserved); the cost is
/// transient and proportional to the subtree, and remangling's output is a
/// fresh `String` either way, so the store's resident-memory goals are
/// unaffected.
public func mangleAsString(_ node: some DemanglingNode, usePunycode: Bool = true, flavor: ManglingFlavor = .default) throws(ManglingError) -> String {
    try mangleAsString(node.materializedNode, usePunycode: usePunycode, flavor: flavor)
}

/// Asynchronous variant of the `DemanglingNode` overload.
public func mangleAsString(_ node: some DemanglingNode, usePunycode: Bool = true, flavor: ManglingFlavor = .default) async throws(ManglingError) -> String {
    try await mangleAsString(node.materializedNode, usePunycode: usePunycode, flavor: flavor)
}

// MARK: - Validation Helpers

/// Check if a node tree can be successfully remangled
///
/// - Parameter node: The node to check
/// - Returns: True if the node can be remangled
public func canMangle(_ node: Node) -> Bool {
    return (try? mangleAsString(node)) != nil
}

/// Check if any `DemanglingNode` representation can be successfully remangled.
public func canMangle(_ node: some DemanglingNode) -> Bool {
    return (try? mangleAsString(node)) != nil
}
