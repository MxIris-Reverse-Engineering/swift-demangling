import Foundation
import FoundationToolbox

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
/// The cache uses a lock for thread-safe access.
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
public final class NodeCache: @unchecked Sendable {
    /// The shared global cache instance.
    /// NodeFactory singletons are registered at initialization time.
    public static let shared: NodeCache = {
        let cache = NodeCache()
        cache.registerFactorySingletons()
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

    /// Storage for leaf nodes (no children).
    private var leafStorage: [LeafKey: Node] = [:]

    /// Storage for interior nodes (with children), keyed by kind + contents + child identities.
    private var subtreeStorage: Set<SubtreeKey> = []

    /// Lock for thread-safe access.
    private let lock = NSLock()

    /// Number of unique leaf nodes in the cache.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return leafStorage.count
    }

    /// Number of unique interior nodes (subtrees with children) in the cache.
    public var subtreeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subtreeStorage.count
    }

    /// Creates a new empty cache.
    /// Use this for isolated caching scenarios. For shared caching, use `NodeCache.shared`.
    public init() {}

    // MARK: - Inline Interning (used by Node.create)

    /// Creates or retrieves an interned node.
    /// Called by `Node.create()`. Only leaf nodes (no children) are cached.
    @usableFromInline
    func createInterned(kind: Node.Kind, contents: Node.Contents, children: [Node]) -> Node {
        if children.isEmpty {
            lock.lock()
            defer { lock.unlock() }
            return internLeafUnsafe(kind: kind, contents: contents)
        }
        return Node(kind: kind, contents: contents, children: children)
    }

    /// Creates or retrieves an interned node from inline children.
    /// Called by `Node.create()`. Only leaf nodes (no children) are cached.
    @usableFromInline
    func createInterned(kind: Node.Kind, contents: Node.Contents, inlineChildren: Node.Children) -> Node {
        if inlineChildren.isEmpty {
            lock.lock()
            defer { lock.unlock() }
            return internLeafUnsafe(kind: kind, contents: contents)
        }
        return Node(kind: kind, contents: contents, inlineChildren: inlineChildren)
    }

    // MARK: - Leaf Node Interning (No Children)

    /// Interns a leaf node with no contents and no children.
    /// Returns an existing cached node if one exists, otherwise creates and caches a new one.
    public func intern(kind: Node.Kind) -> Node {
        lock.lock()
        defer { lock.unlock() }
        return internLeafUnsafe(kind: kind, contents: .none)
    }

    /// Interns a leaf node with text contents.
    public func intern(kind: Node.Kind, text: String) -> Node {
        lock.lock()
        defer { lock.unlock() }
        return internLeafUnsafe(kind: kind, contents: .text(text))
    }

    /// Interns a leaf node with index contents.
    public func intern(kind: Node.Kind, index: UInt64) -> Node {
        lock.lock()
        defer { lock.unlock() }
        return internLeafUnsafe(kind: kind, contents: .index(index))
    }

    // MARK: - Node with Children

    /// Creates or retrieves an interned node with a single child.
    public func intern(kind: Node.Kind, child: Node) -> Node {
        lock.lock()
        defer { lock.unlock() }
        return internTreeUnsafe(Node(kind: kind, contents: .none, children: [child]))
    }

    /// Creates or retrieves an interned node with multiple children.
    public func intern(kind: Node.Kind, children: [Node]) -> Node {
        lock.lock()
        defer { lock.unlock() }
        if children.isEmpty {
            return internLeafUnsafe(kind: kind, contents: .none)
        }
        return internTreeUnsafe(Node(kind: kind, contents: .none, children: children))
    }

    /// Creates or retrieves an interned node with text contents and children.
    public func intern(kind: Node.Kind, text: String, children: [Node]) -> Node {
        lock.lock()
        defer { lock.unlock() }
        if children.isEmpty {
            return internLeafUnsafe(kind: kind, contents: .text(text))
        }
        return internTreeUnsafe(Node(kind: kind, contents: .text(text), children: children))
    }

    /// Creates or retrieves an interned node with index contents and children.
    public func intern(kind: Node.Kind, index: UInt64, children: [Node]) -> Node {
        lock.lock()
        defer { lock.unlock() }
        if children.isEmpty {
            return internLeafUnsafe(kind: kind, contents: .index(index))
        }
        return internTreeUnsafe(Node(kind: kind, contents: .index(index), children: children))
    }

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
        lock.lock()
        defer { lock.unlock() }
        return internTreeUnsafe(node)
    }

    /// Recursively interns multiple trees bottom-up (full hash-consing).
    public func intern(_ nodes: [Node]) -> [Node] {
        lock.lock()
        defer { lock.unlock() }
        return nodes.map { internTreeUnsafe($0) }
    }

    // MARK: - Unsynchronized Methods (for single-threaded use)

    /// Interns a node without locking. Use only in single-threaded contexts.
    public func internUnsafe(kind: Node.Kind) -> Node {
        internLeafUnsafe(kind: kind, contents: .none)
    }

    /// Interns a node with text without locking.
    public func internUnsafe(kind: Node.Kind, text: String) -> Node {
        internLeafUnsafe(kind: kind, contents: .text(text))
    }

    /// Interns a node with index without locking.
    public func internUnsafe(kind: Node.Kind, index: UInt64) -> Node {
        internLeafUnsafe(kind: kind, contents: .index(index))
    }

    /// Creates a node with children without locking. Interns fully (leaf or subtree).
    public func internUnsafe(kind: Node.Kind, children: [Node]) -> Node {
        if children.isEmpty {
            return internLeafUnsafe(kind: kind, contents: .none)
        }
        return internTreeUnsafe(Node(kind: kind, contents: .none, children: children))
    }

    /// Recursively interns a tree bottom-up without locking (full hash-consing).
    public func internTreeUnsafe(_ node: Node) -> Node {
        // Leaf node: intern it
        if node.children.isEmpty {
            return internLeafUnsafe(kind: node.kind, contents: node.contents)
        }

        // Fast path: a stored entry can only match by identity of children if those
        // children are already canonical, so a hit is authoritative without descending.
        // This also makes re-interning an already-canonical subtree O(children).
        if let existingIndex = subtreeStorage.firstIndex(of: SubtreeKey(node: node)) {
            return subtreeStorage[existingIndex].node
        }

        // Canonicalize children bottom-up
        var childrenChanged = false
        var internedChildren = [Node]()
        internedChildren.reserveCapacity(node.children.count)

        for child in node.children {
            let interned = internTreeUnsafe(child)
            internedChildren.append(interned)
            if interned !== child {
                childrenChanged = true
            }
        }

        // Only reconstruct if a child was replaced by its canonical instance; the
        // candidate is dropped again if an equivalent subtree is already stored.
        let candidate = childrenChanged
            ? Node(kind: node.kind, contents: node.contents, children: internedChildren)
            : node
        return subtreeStorage.insert(SubtreeKey(node: candidate)).memberAfterInsert.node
    }

    // MARK: - Cache Management

    /// Clears all cached nodes.
    /// Call this when you're done processing a binary to free memory.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        leafStorage.removeAll()
        subtreeStorage.removeAll()
        registerFactorySingletons()
    }

    /// Reserves capacity for the expected number of unique leaf nodes.
    public func reserveCapacity(_ minimumCapacity: Int) {
        lock.lock()
        defer { lock.unlock() }
        leafStorage.reserveCapacity(minimumCapacity)
    }

    // MARK: - Private Helpers

    /// Registers all `NodeFactory` singletons into the leaf cache.
    ///
    /// Ensures identity consistency: `Node.create(kind: .emptyList)` returns the same
    /// instance as `NodeFactory.emptyList`.
    private func registerFactorySingletons() {
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
            leafStorage[key] = singleton
        }
    }

    private func internLeafUnsafe(kind: Node.Kind, contents: Node.Contents) -> Node {
        let key = LeafKey(kind: kind, contents: contents)
        if let existing = leafStorage[key] {
            return existing
        }
        let node = Node(kind: kind, contents: contents)
        leafStorage[key] = node
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

    convenience init(kind: Kind, text: String, child: Node) {
        self.init(kind: kind, contents: .text(text), children: [child])
    }

    convenience init(kind: Kind, text: String, children: [Node] = []) {
        self.init(kind: kind, contents: .text(text), children: children)
    }

    convenience init(kind: Kind, index: UInt64, child: Node) {
        self.init(kind: kind, contents: .index(index), children: [child])
    }

    convenience init(kind: Kind, index: UInt64, children: [Node] = []) {
        self.init(kind: kind, contents: .index(index), children: children)
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
    convenience init(kind: Kind, contents: Contents = .none, @ArrayBuilder<Node> childrenBuilder: () -> [Node]) {
        self.init(kind: kind, contents: contents, children: childrenBuilder())
    }

    convenience init(kind: Kind, text: String, @ArrayBuilder<Node> childrenBuilder: () -> [Node]) {
        self.init(kind: kind, contents: .text(text), children: childrenBuilder())
    }

    convenience init(kind: Kind, index: UInt64, @ArrayBuilder<Node> childrenBuilder: () -> [Node]) {
        self.init(kind: kind, contents: .index(index), children: childrenBuilder())
    }
}
