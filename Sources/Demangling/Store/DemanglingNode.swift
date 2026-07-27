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
    /// store index. It must be equal exactly when two handles denote the same
    /// shared node within a single traversal.
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
    var materializedNode: Node { get }

    /// Requirements (with derived defaults) so representations can provide
    /// allocation-free fast paths — `NodeReference` witnesses these with
    /// byte comparisons against the store's string table instead of
    /// constructing a `String` per check.
    func isIdentifier(desired: String) -> Bool
    var isSwiftModule: Bool { get }
}

// MARK: - Derived helpers shared by the printer

/// The convenience properties the printer engine derives from the protocol
/// primitives. These are the single implementation for both `Node` and
/// `NodeReference`: they are extension members (not requirements), so the
/// generic engine statically dispatches here for every conformer — keeping a
/// parallel copy on a concrete type would silently drift.
extension DemanglingNode {
    /// Prints this subtree with the given options. Mirrors `Node.print(using:)`.
    public func print(using options: DemangleOptions = .default) -> String {
        StackSafeExecutor.executeWithinStackBudget { stackFloorAddress in
            var printer = DemanglingPrinter<String, Self>(options: options)
            return printer.printRootWithinStackBudget(self, stackFloorAddress: stackFloorAddress)
        } unbudgetedFallback: {
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

    public var isSimpleType: Bool {
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
        case .type:
            return children.first.map(\.isSimpleType) ?? false
        case .protocolList:
            return children.first.map { $0.children.count <= 1 } ?? false
        case .protocolListWithAnyObject:
            return (children.first?.children.first).map { $0.children.count == 0 } ?? false
        default:
            return false
        }
    }

    public var needSpaceBeforeType: Bool {
        switch kind {
        case .type:
            return children.first?.needSpaceBeforeType ?? false
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

    @inlinable
    public var printCacheIdentity: NodeStore.NodeIndex { nodeIndex }

    @inlinable
    public var materializedNode: Node { materialize() }
}

extension NodeReference.ChildrenView: DemanglingNodeChildren {}
