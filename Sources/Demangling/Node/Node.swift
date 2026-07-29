import Foundation
import SwiftStdlibToolbox

/// A node in the demangled symbol tree.
///
/// Thread safety: Node is safe to read from multiple threads after demangling is complete.
/// All modifications happen during the single-threaded demangling process.
///
/// Internally uses a unified `Payload` enum that merges contents and children
/// storage into a single discriminated union, mirroring the C++ Swift runtime's
/// approach where `Text`/`Index`/`InlineChildren`/`Children` share a `union`.
/// This saves ~24 bytes per node compared to storing them separately.
public final class Node: Sendable, Codable {
    /// Legacy contents type preserved for API compatibility.
    public enum Contents: Hashable, Sendable, Codable {
        case none
        case index(UInt64)
        case text(String)
    }

    /// Unified storage that is either contents (text/index) or children, never both.
    /// Mirrors the C++ Swift runtime's union where Text/Index/InlineChildren/Children
    /// are mutually exclusive.
    @usableFromInline
    enum Payload: Sendable, Codable {
        case none
        case index(UInt64)
        case text(String)
        case oneChild(Node)
        case twoChildren(Node, Node)
        case manyChildren(ContiguousArray<Node>)
    }

    public let kind: Kind

    /// Unified payload storage. Only modified during demangling for child mutations.
    @usableFromInline
    nonisolated(unsafe) var payload: Payload

    /// Releases the subtree without recursing.
    ///
    /// Deallocating a tree of reference-typed nodes normally recurses: releasing
    /// the root releases its children, whose deinit releases theirs, one frame
    /// per level. That happens wherever the last reference dies — typically a
    /// 512KB cooperative-pool thread, which was measured to overflow at around
    /// 620 levels — and no amount of stack budgeting inside the engines can
    /// cover it, because it is the runtime doing the releasing, not this
    /// library.
    ///
    /// Instead the root moves its children into an explicit work list and drains
    /// it. A node is only dismantled when this is the last reference to it;
    /// otherwise it stays alive and must keep its children. Because every
    /// uniquely-referenced node has had its children moved out before it is
    /// released, its own `deinit` finds nothing to descend into.
    deinit {
        switch payload {
        case .none, .index, .text:
            return
        case .oneChild, .twoChildren, .manyChildren:
            break
        }

        var pendingNodes = ContiguousArray<Node>()
        moveChildrenOut(into: &pendingNodes)
        while var node = pendingNodes.popLast() {
            if isKnownUniquelyReferenced(&node) {
                node.moveChildrenOut(into: &pendingNodes)
            }
        }
    }

    /// Detaches this node's children, appending them to `collected`.
    private func moveChildrenOut(into collected: inout ContiguousArray<Node>) {
        switch payload {
        case .none, .index, .text:
            return
        case .oneChild(let onlyChild):
            payload = .none
            collected.append(onlyChild)
        case .twoChildren(let firstChild, let secondChild):
            payload = .none
            collected.append(firstChild)
            collected.append(secondChild)
        case .manyChildren(let allChildren):
            payload = .none
            collected.append(contentsOf: allChildren)
        }
    }

    /// The contents of this node (text, index, or none).
    @inlinable
    public var contents: Contents {
        switch payload {
        case .none,
             .oneChild,
             .twoChildren,
             .manyChildren:
            return .none
        case .index(let i):
            return .index(i)
        case .text(let s):
            return .text(s)
        }
    }

    /// Child nodes. Only modified during demangling.
    @inlinable
    public var children: Children {
        switch payload {
        case .none,
             .index,
             .text:
            return Children()
        case .oneChild(let n):
            return Children(n)
        case .twoChildren(let n0, let n1):
            return Children(n0, n1)
        case .manyChildren(let children):
            return Children(children)
        }
    }

    /// Merge contents and children into the most compact payload case.
    /// When children are present, they take priority (contents and children are mutually exclusive).
    @usableFromInline
    static func mergedPayload(contents: Contents, children: Children) -> Payload {
        if children.count > 0 {
            switch children.count {
            case 1: return .oneChild(children[0])
            case 2: return .twoChildren(children[0], children[1])
            default: return .manyChildren(children.toContiguousArray())
            }
        }
        switch contents {
        case .none: return .none
        case .index(let i): return .index(i)
        case .text(let s): return .text(s)
        }
    }

    init(kind: Kind, contents: Contents = .none, children: [Node] = []) {
        self.kind = kind
        self.payload = Self.mergedPayload(contents: contents, children: Children(children))
    }

    init(kind: Kind, contents: Contents = .none, inlineChildren: Children) {
        self.kind = kind
        self.payload = Self.mergedPayload(contents: contents, children: inlineChildren)
    }

    /// A deep copy of this subtree: every node is rebuilt, nothing is shared
    /// with the original.
    ///
    /// Walked with an explicit stack. This is public API over trees of
    /// arbitrary depth, `NodeBuilder` runs it while holding its lock, and it
    /// sits outside every engine, so no depth parameter can ever reach it — the
    /// same reason ``Node/deinit`` tears trees down iteratively.
    public func copy() -> Node {
        var frames: [RebuildFrame] = [RebuildFrame(source: self)]
        var completedNode: Node?

        while var frame = frames.popLast() {
            if let finishedChild = completedNode {
                frame.rebuiltChildren.append(finishedChild)
                completedNode = nil
            }
            let sourceChildren = frame.source.children
            if frame.nextChildIndex < sourceChildren.count {
                let nextChild = sourceChildren[frame.nextChildIndex]
                frame.nextChildIndex += 1
                frames.append(frame)
                frames.append(RebuildFrame(source: nextChild))
                continue
            }
            completedNode = Node(kind: frame.source.kind, contents: frame.source.contents, inlineChildren: frame.rebuiltChildren)
        }

        // The loop only ends once the root frame has been completed.
        return completedNode ?? self
    }
}

/// One node's in-progress reconstruction, for the iterative whole-tree
/// rebuilds (``Node/copy()`` and ``Node/replacingDescendant(_:with:)``).
private struct RebuildFrame {
    let source: Node
    var nextChildIndex: Int = 0
    var rebuiltChildren = Node.Children()
}

extension Node {
    func changeChild(_ newChild: Node?, at index: Int) -> Node {
        guard children.indices.contains(index) else { return self }

        var modifiedChildren = children
        if let nc = newChild {
            modifiedChildren[index] = nc
        } else {
            modifiedChildren.remove(at: index)
        }
        return Node(kind: kind, contents: contents, inlineChildren: modifiedChildren)
    }

    func changeKind(_ newKind: Kind, additionalChildren: [Node] = []) -> Node {
        let newChildren = children + additionalChildren
        return Node(kind: newKind, contents: contents, inlineChildren: newChildren)
    }

    /// Optimized addChild that mutates payload directly for the common
    /// children-only cases, avoiding a full get/rebuild/set round-trip.
    fileprivate func addChild(_ newChild: Node) {
        switch payload {
        case .none:
            payload = .oneChild(newChild)
        case .oneChild(let n):
            payload = .twoChildren(n, newChild)
        case .twoChildren(let n0, let n1):
            payload = .manyChildren(ContiguousArray([n0, n1, newChild]))
        case .manyChildren(var arr):
            arr.append(newChild)
            payload = .manyChildren(arr)
        default:
            // Rare path: node has both contents and children
            var c = children
            c.append(newChild)
            payload = Self.mergedPayload(contents: contents, children: c)
        }
    }

    fileprivate func removeChild(at index: Int) {
        guard children.indices.contains(index) else { return }
        var c = children
        c.remove(at: index)
        payload = Self.mergedPayload(contents: contents, children: c)
    }

    fileprivate func insertChild(_ newChild: Node, at index: Int) {
        guard index >= 0, index <= children.count else { return }
        var c = children
        c.insert(newChild, at: index)
        payload = Self.mergedPayload(contents: contents, children: c)
    }

    fileprivate func addChildren(_ newChildren: [Node]) {
        var c = children
        c.append(contentsOf: newChildren)
        payload = Self.mergedPayload(contents: contents, children: c)
    }

    fileprivate func addChildren(_ newChildren: Children) {
        var c = children
        c.append(contentsOf: newChildren)
        payload = Self.mergedPayload(contents: contents, children: c)
    }

    fileprivate func setChildren(_ newChildren: [Node]) {
        payload = Self.mergedPayload(contents: contents, children: Children(newChildren))
    }

    fileprivate func setChild(_ child: Node, at index: Int) {
        guard children.indices.contains(index) else { return }
        var c = children
        c[index] = child
        payload = Self.mergedPayload(contents: contents, children: c)
    }

    fileprivate func reverseChildren() {
        var c = children
        c.reverse()
        payload = Self.mergedPayload(contents: contents, children: c)
    }

    fileprivate func reverseFirst(_ count: Int) {
        var c = children
        c.reverseFirst(count)
        payload = Self.mergedPayload(contents: contents, children: c)
    }
}

// MARK: - Non-mutating (copying) versions

// These are internal - external modules should use NodeBuilder

extension Node {
    /// Returns a new node with the child added.
    func addingChild(_ newChild: Node) -> Node {
        var nc = children
        nc.append(newChild)
        return Node(kind: kind, contents: contents, inlineChildren: nc)
    }

    /// Returns a new node with the child removed at the specified index.
    func removingChild(at index: Int) -> Node {
        guard children.indices.contains(index) else { return self }
        var nc = children
        nc.remove(at: index)
        return Node(kind: kind, contents: contents, inlineChildren: nc)
    }

    /// Returns a new node with the child inserted at the specified index.
    func insertingChild(_ newChild: Node, at index: Int) -> Node {
        guard index >= 0, index <= children.count else { return self }
        var nc = children
        nc.insert(newChild, at: index)
        return Node(kind: kind, contents: contents, inlineChildren: nc)
    }

    /// Returns a new node with the children added.
    func addingChildren(_ newChildren: [Node]) -> Node {
        let nc = children + newChildren
        return Node(kind: kind, contents: contents, inlineChildren: nc)
    }

    /// Returns a new node with the specified children.
    func withChildren(_ newChildren: [Node]) -> Node {
        Node(kind: kind, contents: contents, children: newChildren)
    }

    /// Returns a new node with the child replaced at the specified index.
    func withChild(_ child: Node, at index: Int) -> Node {
        guard children.indices.contains(index) else { return self }
        var nc = children
        nc[index] = child
        return Node(kind: kind, contents: contents, inlineChildren: nc)
    }

    /// Returns a new node with children reversed.
    func reversingChildren() -> Node {
        var nc = children
        nc.reverse()
        return Node(kind: kind, contents: contents, inlineChildren: nc)
    }

    /// Returns a new node with the first N children reversed.
    func reversingFirst(_ count: Int) -> Node {
        var nc = children
        nc.reverseFirst(count)
        return Node(kind: kind, contents: contents, inlineChildren: nc)
    }

    /// Returns a new node with children from the given index to end reversed.
    func reversingChildren(from startIndex: Int) -> Node {
        var nc = children
        if startIndex < nc.count {
            nc[startIndex...].reverse()
        }
        return Node(kind: kind, contents: contents, inlineChildren: nc)
    }

    /// Returns a new tree with the descendant node replaced.
    /// If `old` is not found in the tree, returns a copy of self.
    ///
    /// Walked with an explicit stack for the same reason as ``copy()``.
    func replacingDescendant(_ old: Node, with new: Node) -> Node {
        if self === old {
            return new
        }
        var frames: [RebuildFrame] = [RebuildFrame(source: self)]
        var completedNode: Node?

        while var frame = frames.popLast() {
            if let finishedChild = completedNode {
                frame.rebuiltChildren.append(finishedChild)
                completedNode = nil
            }
            let sourceChildren = frame.source.children
            if frame.nextChildIndex < sourceChildren.count {
                let nextChild = sourceChildren[frame.nextChildIndex]
                frame.nextChildIndex += 1
                frames.append(frame)
                if nextChild === old {
                    completedNode = new
                } else {
                    frames.append(RebuildFrame(source: nextChild))
                }
                continue
            }
            completedNode = Node(kind: frame.source.kind, contents: frame.source.contents, inlineChildren: frame.rebuiltChildren)
        }

        return completedNode ?? self
    }
}

// MARK: - NodeBuilder

/// A builder for constructing Node trees by accumulating children.
///
/// Since Node is immutable after creation (mutation methods are fileprivate),
/// use NodeBuilder when you need to incrementally build a node with children.
///
/// Example usage:
/// ```swift
/// let builder = NodeBuilder(kind: .tuple)
/// builder.addChild(element1)
/// builder.addChild(element2)
/// let node = builder.build()
/// ```
public final class NodeBuilder: @unchecked Sendable {
    private let _lock: UnsafeMutablePointer<os_unfair_lock>
    private var _node: Node

    /// The current node being built.
    public var node: Node {
        withLock { _node }
    }

    /// Creates a builder with a copy of the given node.
    public init(_ node: Node) {
        self._lock = .allocate(capacity: 1)
        self._lock.initialize(to: os_unfair_lock())
        self._node = node.copy()
    }

    /// Creates a builder with a new node.
    public init(kind: Node.Kind, contents: Node.Contents = .none, children: [Node] = []) {
        self._lock = .allocate(capacity: 1)
        self._lock.initialize(to: os_unfair_lock())
        self._node = Node(kind: kind, contents: contents, children: children)
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return body()
    }

    // MARK: - Mutating Operations

    /// Adds a child node.
    @discardableResult
    public func addChild(_ child: Node) -> Self {
        withLock { _node.addChild(child) }
        return self
    }

    /// Adds multiple child nodes.
    @discardableResult
    public func addChildren(_ children: [Node]) -> Self {
        withLock { _node.addChildren(children) }
        return self
    }

    /// Inserts a child node at the specified index.
    @discardableResult
    public func insertChild(_ child: Node, at index: Int) -> Self {
        withLock { _node.insertChild(child, at: index) }
        return self
    }

    /// Removes the child at the specified index.
    @discardableResult
    public func removeChild(at index: Int) -> Self {
        withLock { _node.removeChild(at: index) }
        return self
    }

    /// Sets a child at the specified index.
    @discardableResult
    public func setChild(_ child: Node, at index: Int) -> Self {
        withLock { _node.setChild(child, at: index) }
        return self
    }

    /// Replaces all children with the specified nodes.
    @discardableResult
    public func setChildren(_ children: [Node]) -> Self {
        withLock { _node.setChildren(children) }
        return self
    }

    /// Reverses all children.
    @discardableResult
    public func reverseChildren() -> Self {
        withLock { _node.reverseChildren() }
        return self
    }

    /// Reverses the first N children.
    @discardableResult
    public func reverseFirst(_ count: Int) -> Self {
        withLock { _node.reverseFirst(count) }
        return self
    }

    // MARK: - Non-mutating Operations (return new Node)

    /// Returns a new node with the child added.
    public func addingChild(_ child: Node) -> Node {
        withLock { _node.addingChild(child) }
    }

    /// Returns a new node with the children added.
    public func addingChildren(_ children: [Node]) -> Node {
        withLock { _node.addingChildren(children) }
    }

    /// Returns a new node with the child inserted.
    public func insertingChild(_ child: Node, at index: Int) -> Node {
        withLock { _node.insertingChild(child, at: index) }
    }

    /// Returns a new node with the child removed.
    public func removingChild(at index: Int) -> Node {
        withLock { _node.removingChild(at: index) }
    }

    /// Returns a new node with the child replaced.
    public func withChild(_ child: Node, at index: Int) -> Node {
        withLock { _node.withChild(child, at: index) }
    }

    /// Returns a new node with the specified children.
    public func withChildren(_ children: [Node]) -> Node {
        withLock { _node.withChildren(children) }
    }

    /// Returns a new node with children reversed.
    public func reversingChildren() -> Node {
        withLock { _node.reversingChildren() }
    }

    /// Returns a new node with the first N children reversed.
    public func reversingFirst(_ count: Int) -> Node {
        withLock { _node.reversingFirst(count) }
    }

    /// Returns a new node with the descendant replaced.
    public func replacingDescendant(_ old: Node, with new: Node) -> Node {
        withLock { _node.replacingDescendant(old, with: new) }
    }

    // MARK: - Transformations

    /// Returns a new node with a different kind.
    public func changingKind(_ newKind: Node.Kind, additionalChildren: [Node] = []) -> Node {
        withLock { _node.changeKind(newKind, additionalChildren: additionalChildren) }
    }

    /// Returns a new node with the child at index replaced or removed.
    public func changingChild(_ newChild: Node?, at index: Int) -> Node {
        withLock { _node.changeChild(newChild, at: index) }
    }

    /// Returns a copy of the current node.
    public func copy() -> Node {
        withLock { _node.copy() }
    }

    /// Finalizes and returns the built node.
    /// After calling this, the builder should not be used.
    public func build() -> Node {
        withLock { _node }
    }
}
