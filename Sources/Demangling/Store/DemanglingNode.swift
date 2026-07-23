/// The read-only tree shape shared by `Node` (the class tree) and
/// `NodeReference` (a handle into a `SymbolStore`).
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
}

// MARK: - Derived helpers shared by the printer

/// Generic ports of the `Node` convenience properties the printer engine uses.
/// On `Node` its own concrete members take precedence (identical behavior); the
/// generic engine resolves these when specialized on `NodeReference`.
extension DemanglingNode {
    /// Prints this subtree with the given options. Mirrors `Node.print(using:)`.
    public func print(using options: DemangleOptions = .default) -> String {
        StackSafeExecutor.execute {
            var printer = DemanglingPrinter<String, Self>(options: options)
            return printer.printRoot(self)
        }
    }

    public func isIdentifier(desired: String) -> Bool {
        kind == .identifier && text == desired
    }

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
    public var printCacheIdentity: SymbolStore.NodeIndex { nodeIndex }
}

extension NodeReference.ChildrenView: DemanglingNodeChildren {}
