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
/// Error positions carried by thrown ``DemanglingError`` values are byte offsets
/// into the mangled input (proposal 0008). Mangled symbols are ASCII, so for any
/// valid input these equal the scalar counts reported before; they can differ only
/// for invalid inputs containing non-ASCII bytes.
///
/// The byte move changed more than error positions: identifier **length
/// prefixes** now count bytes rather than Unicode scalars, so on an input whose
/// identifier contains non-ASCII bytes the demangler slices a different span and
/// can reach a different parse outcome — not merely a different error offset.
/// Valid Swift symbols are unaffected (they are ASCII, and non-ASCII identifiers
/// arrive punycode-encoded, which is also ASCII); this is only observable on
/// malformed input.
///
/// Measured against `swift-demangle` as referee on 1068 non-ASCII inputs built to
/// stress that boundary: the byte reading is right 194 times and the scalar
/// reading 41, the rest agreeing. The 41 are one shape — this entry *accepting* a
/// punycode-marked identifier the Swift toolchain rejects — so the byte reading is
/// the better default, not a strictly better one. Recorded rather than papered
/// over, because "we match upstream here" would be the wrong thing to believe
/// while debugging one of those 41 (ReviewFindingsPR7, second round).
///
/// - Parameters:
///   - mangled: the string to be parsed ("isType` is false, the string should start with a Swift Symbol prefix, _T, _$S or $S).
///   - isType: if true, no prefix is parsed and, on completion, the first item on the parse stack is returned.
///   - internsSubtrees: if true, the resulting tree is canonicalized through `NodeCache.shared` so equal subtrees are shared.
/// - Returns: the successfully parsed result
/// - Throws: a SwiftSymbolParseError error that contains parse position when the error occurred.
public func demangleAsNode(_ mangled: String, isType: Bool = false, symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil, internsSubtrees: Bool = true) throws(DemanglingError) -> Node {
    let demangleBlock: @Sendable () throws(DemanglingError) -> Node = {
        try demangleAsNodeFromMangledText(mangled, isType: isType, symbolicReferenceResolver: symbolicReferenceResolver, internsSubtrees: internsSubtrees)
    }
    return try StackSafeExecutor.execute(demangleBlock)
}

/// Asynchronous variant of ``demangleAsNode(_:isType:symbolicReferenceResolver:internsSubtrees:)``.
///
/// Suspends the calling task instead of blocking a cooperative worker when
/// the walk has to move to a large-stack thread; with enough stack on the
/// calling thread it runs inline. Prefer this overload in high-throughput
/// async pipelines.
public func demangleAsNode(_ mangled: String, isType: Bool = false, symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil, internsSubtrees: Bool = true) async throws(DemanglingError) -> Node {
    let demangleBlock: @Sendable () throws(DemanglingError) -> Node = {
        try demangleAsNodeFromMangledText(mangled, isType: isType, symbolicReferenceResolver: symbolicReferenceResolver, internsSubtrees: internsSubtrees)
    }
    return try await StackSafeExecutor.executeAsync(demangleBlock)
}

/// Fully cache-free demangle for transient trees: neither leaves nor subtrees
/// are interned into `NodeCache.shared`, so nothing the call builds is
/// retained anywhere once the returned tree is released.
///
/// This is the entry to choose for **demangle-and-discard** work — demangle,
/// extract a string or a classification, drop the tree. That shape is the
/// norm in reverse-engineering tooling (bulk indexing through
/// `NodeStoreBuilder`, resolving a display name, deriving a lookup key), and
/// routing it through the cached ``demangleAsNode(_:isType:symbolicReferenceResolver:internsSubtrees:)``
/// pins every result in the never-evicting global `NodeCache` for the process
/// lifetime. Choose `demangleAsNode` only when the returned tree itself is
/// kept and canonical instances (`===` across symbols) are wanted.
///
/// Contracts:
///
/// - **The returned tree is NOT canonical, but neither is it
///   instance-distinct**: parameterless kinds (`.asyncAnnotation`,
///   `.throwsAnnotation`, `.labelList`, ...) resolve to the process-wide
///   `NodeFactory` singletons shared by every tree ever demangled, and the
///   demangler's substitution back-references reuse one instance for repeated
///   occurrences within the tree. So neither direction of an identity
///   assumption holds: structurally equal nodes are not guaranteed distinct,
///   and `NodeCache`'s structurally-equal-implies-identical guarantee does
///   not apply either. Per-occurrence logic (deduplication, counting, parent
///   maps) must not key by `ObjectIdentifier`/`===` — use structural keys.
/// - **Remangling is byte-identical to the canonical path**: for any symbol,
///   `mangleAsString` over this function's tree equals `mangleAsString` over
///   `demangleAsNode`'s tree — the remangler matches substitutions
///   structurally, never by instance identity. Deriving lookup keys by
///   remangling a transient tree is therefore sound
///   (`TransientRemangleParityTests` pins this equivalence).
public func demangleAsNodeTransient(_ mangled: String, isType: Bool = false, symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil) throws(DemanglingError) -> Node {
    let demangleBlock: @Sendable () throws(DemanglingError) -> Node = {
        try demangleAsNodeFromMangledText(mangled, isType: isType, symbolicReferenceResolver: symbolicReferenceResolver, internsSubtrees: false, internsLeaves: false)
    }
    return try StackSafeExecutor.execute(demangleBlock)
}

/// The axis-1 entry point (proposal 0008): fixes input borrowing, text
/// materialization, and word-table storage once, then runs the shared
/// byte-based demangling core inside the borrow scope.
///
/// - Modern runtimes (`#available` macOS 26 family): `String.utf8Span`
///   borrows the input without copying or a closure; known-ASCII inputs
///   (`UTF8Span.isKnownASCII`, O(1)) additionally take revalidation-free text
///   materialization. Non-ASCII inputs keep validating materialization — a
///   byte subrange of non-ASCII UTF-8 can split a scalar, so `unchecked`
///   materialization would be unsound there (see
///   `TextMaterializationStrategy`).
/// - Legacy runtimes, or when ``DemanglingRuntimePath/forcesLegacyPath`` is
///   set (the dual-path testability seam): `withUTF8` borrows inside a
///   closure (possibly copying a bridged string once), validating
///   materialization, heap-backed word table.
private func demangleAsNodeFromMangledText(_ mangled: String, isType: Bool, symbolicReferenceResolver: DemangleSymbolicReferenceResolver?, internsSubtrees: Bool, internsLeaves: Bool = true) throws(DemanglingError) -> Node {
    if !DemanglingRuntimePath.forcesLegacyPath,
       #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
        let utf8 = mangled.utf8Span
        let materialization: TextMaterializationStrategy = utf8.isKnownASCII ? .prevalidatedCopying : .decoding
        return try runDemangler(
            bytes: utf8.span,
            wordRangeStorageType: InlineWordRanges.self,
            materialization: materialization,
            mangled: mangled,
            isType: isType,
            symbolicReferenceResolver: symbolicReferenceResolver,
            internsSubtrees: internsSubtrees,
            internsLeaves: internsLeaves
        )
    } else {
        return try demangleAsNodeOnLegacyRuntimePath(
            mangled,
            isType: isType,
            symbolicReferenceResolver: symbolicReferenceResolver,
            internsSubtrees: internsSubtrees,
            internsLeaves: internsLeaves
        )
    }
}

/// The legacy (pre-macOS 26) runtime leg: `withUTF8` input borrowing,
/// validating text materialization, heap-backed word table.
///
/// Internal — not merely an implementation detail of the seam branch above —
/// so tests can drive this leg *directly* (`DualPathParityTests`). The
/// alternative, flipping ``DemanglingRuntimePath/forcesLegacyPath`` mid-run,
/// mutates process-wide state: `.serialized` only orders tests within one
/// suite, so a flipped seam silently dragged every concurrently running
/// suite onto the legacy path and non-deterministically un-covered the
/// modern one (ReviewFindingsPR7 F12). A task-local seam was considered and
/// rejected: the seam is read inside the `StackSafeExecutor` closure, which
/// may run on a pooled pthread where task-locals do not propagate.
func demangleAsNodeOnLegacyRuntimePath(_ mangled: String, isType: Bool, symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil, internsSubtrees: Bool, internsLeaves: Bool = true) throws(DemanglingError) -> Node {
    var utf8Copy = mangled
    let outcome = utf8Copy.withUTF8 { buffer in
        Result { () throws(DemanglingError) -> Node in
            try runDemangler(
                bytes: buffer.span,
                wordRangeStorageType: ArrayWordRanges.self,
                materialization: .decoding,
                mangled: mangled,
                isType: isType,
                symbolicReferenceResolver: symbolicReferenceResolver,
                internsSubtrees: internsSubtrees,
                internsLeaves: internsLeaves
            )
        }
    }
    return try outcome.get()
}

/// The shared demangling core, generic over the word-table storage. `mangled`
/// rides along only for the prefix-shape decision (Swift 4+ vs the extinct
/// Swift 3 `_T` grammar), which predates the byte borrow.
private func runDemangler<Words: WordRangeStorage>(
    bytes: Span<UInt8>,
    wordRangeStorageType: Words.Type,
    materialization: TextMaterializationStrategy,
    mangled: String,
    isType: Bool,
    symbolicReferenceResolver: DemangleSymbolicReferenceResolver?,
    internsSubtrees: Bool,
    internsLeaves: Bool
) throws(DemanglingError) -> Node {
    var demangler = Demangler<Words>(bytes: bytes, materialization: materialization, internsLeaves: internsLeaves)
    demangler.symbolicReferenceResolver = symbolicReferenceResolver
    let demangledNode: Node
    if isType {
        demangledNode = try demangler.demangleType()
    } else if getManglingPrefixLength(mangled) != 0 {
        demangledNode = try demangler.demangleSymbol()
    } else {
        demangledNode = try demangler.demangleSwift3TopLevelSymbol()
    }
    guard internsSubtrees else {
        return demangledNode
    }
    return NodeCache.shared.intern(demangledNode)
}
