/// This is likely to be the primary entry point to this file. Pass a string containing a Swift mangled symbol or type, get a parsed SwiftSymbol structure which can then be directly examined or printed.
///
/// Leaf nodes are automatically interned via `NodeCache.shared` during demangling,
/// deduplicating common nodes like `.module("Swift")` and `.identifier("Int")`.
/// When `internsSubtrees` is true (the default), the finished tree additionally goes
/// through a bottom-up subtree interning (hash-consing) pass, so structurally equal
/// subtrees across all demangled symbols share a single `Node` instance. This
/// reduces memory by roughly 4x when demangling a whole binary. Interned nodes are
/// retained by `NodeCache.shared` until `NodeCache.shared.clear()` is called; pass
/// `internsSubtrees: false` for one-off demangling that should not grow the cache.
///
/// - Parameters:
///   - mangled: the string to be parsed ("isType` is false, the string should start with a Swift Symbol prefix, _T, _$S or $S).
///   - isType: if true, no prefix is parsed and, on completion, the first item on the parse stack is returned.
///   - internsSubtrees: if true, the resulting tree is canonicalized through `NodeCache.shared` so equal subtrees are shared.
/// - Returns: the successfully parsed result
/// - Throws: a SwiftSymbolParseError error that contains parse position when the error occurred.
public func demangleAsNode(_ mangled: String, isType: Bool = false, symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil, internsSubtrees: Bool = true) throws(DemanglingError) -> Node {
    let demangleBlock: @Sendable () throws(DemanglingError) -> Node = {
        try demangleAsNode(mangled.unicodeScalars, isType: isType, symbolicReferenceResolver: symbolicReferenceResolver, internsSubtrees: internsSubtrees)
    }
    return try StackSafeExecutor.execute(demangleBlock)
}

/// Asynchronous variant of ``demangleAsNode(_:isType:symbolicReferenceResolver:)``.
///
/// Always runs on a dedicated 8MB-stack `Thread` and suspends the calling task
/// via a continuation, so Swift Concurrency cooperative workers are not blocked
/// while demangling deeply nested types. Prefer this overload in high-throughput
/// async pipelines.
public func demangleAsNode(_ mangled: String, isType: Bool = false, symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil, internsSubtrees: Bool = true) async throws(DemanglingError) -> Node {
    let demangleBlock: @Sendable () throws(DemanglingError) -> Node = {
        try demangleAsNode(mangled.unicodeScalars, isType: isType, symbolicReferenceResolver: symbolicReferenceResolver, internsSubtrees: internsSubtrees)
    }
    return try await StackSafeExecutor.executeAsync(demangleBlock)
}

/// Pass a collection of `UnicodeScalars` containing a Swift mangled symbol or type, get a parsed SwiftSymbol structure which can then be directly examined or printed.
///
/// - Parameters:
///   - mangled: the collection of `UnicodeScalars` to be parsed ("isType` is false, the string should start with a Swift Symbol prefix, _T, _$S or $S).
///   - isType: if true, no prefix is parsed and, on completion, the first item on the parse stack is returned.
/// - Returns: the successfully parsed result
/// - Throws: a SwiftSymbolParseError error that contains parse position when the error occurred.
private func demangleAsNode<C: Collection & Sendable>(_ mangled: C, isType: Bool = false, symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil, internsSubtrees: Bool = true, internsLeaves: Bool = true) throws(DemanglingError) -> Node where C.Iterator.Element == UnicodeScalar, C.Index: Sendable {
    var demangler = Demangler(scalars: mangled, internsLeaves: internsLeaves)
    demangler.symbolicReferenceResolver = symbolicReferenceResolver
    let demangledNode: Node
    if isType {
        demangledNode = try demangler.demangleType()
    } else if Demangler.getManglingPrefixLength(mangled) != 0 {
        demangledNode = try demangler.demangleSymbol()
    } else {
        demangledNode = try demangler.demangleSwift3TopLevelSymbol()
    }
    guard internsSubtrees else {
        return demangledNode
    }
    return NodeCache.shared.intern(demangledNode)
}

/// Fully cache-free demangle for transient trees (proposal 0001, Phase 3):
/// neither leaves nor subtrees touch `NodeCache.shared`, so bulk demangling
/// through `SymbolStoreBuilder` leaves no trace in global state.
func demangleAsNodeTransient(_ mangled: String, isType: Bool = false) throws(DemanglingError) -> Node {
    let demangleBlock: @Sendable () throws(DemanglingError) -> Node = {
        try demangleAsNode(mangled.unicodeScalars, isType: isType, internsSubtrees: false, internsLeaves: false)
    }
    return try StackSafeExecutor.execute(demangleBlock)
}
