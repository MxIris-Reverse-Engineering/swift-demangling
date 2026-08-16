/// The read-only tree shape shared by `Node` (the class tree) and
/// `NodeReference` (a handle into a `NodeStore`).
///
/// It exists so that traversal-only consumers — first the `NodePrinter`
/// engine — can walk either representation without materializing a class
/// tree. The member names deliberately match `Node`'s existing API so that
/// the generic engine's body is identical whether specialized on `Node` or
/// `NodeReference`. See evolution proposal 0001, Phase 2.
public protocol DemanglingNode: Sendable {
    associatedtype Children: DemanglingNodeChildren where Children.Element == Self

    /// A per-tree-node identity used to memoize shared subtrees while printing.
    /// For `Node` this is `ObjectIdentifier`; for `NodeReference` it is the
    /// reference itself, which hashes as store identity plus index — the store
    /// half matters, because every store numbers its nodes from zero. It must
    /// be equal exactly when two handles denote the same shared node.
    associatedtype PrintCacheIdentity: Hashable & Sendable

    var kind: Node.Kind { get }
    var text: String? { get }
    var index: UInt64? { get }
    var hasIndex: Bool { get }
    var children: Children { get }
    var printCacheIdentity: PrintCacheIdentity { get }

    /// The concrete class-tree form of this subtree, for interop boundaries
    /// that still require `Node` (`TypeBuilder` handoffs, remangling until the
    /// `Remangler` is genericized). `Node` returns itself; `NodeReference`
    /// materializes with subtree sharing preserved.
    ///
    /// - Important: the result is canonical only on the `Node` path.
    ///   `NodeReference` builds a fresh, non-interned tree on every access, so
    ///   two reads of the *same* store index are equal but not `===`. Anything
    ///   downstream that memoizes what it receives — a `TypeBuilder` caching
    ///   declarations, a rich `NodePrinterTarget` grouping scopes — must key on
    ///   structure, never on `ObjectIdentifier` or `===`, or it will treat one
    ///   declaration as many.
    var materializedNode: Node { get }

    /// Runs a print walk over this subtree and returns the rendered text.
    ///
    /// A **requirement**, not an extension member, and that distinction is the
    /// whole point. `print(using:)` below is the API callers use; it forwards
    /// here, so the call lands in the witness table and every conformer's own
    /// walk is selected — including from generic and existential contexts.
    ///
    /// `NodeReference` overrides this to walk the arena on unretained handles
    /// (zero store retain/release per visited child). That override used to be
    /// written directly on `print(using:)`, which is an extension member: a
    /// concrete `NodeReference` picked up the fast walk, while
    /// `some DemanglingNode` / `any DemanglingNode` silently kept the generic
    /// one. Output was identical either way, so no comparison test could see
    /// it — the same near-miss shape `NodePrinterTarget` documents for its own
    /// hooks (ReviewFindingsPR7 F14 addendum).
    ///
    /// Note the split: the requirement takes no default argument (Swift does
    /// not allow them on requirements), so the defaulted spelling lives on
    /// `print(using:)` alone. Putting a default here and overriding *that* is
    /// exactly how the dispatch hole reopens.
    func runPrintWalk(using options: DemangleOptions) -> String

    /// Asynchronous counterpart of ``runPrintWalk(using:)``; see its note on
    /// why this is a requirement.
    func runPrintWalk(using options: DemangleOptions) async -> String

    /// Requirements (with derived defaults) so representations can provide
    /// allocation-free fast paths — `NodeReference` witnesses these with
    /// byte comparisons against the store's string table instead of
    /// constructing a `String` per check.
    func isIdentifier(desired: String) -> Bool
    var isSwiftModule: Bool { get }

    /// Whether this node has any children.
    ///
    /// A **requirement** with a derived default below, for the same reason
    /// ``runPrintWalk(using:)`` is one. `Node` overrides it to answer from the
    /// payload tag, because its `children` getter rebuilds a `Children` value
    /// and retains every child — but written as an extension member the
    /// override never dispatched: every call site in `Sources/` is inside
    /// `TypeDecoderEngine<Builder, SomeNode>`, where the receiver is
    /// statically `SomeNode`, so the generic spelling bound `!children.isEmpty`
    /// and the override was dead code. Both spellings return the same answer,
    /// so no value-comparison test could see it.
    ///
    /// This is the third appearance of that shape on this protocol
    /// (`print(using:)` → `runPrintWalk` in `db3c604`, then `hasChildren` in
    /// `badb778` three days later). **An extension member is never a valid
    /// place for a per-conformer performance override** — if a conformer needs
    /// to answer a question differently, the question has to be a requirement.
    var hasChildren: Bool { get }
}

// MARK: - Derived helpers shared by the printer

/// The convenience properties the printer engine derives from the protocol
/// primitives. These are the single implementation for both `Node` and
/// `NodeReference`: they are extension members (not requirements), so the
/// generic engine statically dispatches here for every conformer — keeping a
/// parallel copy on a concrete type would silently drift.
extension DemanglingNode {
    /// Prints this subtree with the given options.
    ///
    /// The single implementation for every representation: `Node` prints the
    /// class tree, `NodeReference` prints straight from the store without
    /// materializing a `Node` tree.
    /// Forwards through the ``runPrintWalk(using:)`` requirement so the
    /// conformer's own walk is selected even from a generic or existential
    /// context — see that requirement for why the override cannot live here.
    public func print(using options: DemangleOptions = .default) -> String {
        runPrintWalk(using: options)
    }

    /// Asynchronous variant of ``print(using:)``.
    ///
    /// Suspends the calling task instead of blocking a cooperative worker when
    /// the walk has to move to a large-stack thread.
    public func print(using options: DemangleOptions = .default) async -> String {
        await runPrintWalk(using: options)
    }

    /// Default walk: the generic engine specialized on this representation.
    /// `Node` uses it as-is; `NodeReference` overrides it.
    public func runPrintWalk(using options: DemangleOptions) -> String {
        DemanglingPrinter<String, Self>.print(self, options: options)
    }

    public func runPrintWalk(using options: DemangleOptions) async -> String {
        await StackSafeExecutor.executeAsync {
            var printer = DemanglingPrinter<String, Self>(options: options)
            return printer.printRoot(self)
        }
    }

    @inlinable
    public var hasChildren: Bool {
        !children.isEmpty
    }

    @inlinable
    public subscript(throwChild childIndex: Int) -> Self {
        get throws(Node.IndexOutOfBoundError) {
            if let child = children.at(childIndex) {
                return child
            } else {
                throw .default
            }
        }
    }

    @inlinable
    public func isKind(of kinds: Node.Kind...) -> Bool {
        kinds.contains(kind)
    }

    @inlinable
    public func isIdentifier(desired: String) -> Bool {
        kind == .identifier && text == desired
    }

    @inlinable
    public var isSwiftModule: Bool {
        kind == .module && text == stdlibName
    }

    /// Ceiling on `.type`-wrapper unwrapping. They nest only once or twice in
    /// anything the demangler builds; the bound exists because `NodeBuilder`
    /// can hand these walks a node that is its own descendant, and an
    /// unbounded loop on a cycle spins forever — silently, which is harder to
    /// diagnose than any crash.
    @usableFromInline
    static var maxTypeWrapperUnwrapDepth: Int { 64 }

    /// Whether this type prints without needing parentheses around it.
    ///
    /// `.type` wrappers are unwrapped with a bounded loop rather than by
    /// recursing: this is public API reachable from a caller-assembled tree,
    /// and it sits outside every engine's stack guard.
    public var isSimpleType: Bool {
        var currentNode = self
        var unwrapDepth = 0
        while currentNode.kind == .type {
            unwrapDepth += 1
            guard unwrapDepth <= Self.maxTypeWrapperUnwrapDepth,
                  let onlyChild = currentNode.children.first
            else { return false }
            currentNode = onlyChild
        }
        return currentNode.isSimpleTypeIgnoringTypeWrappers
    }

    private var isSimpleTypeIgnoringTypeWrappers: Bool {
        switch kind {
        case .associatedType,
             .associatedTypeRef,
             .boundGenericClass,
             .boundGenericEnum,
             .boundGenericFunction,
             .boundGenericOtherNominalType,
             .boundGenericProtocol,
             .boundGenericStructure,
             .boundGenericTypeAlias,
             .builtinBorrow,
             .builtinTypeName,
             .builtinTupleType,
             .builtinFixedArray,
             .class,
             .dependentGenericType,
             .dependentMemberType,
             .dependentGenericParamType,
             .dynamicSelf,
             .enum,
             .errorType,
             .existentialMetatype,
             .integer,
             .labelList,
             .metatype,
             .metatypeRepresentation,
             .module,
             .negativeInteger,
             .otherNominalType,
             .pack,
             .protocol,
             .protocolSymbolicReference,
             .returnType,
             .silBoxType,
             .silBoxTypeWithLayout,
             .structure,
             .sugaredArray,
             .sugaredDictionary,
             .sugaredOptional,
             .sugaredInlineArray,
             .sugaredParen,
             .tuple,
             .tupleElementName,
             .typeAlias,
             .typeList,
             .typeSymbolicReference:
            return true
        case .protocolList:
            return children.first.map { $0.children.count <= 1 } ?? false
        case .protocolListWithAnyObject:
            return (children.first?.children.first).map { $0.children.count == 0 } ?? false
        default:
            return false
        }
    }

    /// Whether a space belongs between a preceding keyword and this type.
    ///
    /// Unwraps `.type` with a bounded loop, for the same reason as
    /// ``isSimpleType``.
    public var needSpaceBeforeType: Bool {
        var currentNode = self
        var unwrapDepth = 0
        while currentNode.kind == .type {
            unwrapDepth += 1
            guard unwrapDepth <= Self.maxTypeWrapperUnwrapDepth,
                  let onlyChild = currentNode.children.first
            else { return false }
            currentNode = onlyChild
        }
        return currentNode.needSpaceBeforeTypeIgnoringTypeWrappers
    }

    private var needSpaceBeforeTypeIgnoringTypeWrappers: Bool {
        switch kind {
        case .functionType,
             .noEscapeFunctionType,
             .uncurriedFunctionType,
             .dependentGenericType:
            return false
        default:
            return true
        }
    }
}

/// A node's children as a random-access collection, extended with the
/// safe-indexing helpers the printer relies on (`at`, `slice`).
public protocol DemanglingNodeChildren: RandomAccessCollection where Index == Int {
    func at(_ index: Int) -> Element?
    func slice(_ from: Int, _ to: Int) -> ArraySlice<Element>
}

extension DemanglingNodeChildren {
    @inlinable
    public func at(_ index: Int) -> Element? {
        (index >= startIndex && index < endIndex) ? self[index] : nil
    }

    @inlinable
    public var second: Element? {
        at(1)
    }

    @inlinable
    public func slice(_ from: Int, _ to: Int) -> ArraySlice<Element> {
        let elements = Array(self)
        if from > to || from > elements.endIndex || to < elements.startIndex {
            return ArraySlice()
        }
        let lowerBound = Swift.max(from, elements.startIndex)
        let upperBound = Swift.min(to, elements.endIndex)
        return elements[lowerBound ..< upperBound]
    }
}

// MARK: - Node conformance

extension Node: DemanglingNode {
    @inlinable
    public var printCacheIdentity: ObjectIdentifier { ObjectIdentifier(self) }

    @inlinable
    public var materializedNode: Node { self }
}

extension Node.Children: DemanglingNodeChildren {}

// MARK: - NodeReference conformance

extension NodeReference: DemanglingNode {
    @inlinable
    public var hasIndex: Bool {
        if case .index = compactNode.payloadKind { return true }
        return false
    }

    /// The whole reference, not just the index: an index is only meaningful
    /// relative to its store, and every store numbers from zero. `NodeReference`
    /// already hashes as store identity plus index, which is exactly the
    /// identity a cache key needs.
    @inlinable
    public var printCacheIdentity: NodeReference { self }

    /// Freshly constructed on every access — see ``materialize()`` for the
    /// identity caveat this brings to identity-keyed consumers (printer scope
    /// hooks and `NodePrintContext` deliver nodes through this property on
    /// the store path).
    @inlinable
    public var materializedNode: Node { materialize() }
}

extension NodeReference.ChildrenView: DemanglingNodeChildren {}

// MARK: - Store-path printing without per-child ARC (proposal 0008, B2)

extension NodeReference {
    /// Shadows the generic ``DemanglingNode`` `print(using:)` for the store
    /// path: the walk runs on `UnretainedNodeReference` handles — zero store
    /// retain/release per visited child — over one view descriptor pinned at
    /// entry (proposal 0010, step 3), inside a scope that anchors the store
    /// strongly for the walk's whole duration. Output and fragment-cache
    /// behavior are identical to the generic path (the cache keys on
    /// per-store node identity either way); only the ARC traffic differs.
    ///
    /// The pinned view stays valid across the `StackSafeExecutor` hop inside
    /// the printer: the submitting frame blocks on the hop, so the
    /// `withUnsafePointer` scope outlives the whole walk.
    public func runPrintWalk(using options: DemangleOptions) -> String {
        withExtendedLifetime(store) {
            store.withView { pinnedView in
                withUnsafePointer(to: pinnedView) { viewPointer in
                    DemanglingPrinter<String, UnretainedNodeReference>.print(
                        UnretainedNodeReference(viewPointer: viewPointer, rawIndex: nodeIndex.rawValue),
                        options: options
                    )
                }
            }
        }
    }

    /// Asynchronous variant of ``print(using:)``; the closure's strong `self`
    /// capture anchors the store across the executor hop, and the view is
    /// pinned on the thread that runs the walk.
    ///
    /// The `withExtendedLifetime(store)` matches the synchronous variant's:
    /// `UnretainedNodeReference`'s contract makes the calling scope
    /// responsible for keeping the store — and through it every buffer
    /// generation, retired ones included — strongly alive for the whole
    /// walk, and that responsibility should not rest on the optimizer
    /// choosing to keep the closure's implicit `self` capture live to the
    /// end (ReviewFindingsPR7 F15).
    public func runPrintWalk(using options: DemangleOptions) async -> String {
        await StackSafeExecutor.executeAsync {
            withExtendedLifetime(store) {
                store.withView { pinnedView in
                    withUnsafePointer(to: pinnedView) { viewPointer in
                        // `printer` is declared *inside* this scope, matching
                        // the synchronous override above. Its `printCache` is
                        // keyed by `UnretainedNodeReference`, whose stored
                        // `viewPointer` addresses `pinnedView` — a local of
                        // the `withView` closure. Bound outside, the printer
                        // outlived the stack slot its keys point at. Benign
                        // only because those keys are POD and dictionary
                        // teardown never dereferences them; any later rehash,
                        // debug description, or reuse would read freed stack,
                        // and `UnretainedNodeReference`'s own contract says
                        // not to hold one beyond the anchoring scope.
                        var printer = DemanglingPrinter<String, UnretainedNodeReference>(options: options)
                        return printer.printRoot(UnretainedNodeReference(viewPointer: viewPointer, rawIndex: nodeIndex.rawValue))
                    }
                }
            }
        }
    }
}
