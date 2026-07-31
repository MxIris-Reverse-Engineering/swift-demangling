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

    // `hasChildren` and `subscript(throwChild:)` live in the `DemanglingNode`
    // extension (DemanglingNode.swift) as the single implementation for both
    // `Node` and `NodeReference`.

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
    public func findGenericParamsDepth() -> [UInt64: UInt64]? {
        guard kind == .dependentGenericType, first(of: .dependentGenericParamCount) != nil else { return nil }

        var depths: [UInt64: UInt64] = [:]

        for child in self {
            guard child.kind == .dependentGenericParamType else { continue }
            guard let depth = child.children.at(0)?.index else { continue }
            guard let index = child.children.at(1)?.index else { continue }

            if let currentDepth = depths[index] {
                depths[index] = Swift.max(currentDepth, depth)
            } else {
                depths[index] = depth
            }
        }

        return depths
    }

    // `identifier` lives in DemanglingNode+Sequence.swift as the single
    // implementation shared with `NodeReference`.
}
