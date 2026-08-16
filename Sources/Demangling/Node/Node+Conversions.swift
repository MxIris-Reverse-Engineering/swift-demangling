extension Node {
    @inlinable
    public var text: String? {
        switch payload {
        case .text(let s): return s
        case .oneChild, .twoChildren, .manyChildren:
            // For dependentGenericParamType nodes, derive the name from children (depth, index)
            if kind == .dependentGenericParamType {
                return _genericParamNameFromChildren
            }
            return nil
        default: return nil
        }
    }

    /// Derives the generic parameter name (e.g. "A", "B", "A1") from children.
    /// Children are [Index(depth), Index(index)].
    @usableFromInline
    var _genericParamNameFromChildren: String? {
        guard let depth = firstChild?.index, let idx = children.at(1)?.index else { return nil }
        return genericParameterName(depth: depth, index: idx)
    }

    @inlinable
    public var hasText: Bool {
        switch payload {
        case .text: return true
        case .oneChild, .twoChildren, .manyChildren:
            return kind == .dependentGenericParamType
        default: return false
        }
    }

    public var indexAsCharacter: Character? {
        if let index, let scalar = UnicodeScalar(UInt32(index)) {
            return Character(scalar)
        } else {
            return nil
        }
    }

    @inlinable
    public var index: UInt64? {
        switch payload {
        case .index(let i): return i
        default: return nil
        }
    }

    @inlinable
    public var hasIndex: Bool {
        switch payload {
        case .index: return true
        default: return false
        }
    }

    @inlinable
    public var isNoneContents: Bool {
        switch payload {
        case .none, .oneChild, .twoChildren, .manyChildren: return true
        default: return false
        }
    }

    @inlinable
    public var numberOfChildren: Int {
        switch payload {
        case .none, .index, .text: return 0
        case .oneChild: return 1
        case .twoChildren: return 2
        case .manyChildren(let arr): return arr.count
        }
    }

    /// Overrides the `DemanglingNode` default, which spells this
    /// `!children.isEmpty`. That default is right for `NodeReference`, but on
    /// `Node` the `children` getter rebuilds a `Children` value and retains
    /// every child reference, so the generic spelling put a retain/release pair
    /// on a question the payload tag answers for free — across eight
    /// `TypeDecoderEngine` guards among others (PR #7 review, minor finding).
    @inlinable
    public var hasChildren: Bool {
        switch payload {
        case .none, .index, .text: return false
        default: return true
        }
    }

    // `subscript(throwChild:)` lives in the `DemanglingNode` extension
    // (DemanglingNode.swift) as the single implementation for both `Node` and
    // `NodeReference`.

    @inlinable
    public var firstChild: Node? {
        switch payload {
        case .oneChild(let n): return n
        case .twoChildren(let n, _): return n
        case .manyChildren(let arr): return arr.first
        default: return nil
        }
    }

    @inlinable
    public var lastChild: Node? {
        switch payload {
        case .oneChild(let n): return n
        case .twoChildren(_, let n): return n
        case .manyChildren(let arr): return arr.last
        default: return nil
        }
    }
}

extension Node {
    /// Whether this node denotes a protocol, looking through `.type` wrappers.
    ///
    /// Unwraps `.type` with a bounded loop rather than by recursing, for the
    /// same reason as ``DemanglingNode/isSimpleType``: this is public API, so
    /// the tree may be caller-assembled rather than demangler-produced, and it
    /// sits outside every engine's stack guard. On demangled input the limit is
    /// unreachable — the demangler does not nest `.type` (measured across the
    /// full 4.5M-symbol corpus, the longest consecutive run is one) — so the
    /// bound exists only so a hand-built chain returns `false` instead of
    /// overflowing the stack.
    public var isProtocol: Bool {
        var currentNode = self
        var unwrapDepth = 0
        while currentNode.kind == .type {
            unwrapDepth += 1
            guard unwrapDepth <= Self.maxTypeWrapperUnwrapDepth,
                  let onlyChild = currentNode.children.first
            else { return false }
            currentNode = onlyChild
        }
        switch currentNode.kind {
        case .protocol,
             .protocolSymbolicReference,
             .objectiveCProtocolSymbolicReference: return true
        default: return false
        }
    }

    // `isSimpleType`, `needSpaceBeforeType`, `isIdentifier(desired:)`, and
    // `isSwiftModule` live in the `DemanglingNode` protocol extension
    // (DemanglingNode.swift) as the single implementation for both `Node`
    // and `NodeReference` — a parallel copy here would drift, since the
    // generic printer engine statically dispatches to the extension.
}

extension Node {
    @inlinable
    public subscript(child childIndex: Int) -> Node {
        children[childIndex]
    }

    @inlinable
    public subscript(safeChild childIndex: Int) -> Node? {
        children.at(childIndex)
    }

    public struct IndexOutOfBoundError: Error {
        public static let `default` = IndexOutOfBoundError()
    }
}

extension Node {
    /// Walked with an explicit deduped stack rather than the `Sequence`
    /// traversal: substitution back-references and interning make demangled
    /// trees DAGs, and the path-based traversal repeats a shared instance once
    /// per path — 2^N on a doubling DAG. Both the `dependentGenericParamCount`
    /// existence guard and the max-combine collection below are idempotent per
    /// instance, so visiting each unique node once answers identically at node
    /// count (evolution 0006).
    public func findGenericParamsDepth() -> [UInt64: UInt64]? {
        guard kind == .dependentGenericType else { return nil }

        var containsGenericParamCount = false
        var depths: [UInt64: UInt64] = [:]

        var pendingNodes: [Node] = [self]
        var visitedNodes: Set<ObjectIdentifier> = []
        while let currentNode = pendingNodes.popLast() {
            guard visitedNodes.insert(ObjectIdentifier(currentNode)).inserted else { continue }

            switch currentNode.kind {
            case .dependentGenericParamCount:
                containsGenericParamCount = true
            case .dependentGenericParamType:
                guard let depth = currentNode.children.at(0)?.index else { break }
                guard let index = currentNode.children.at(1)?.index else { break }
                if let currentDepth = depths[index] {
                    depths[index] = Swift.max(currentDepth, depth)
                } else {
                    depths[index] = depth
                }
            default:
                break
            }

            for child in currentNode.children {
                pendingNodes.append(child)
            }
        }

        guard containsGenericParamCount else { return nil }
        return depths
    }

    // `identifier` lives in DemanglingNode+Sequence.swift as the single
    // implementation shared with `NodeReference`.
}
