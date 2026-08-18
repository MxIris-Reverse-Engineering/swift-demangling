import Foundation
import FoundationToolbox
import SwiftStdlibToolbox

/// Global cache for interning Node instances (full hash-consing).
///
/// Two levels of interning are performed:
/// - **Leaf nodes** (no children), like `.module("Swift")` and `.identifier("Int")`,
///   are interned eagerly at creation time by `Node.create()`.
/// - **Interior nodes** (with children) are interned by the bottom-up tree passes
///   (`intern(_:)` / `internTreeUnsafe(_:)`), collapsing structurally equal subtrees
///   into a single shared instance. Because children are canonicalized before their
///   parent, interior-node lookups compare children by identity (`===`) and never
///   need to hash or compare recursively.
///
/// Measured on ~49k SwiftUI/Foundation/stdlib symbols, subtree interning reduces
/// live Node instances by ~3.8x compared to leaf-only interning.
///
/// Interned nodes must never be mutated: all `Node` mutation methods are
/// `fileprivate` and `NodeBuilder` operates on a private deep copy, so this
/// invariant holds as long as nodes are created through the public API.
///
/// ## Thread Safety
/// Both interning tables live in a single ``Mutex``, so every entry point is
/// synchronized and the type is `Sendable` without an `@unchecked` opt-out.
/// One mutex rather than one per table: interning a tree canonicalizes leaves
/// and interior nodes in the same walk, and that has to be atomic.
///
/// ## Usage
///
/// ```swift
/// // Node.create() automatically interns leaf nodes at creation time
/// let node = Node.create(kind: .module, text: "Swift") // interned (leaf)
/// let tree = Node.create(kind: .type, children: [node]) // not interned yet (interior)
///
/// // Full-tree interning happens as a post-pass; demangleAsNode() does this by default
/// let canonical = NodeCache.shared.intern(tree)
///
/// // Clear cache when done processing a binary
/// NodeCache.shared.clear()
/// ```
public final class NodeCache: Sendable {
    /// The shared global cache instance.
    /// NodeFactory singletons are registered at initialization time.
    public static let shared: NodeCache = {
        let cache = NodeCache()
        cache.storage.withLockUnchecked { NodeCache.registerFactorySingletons(in: &$0) }
        return cache
    }()

    // MARK: - Key Types

    /// Key for leaf nodes (no children). Uses kind + contents for identity.
    private struct LeafKey: Hashable {
        let kind: Node.Kind
        let contents: Node.Contents

        init(_ node: Node) {
            self.kind = node.kind
            self.contents = node.contents
        }

        init(kind: Node.Kind, contents: Node.Contents = .none) {
            self.kind = kind
            self.contents = contents
        }
    }

    /// Key for interior nodes (with children).
    ///
    /// Children are compared by identity (`===`) rather than structure: interning
    /// proceeds bottom-up, so an entry can only be stored after its children have
    /// been canonicalized. A lookup that finds identical child instances is therefore
    /// authoritative, keeping hashing and equality O(children) with no recursion.
    private struct SubtreeKey: Hashable {
        let node: Node

        static func == (lhs: SubtreeKey, rhs: SubtreeKey) -> Bool {
            guard lhs.node.kind == rhs.node.kind, lhs.node.contents == rhs.node.contents else { return false }
            let leftChildren = lhs.node.children
            let rightChildren = rhs.node.children
            guard leftChildren.count == rightChildren.count else { return false }
            for childIndex in leftChildren.indices where leftChildren[childIndex] !== rightChildren[childIndex] {
                return false
            }
            return true
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(node.kind)
            hasher.combine(node.contents)
            for child in node.children {
                hasher.combine(ObjectIdentifier(child))
            }
        }
    }

    // MARK: - Storage

    /// Everything mutable about the cache, reachable only inside
    /// ``Mutex/withLockUnchecked(_:)``.
    ///
    /// Both tables live in one value so that a single acquisition covers an
    /// operation touching both — `internTree` walks a subtree canonicalizing
    /// leaves and interior nodes as it goes, and splitting them across two
    /// mutexes would make that walk non-atomic.
    private struct Storage {
        /// Leaf nodes (no children), keyed by kind + contents.
        var leaves: [LeafKey: Node] = [:]
        /// Interior nodes, keyed by kind + contents + child identities.
        var subtrees: Set<SubtreeKey> = []
    }

    private let storage = Mutex(Storage())

    /// Number of unique leaf nodes in the cache.
    public var count: Int {
        storage.withLockUnchecked { $0.leaves.count }
    }

    /// Number of unique interior nodes (subtrees with children) in the cache.
    public var subtreeCount: Int {
        storage.withLockUnchecked { $0.subtrees.count }
    }

    /// Creates a new empty cache.
    /// Use this for isolated caching scenarios. For shared caching, use `NodeCache.shared`.
    public init() {}

    // MARK: - Inline Interning (used by Node.create)

    // Contents and children are never accepted together here either, so the
    // invalid combination has no internal back door — see
    // `Node.create(kind:text:)`. An empty `children` still interns as a leaf.

    /// Creates or retrieves an interned node.
    /// Called by `Node.create()`. Only leaf nodes (no children) are cached.
    @usableFromInline
    func createInterned(kind: Node.Kind, children: [Node]) -> Node {
        if children.isEmpty {
            return storage.withLockUnchecked { Self.internLeaf(kind: kind, contents: .none, in: &$0) }
        }
        return Node(kind: kind, contents: .none, children: children)
    }

    /// Creates or retrieves an interned leaf carrying `contents`.
    @usableFromInline
    func createInterned(kind: Node.Kind, contents: Node.Contents) -> Node {
        storage.withLockUnchecked { Self.internLeaf(kind: kind, contents: contents, in: &$0) }
    }

    /// Creates or retrieves an interned node from inline children.
    /// Called by `Node.create()`. Only leaf nodes (no children) are cached.
    @usableFromInline
    func createInterned(kind: Node.Kind, inlineChildren: Node.Children) -> Node {
        if inlineChildren.isEmpty {
            return storage.withLockUnchecked { Self.internLeaf(kind: kind, contents: .none, in: &$0) }
        }
        return Node(kind: kind, contents: .none, inlineChildren: inlineChildren)
    }

    // MARK: - Leaf Node Interning (No Children)

    /// Interns a leaf node with no contents and no children.
    /// Returns an existing cached node if one exists, otherwise creates and caches a new one.
    public func intern(kind: Node.Kind) -> Node {
        storage.withLockUnchecked { cacheStorage in
            Self.internLeaf(kind: kind, contents: .none, in: &cacheStorage)
        }
    }

    /// Interns a leaf node with text contents.
    public func intern(kind: Node.Kind, text: String) -> Node {
        storage.withLockUnchecked { cacheStorage in
            Self.internLeaf(kind: kind, contents: .text(text), in: &cacheStorage)
        }
    }

    /// Interns a leaf node with index contents.
    public func intern(kind: Node.Kind, index: UInt64) -> Node {
        storage.withLockUnchecked { cacheStorage in
            Self.internLeaf(kind: kind, contents: .index(index), in: &cacheStorage)
        }
    }

    // MARK: - Node with Children

    /// Creates or retrieves an interned node with a single child.
    public func intern(kind: Node.Kind, child: Node) -> Node {
        storage.withLockUnchecked { cacheStorage in
            Self.internTree(Node(kind: kind, contents: .none, children: [child]), in: &cacheStorage)
        }
    }

    /// Creates or retrieves an interned node with multiple children.
    public func intern(kind: Node.Kind, children: [Node]) -> Node {
        storage.withLockUnchecked { cacheStorage in
            if children.isEmpty {
                return Self.internLeaf(kind: kind, contents: .none, in: &cacheStorage)
            }
            return Self.internTree(Node(kind: kind, contents: .none, children: children), in: &cacheStorage)
        }
    }

    // There is no `intern(kind:text:children:)` / `intern(kind:index:children:)`.
    // Contents and children are mutually exclusive in `Payload`, so with
    // children present `mergedPayload` discarded the contents and the resulting
    // `SubtreeKey` matched across differently-texted requests — two calls
    // differing only in `text` returned the *same* instance, both reporting
    // `text == nil`. With empty children they merely duplicated
    // ``intern(kind:text:)`` / ``intern(kind:index:)`` above. Deleted rather
    // than guarded so the invalid combination cannot be spelled
    // (PR #7 review, finding 8).

    // MARK: - Tree Interning (Post-Processing)

    /// Recursively interns a tree bottom-up (full hash-consing).
    ///
    /// Leaf nodes are deduplicated through the leaf cache; interior nodes are
    /// deduplicated by (kind, contents, child identities). Structurally equal
    /// subtrees — within one tree or across trees — collapse to a single shared
    /// instance, so `===` on interned nodes implies structural equality.
    ///
    /// - Parameter node: The root node to intern.
    /// - Returns: The canonical node for the tree.
    public func intern(_ node: Node) -> Node {
        storage.withLockUnchecked { cacheStorage in
            Self.internTree(node, in: &cacheStorage)
        }
    }

    /// Recursively interns multiple trees bottom-up (full hash-consing).
    public func intern(_ nodes: [Node]) -> [Node] {
        storage.withLockUnchecked { cacheStorage in
            nodes.map { Self.internTree($0, in: &cacheStorage) }
        }
    }

    // MARK: - Historically Unsynchronized Methods

    // These once skipped the lock to save the cost of an `NSLock` acquisition
    // in single-threaded callers. The state now lives in a `Mutex`, which is
    // reachable only from inside `withLock`, so they acquire like everything
    // else — an uncontended `os_unfair_lock` is a couple of atomics, cheaper
    // than the `NSLock` the old fast path was avoiding. The names are kept for
    // source compatibility; there is no longer an unsynchronized variant, and
    // calling these from several threads is now simply correct.

    /// Interns a leaf node with no contents.
    public func internUnsafe(kind: Node.Kind) -> Node {
        storage.withLockUnchecked { Self.internLeaf(kind: kind, contents: .none, in: &$0) }
    }

    /// Interns a leaf node with text contents.
    public func internUnsafe(kind: Node.Kind, text: String) -> Node {
        storage.withLockUnchecked { Self.internLeaf(kind: kind, contents: .text(text), in: &$0) }
    }

    /// Interns a leaf node with index contents.
    public func internUnsafe(kind: Node.Kind, index: UInt64) -> Node {
        storage.withLockUnchecked { Self.internLeaf(kind: kind, contents: .index(index), in: &$0) }
    }

    /// Creates a node with children. Interns fully (leaf or subtree).
    public func internUnsafe(kind: Node.Kind, children: [Node]) -> Node {
        storage.withLockUnchecked { cacheStorage in
            if children.isEmpty {
                return Self.internLeaf(kind: kind, contents: .none, in: &cacheStorage)
            }
            return Self.internTree(Node(kind: kind, contents: .none, children: children), in: &cacheStorage)
        }
    }

    /// One suspended level of ``internTreeUnsafe(_:)``'s bottom-up walk.
    private struct InternFrame {
        let node: Node
        var nextChildIndex: Int
        var internedChildren: [Node]
        var childrenChanged: Bool
    }

    /// Interns a tree bottom-up (full hash-consing).
    ///
    /// The name is kept for source compatibility; the walk is synchronized like
    /// every other entry point (see the note above ``internUnsafe(kind:)``).
    public func internTreeUnsafe(_ node: Node) -> Node {
        storage.withLockUnchecked { Self.internTree(node, in: &$0) }
    }

    /// Interns a tree bottom-up into `storage` (full hash-consing).
    ///
    /// Walked with an explicit stack rather than by recursion. This runs on
    /// every `demangleAsNode` call that leaves `internsSubtrees` at its default,
    /// so it is on the hot path for the deepest trees the library ever sees, and
    /// as a whole-tree walk it sits outside every engine's stack guard.
    ///
    /// The walk memoizes canonical results by source-instance identity for its
    /// own duration. The `SubtreeKey` probe alone is not enough: it keys by the
    /// probed node's *original* child identities, so it only short-cuts while
    /// those children are already canonical. As soon as canonicalization
    /// replaces a child anywhere below — structural duplicates inside the tree,
    /// or overlap with previously interned structure, the normal case for every
    /// tree after the first — every repeated instance probe-misses and, without
    /// the memo, re-descends its whole subtree once per *path*: 2^N on a
    /// doubling DAG, reachable straight through default `demangleAsNode`
    /// because substitution back-references repeat instances (evolution 0006).
    ///
    /// - Precondition: the caller holds the mutex — that is what the `inout
    ///   Storage` stands for.
    private static func internTree(_ node: Node, in cacheStorage: inout Storage) -> Node {
        var frames: [InternFrame] = []
        var completedChild: Node?
        var canonicalBySourceIdentity: [ObjectIdentifier: Node] = [:]

        func canonicalizeWithoutDescending(_ candidate: Node) -> Node? {
            // A source instance this walk already canonicalized repeats its
            // result — this is what keeps the walk priced by node count.
            if let alreadyCanonicalized = canonicalBySourceIdentity[ObjectIdentifier(candidate)] {
                return alreadyCanonicalized
            }
            // Leaf node: intern it, and memoize like every other branch — a
            // repeated leaf instance otherwise re-pays a `LeafKey` string hash
            // once per referencing edge (PR #7 review, minor finding).
            if candidate.children.isEmpty {
                let canonical = Self.internLeaf(kind: candidate.kind, contents: candidate.contents, in: &cacheStorage)
                canonicalBySourceIdentity[ObjectIdentifier(candidate)] = canonical
                return canonical
            }
            // Fast path: a stored entry can only match by identity of children if those
            // children are already canonical, so a hit is authoritative without descending.
            // This also makes re-interning an already-canonical subtree O(children).
            if let existingIndex = cacheStorage.subtrees.firstIndex(of: SubtreeKey(node: candidate)) {
                let canonical = cacheStorage.subtrees[existingIndex].node
                canonicalBySourceIdentity[ObjectIdentifier(candidate)] = canonical
                return canonical
            }
            return nil
        }

        if let canonical = canonicalizeWithoutDescending(node) {
            return canonical
        }
        frames.append(InternFrame(node: node, nextChildIndex: 0, internedChildren: [], childrenChanged: false))
        frames[0].internedChildren.reserveCapacity(node.children.count)

        while var frame = frames.popLast() {
            if let interned = completedChild {
                frame.internedChildren.append(interned)
                if interned !== frame.node.children[frame.nextChildIndex - 1] {
                    frame.childrenChanged = true
                }
                completedChild = nil
            }

            if frame.nextChildIndex < frame.node.children.count {
                let child = frame.node.children[frame.nextChildIndex]
                frame.nextChildIndex += 1
                frames.append(frame)

                if let canonical = canonicalizeWithoutDescending(child) {
                    completedChild = canonical
                } else {
                    var childFrame = InternFrame(node: child, nextChildIndex: 0, internedChildren: [], childrenChanged: false)
                    childFrame.internedChildren.reserveCapacity(child.children.count)
                    frames.append(childFrame)
                }
                continue
            }

            // Only reconstruct if a child was replaced by its canonical instance; the
            // candidate is dropped again if an equivalent subtree is already stored.
            let candidate = frame.childrenChanged
                ? Node(kind: frame.node.kind, contents: frame.node.contents, children: frame.internedChildren)
                : frame.node
            let canonical = cacheStorage.subtrees.insert(SubtreeKey(node: candidate)).memberAfterInsert.node
            canonicalBySourceIdentity[ObjectIdentifier(frame.node)] = canonical

            if frames.isEmpty {
                return canonical
            }
            completedChild = canonical
        }

        // Unreachable: the loop returns as soon as the root frame completes.
        return node
    }

    // MARK: - Cache Management

    /// Whether a leaf with this kind and contents is already canonical here,
    /// without making it so.
    ///
    /// Every other way of asking is a mutation: `intern` builds and stores the
    /// leaf on a miss, and `count` is a shared counter that concurrent work
    /// moves. Tests that assert a code path left the global cache alone need a
    /// question that is both read-only and specific to one leaf.
    func containsCanonicalLeaf(kind: Node.Kind, contents: Node.Contents) -> Bool {
        storage.withLockUnchecked { cacheStorage in
            cacheStorage.leaves[LeafKey(kind: kind, contents: contents)] != nil
        }
    }

    /// Clears all cached nodes.
    /// Call this when you're done processing a binary to free memory.
    public func clear() {
        storage.withLockUnchecked { cacheStorage in
            cacheStorage.leaves.removeAll()
            cacheStorage.subtrees.removeAll()
            Self.registerFactorySingletons(in: &cacheStorage)
        }
    }

    /// Reserves capacity for the expected number of unique leaf nodes.
    public func reserveCapacity(_ minimumCapacity: Int) {
        storage.withLockUnchecked { cacheStorage in
            cacheStorage.leaves.reserveCapacity(minimumCapacity)
        }
    }

    // MARK: - Private Helpers

    /// Registers all `NodeFactory` singletons into the leaf cache.
    ///
    /// Ensures identity consistency: `Node.create(kind: .emptyList)` returns the same
    /// instance as `NodeFactory.emptyList`.
    private static func registerFactorySingletons(in cacheStorage: inout Storage) {
        let singletons: [Node] = [
            NodeFactory.emptyList,
            NodeFactory.firstElementMarker,
            NodeFactory.labelList,
            NodeFactory.throwsAnnotation,
            NodeFactory.asyncAnnotation,
            NodeFactory.variadicMarker,
            NodeFactory.concurrentFunctionType,
            NodeFactory.isolatedAnyFunctionType,
            NodeFactory.nonIsolatedCallerFunctionType,
            NodeFactory.sendingResultFunctionType,
            NodeFactory.unknownIndex,
            NodeFactory.constrainedExistentialSelf,
            NodeFactory.objCAttribute,
            NodeFactory.nonObjCAttribute,
            NodeFactory.dynamicAttribute,
            NodeFactory.directMethodReferenceAttribute,
            NodeFactory.distributedThunk,
            NodeFactory.distributedAccessor,
            NodeFactory.partialApplyObjCForwarder,
            NodeFactory.partialApplyForwarder,
            NodeFactory.mergedFunction,
            NodeFactory.dynamicallyReplaceableFunctionVar,
            NodeFactory.dynamicallyReplaceableFunctionKey,
            NodeFactory.dynamicallyReplaceableFunctionImpl,
            NodeFactory.asyncFunctionPointer,
            NodeFactory.backDeploymentThunk,
            NodeFactory.backDeploymentFallback,
            NodeFactory.coroFunctionPointer,
            NodeFactory.defaultOverride,
            NodeFactory.hasSymbolQuery,
            NodeFactory.accessibleFunctionRecord,
            NodeFactory.implEscaping,
            NodeFactory.implErasedIsolation,
            NodeFactory.implSendingResult,
            NodeFactory.isSerialized,
            NodeFactory.asyncRemoved,
            NodeFactory.tuple,
            NodeFactory.pack,
            NodeFactory.errorType,
            NodeFactory.sugaredOptional,
            NodeFactory.sugaredArray,
            NodeFactory.sugaredParen,
            NodeFactory.opaqueReturnType,
            NodeFactory.vTableAttribute,
        ]

        for singleton in singletons {
            let key = LeafKey(singleton)
            cacheStorage.leaves[key] = singleton
        }
    }

    /// Returns the canonical leaf for `kind`/`contents`, creating and storing
    /// it on a miss.
    ///
    /// - Precondition: the caller holds the mutex — that is what the `inout
    ///   Storage` stands for.
    private static func internLeaf(kind: Node.Kind, contents: Node.Contents, in cacheStorage: inout Storage) -> Node {
        let key = LeafKey(kind: kind, contents: contents)
        if let existing = cacheStorage.leaves[key] {
            return existing
        }
        let node = Node(kind: kind, contents: contents)
        cacheStorage.leaves[key] = node
        return node
    }
}

// MARK: - NodeFactory Static Singletons

/// Factory providing pre-created singleton instances for common parameterless nodes.
///
/// These singletons are used directly by `Demangler` during parsing to avoid
/// creating duplicate instances of frequently-used nodes.
///
/// For nodes with contents or children, use `NodeCache.shared` to intern them.
public enum NodeFactory {

    // MARK: - Static Singletons (Parameterless Nodes)

    /// `.emptyList` - extremely common in function signatures
    public static let emptyList = Node(kind: .emptyList)

    /// `.firstElementMarker` - used in tuple/label processing
    public static let firstElementMarker = Node(kind: .firstElementMarker)

    /// `.labelList` - used in function parameter labels
    public static let labelList = Node(kind: .labelList)

    /// `.throwsAnnotation` - function throws marker
    public static let throwsAnnotation = Node(kind: .throwsAnnotation)

    /// `.asyncAnnotation` - async function marker
    public static let asyncAnnotation = Node(kind: .asyncAnnotation)

    /// `.variadicMarker` - variadic parameter marker
    public static let variadicMarker = Node(kind: .variadicMarker)

    /// `.concurrentFunctionType` - @Sendable function marker
    public static let concurrentFunctionType = Node(kind: .concurrentFunctionType)

    /// `.isolatedAnyFunctionType` - @isolated(any) marker
    public static let isolatedAnyFunctionType = Node(kind: .isolatedAnyFunctionType)

    /// `.nonIsolatedCallerFunctionType` - nonisolated(unsafe) marker
    public static let nonIsolatedCallerFunctionType = Node(kind: .nonIsolatedCallerFunctionType)

    /// `.sendingResultFunctionType` - sending result marker
    public static let sendingResultFunctionType = Node(kind: .sendingResultFunctionType)

    /// `.unknownIndex` - placeholder for unknown indices
    public static let unknownIndex = Node(kind: .unknownIndex)

    /// `.constrainedExistentialSelf` - Self in constrained existential
    public static let constrainedExistentialSelf = Node(kind: .constrainedExistentialSelf)

    // Function attributes
    public static let objCAttribute = Node(kind: .objCAttribute)
    public static let nonObjCAttribute = Node(kind: .nonObjCAttribute)
    public static let dynamicAttribute = Node(kind: .dynamicAttribute)
    public static let directMethodReferenceAttribute = Node(kind: .directMethodReferenceAttribute)
    public static let distributedThunk = Node(kind: .distributedThunk)
    public static let distributedAccessor = Node(kind: .distributedAccessor)
    public static let partialApplyObjCForwarder = Node(kind: .partialApplyObjCForwarder)
    public static let partialApplyForwarder = Node(kind: .partialApplyForwarder)
    public static let mergedFunction = Node(kind: .mergedFunction)
    public static let dynamicallyReplaceableFunctionVar = Node(kind: .dynamicallyReplaceableFunctionVar)
    public static let dynamicallyReplaceableFunctionKey = Node(kind: .dynamicallyReplaceableFunctionKey)
    public static let dynamicallyReplaceableFunctionImpl = Node(kind: .dynamicallyReplaceableFunctionImpl)

    // Async/thunk related
    public static let asyncFunctionPointer = Node(kind: .asyncFunctionPointer)
    public static let backDeploymentThunk = Node(kind: .backDeploymentThunk)
    public static let backDeploymentFallback = Node(kind: .backDeploymentFallback)
    public static let coroFunctionPointer = Node(kind: .coroFunctionPointer)
    public static let defaultOverride = Node(kind: .defaultOverride)
    public static let hasSymbolQuery = Node(kind: .hasSymbolQuery)
    public static let accessibleFunctionRecord = Node(kind: .accessibleFunctionRecord)

    // Impl function markers
    public static let implEscaping = Node(kind: .implEscaping)
    public static let implErasedIsolation = Node(kind: .implErasedIsolation)
    public static let implSendingResult = Node(kind: .implSendingResult)

    // Serialization/async markers
    public static let isSerialized = Node(kind: .isSerialized)
    public static let asyncRemoved = Node(kind: .asyncRemoved)

    // Common type nodes
    public static let tuple = Node(kind: .tuple)
    public static let pack = Node(kind: .pack)
    public static let errorType = Node(kind: .errorType)
    public static let sugaredOptional = Node(kind: .sugaredOptional)
    public static let sugaredArray = Node(kind: .sugaredArray)
    public static let sugaredParen = Node(kind: .sugaredParen)
    public static let opaqueReturnType = Node(kind: .opaqueReturnType)
    public static let vTableAttribute = Node(kind: .vTableAttribute)
}

// MARK: - Node Interning Extension

extension Node {
    /// Interns this node tree into the global cache.
    ///
    /// Convenience method that calls `NodeCache.shared.intern(self)`.
    public func interned() -> Node {
        NodeCache.shared.intern(self)
    }
}

extension Node {
    convenience init(kind: Kind, child: Node) {
        self.init(kind: kind, contents: .none, children: [child])
    }

    convenience init(kind: Kind, children: [Node] = []) {
        self.init(kind: kind, contents: .none, children: children)
    }

    // Contents-carrying leaves only — see `Node.create(kind:text:)` for why the
    // `child:`/`children:` counterparts are gone.
    convenience init(kind: Kind, text: String) {
        self.init(kind: kind, contents: .text(text))
    }

    convenience init(kind: Kind, index: UInt64) {
        self.init(kind: kind, contents: .index(index))
    }

    convenience init(typeWithChildKind: Kind, childChild: Node) {
        self.init(kind: .type, contents: .none, children: [Node.create(kind: typeWithChildKind, children: [childChild])])
    }

    convenience init(typeWithChildKind: Kind, childChildren: [Node]) {
        self.init(kind: .type, contents: .none, children: [Node.create(kind: typeWithChildKind, children: childChildren)])
    }

    convenience init(swiftStdlibTypeKind: Kind, name: String) {
        self.init(kind: .type, contents: .none, children: [Node.create(kind: swiftStdlibTypeKind, children: [
            Node.create(kind: .module, text: stdlibName),
            Node.create(kind: .identifier, text: name),
        ])])
    }

    convenience init(swiftBuiltinType: Kind, name: String) {
        self.init(kind: .type, children: [Node.create(kind: swiftBuiltinType, text: name)])
    }
}

extension Node {
    // No `contents:` parameter: this initializer exists to produce children,
    // and the two are mutually exclusive in `Payload`. Mirrors the public
    // `Node.create(kind:childrenBuilder:)`, which dropped its own `contents:`
    // for the same reason.
    convenience init(kind: Kind, @ArrayBuilder<Node> childrenBuilder: () -> [Node]) {
        self.init(kind: kind, children: childrenBuilder())
    }
}
