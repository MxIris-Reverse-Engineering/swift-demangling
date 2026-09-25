import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Guards how an entity's name reaches a rich target when the demangled name
/// wraps its identifier in another node — `privateDeclName` (a `private` or
/// `fileprivate` declaration), `localDeclName` (a declaration inside a function
/// body) or `relatedEntityDeclName` (a Clang-imported related entity).
///
/// A rich target needs two things from the write that carries a name: the
/// `parentKind` of `write(_:context:)`, which says what the name *is* (a
/// protocol, a struct, a function), and the enclosing type-reference scope,
/// which says which declaration it refers to. MachOSwiftSection's
/// `SemanticString` turns the first into the semantic type that drives
/// highlighting and the second into the span identity a jump to the
/// declaration follows. A bare `identifier` got both. A wrapped one got
/// neither: the wrapper went through `printName`, which passed no kind down,
/// and whose memoization printed it into a fresh sub-target — one whose scope
/// stack is empty, so the name landed outside its entity's scope (evolution
/// 0012, item 2, names exactly this case). Every private protocol a
/// conformance names rendered as plain, unlinked text. The printed text is
/// byte-identical either way, which is why no output-comparison test could see
/// it.
@Suite
struct NodePrinterWrappedEntityNameTests {
    /// Writes text exactly like `String`, so the print flow is unchanged, and
    /// records every identifier write with the `parentKind` it arrived with and
    /// the type-reference scope it landed in.
    private struct IdentifierRecordingTarget: NodePrinterTarget {
        struct IdentifierWrite: Equatable, Sendable {
            var content: String
            var parentKind: Node.Kind?
            /// The kind of the innermost open type-reference scope; `nil` for
            /// no scope or a barrier.
            var scopeKind: Node.Kind?
        }

        var text: String = ""
        var identifierWrites: [IdentifierWrite] = []
        /// Per target instance, like `SemanticString`'s: a memoized fragment
        /// printed into a fresh sub-target starts with it empty.
        private var scopeKinds: [Node.Kind?] = []

        init() {}

        var writtenUnitCount: Int { text.utf8.count }

        mutating func write(_ content: String) {
            text.write(content)
        }

        mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
            text.write(content)
            guard let context = context(), context.state == .printIdentifier else { return }
            identifierWrites.append(IdentifierWrite(content: content, parentKind: context.parentKind, scopeKind: scopeKinds.last ?? nil))
        }

        mutating func append(_ other: IdentifierRecordingTarget) {
            text.append(other.text)
            identifierWrites.append(contentsOf: other.identifierWrites)
        }

        mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {
            scopeKinds.append(node()?.kind)
        }

        mutating func popTypeReferenceScope() {
            _ = scopeKinds.popLast()
        }
    }

    struct NamedEntityCase: Sendable, CustomTestStringConvertible {
        let summary: String
        let mangledName: String
        let printedName: String
        let entityKind: Node.Kind
        /// Nominal types open a type-reference scope; functions do not.
        let isTypeReference: Bool

        var testDescription: String { summary }
    }

    static let namedEntityCases: [NamedEntityCase] = [
        NamedEntityCase(
            summary: "bare identifier (the path that always worked)",
            mangledName: "$s4Test6PublicVMn",
            printedName: "Public",
            entityKind: .structure,
            isTypeReference: true
        ),
        NamedEntityCase(
            summary: "private protocol",
            mangledName: "$s7SwiftUI20DocumentViewDelegate33_6B9589E2B2301F373BAB5CF17408C384LLMp",
            printedName: "DocumentViewDelegate",
            entityKind: .protocol,
            isTypeReference: true
        ),
        NamedEntityCase(
            summary: "private struct",
            mangledName: "$s4Test7Private33_0123456789ABCDEF0123456789ABCDEFLLVMn",
            printedName: "Private",
            entityKind: .structure,
            isTypeReference: true
        ),
        NamedEntityCase(
            summary: "private class",
            mangledName: "$s4Test7Private33_0123456789ABCDEF0123456789ABCDEFLLCMn",
            printedName: "Private",
            entityKind: .class,
            isTypeReference: true
        ),
        NamedEntityCase(
            summary: "private enum",
            mangledName: "$s4Test7Private33_0123456789ABCDEF0123456789ABCDEFLLOMn",
            printedName: "Private",
            entityKind: .enum,
            isTypeReference: true
        ),
        NamedEntityCase(
            summary: "private enclosing type, printed as a prefix context",
            mangledName: "$s4Test5Outer33_0123456789ABCDEF0123456789ABCDEFLLC5InnerOMn",
            printedName: "Outer",
            entityKind: .class,
            isTypeReference: true
        ),
        NamedEntityCase(
            summary: "private function",
            mangledName: "$s4Test6helper33_0123456789ABCDEF0123456789ABCDEFLLyyF",
            printedName: "helper",
            entityKind: .function,
            isTypeReference: false
        ),
        NamedEntityCase(
            summary: "local struct",
            mangledName: "$s4Test5outeryyF5LocalL_VMn",
            printedName: "Local",
            entityKind: .structure,
            isTypeReference: true
        ),
        NamedEntityCase(
            summary: "local function",
            mangledName: "$s4Test6helperL_yyF",
            printedName: "helper",
            entityKind: .function,
            isTypeReference: false
        ),
        NamedEntityCase(
            summary: "Clang-imported related entity",
            mangledName: "$sSo6FooBarLeVMn",
            printedName: "FooBar",
            entityKind: .structure,
            isTypeReference: true
        ),
    ]

    /// `.default` prints private discriminators (`(Name in _…)`), the interface
    /// options drop them; the name must arrive intact under both.
    static let printOptions: [DemangleOptions] = [.default, .interfaceTypeBuilderOnly]

    @Test(arguments: namedEntityCases, printOptions)
    func entityNameArrivesWithItsKindInsideItsScope(_ namedEntityCase: NamedEntityCase, options: DemangleOptions) throws {
        let nodeTree = try demangleAsNode(namedEntityCase.mangledName, internsSubtrees: false)
        var storeBuilder = NodeStoreBuilder()
        let rootIndex = try storeBuilder.demangle(namedEntityCase.mangledName)
        let store = storeBuilder.freeze()
        let reference = store.reference(at: rootIndex)

        let nodePathTarget = NodePrinter<IdentifierRecordingTarget>.print(nodeTree, using: options)
        let referencePathTarget = DemanglingPrinter<IdentifierRecordingTarget, NodeReference>.print(reference, options: options)

        // Annotations are all this seam may change.
        #expect(nodePathTarget.text == NodePrinter<String>.print(nodeTree, using: options))
        #expect(referencePathTarget.text == nodePathTarget.text)

        for (representation, target) in [("Node", nodePathTarget), ("NodeReference", referencePathTarget)] {
            let nameWrites = target.identifierWrites.filter { $0.content == namedEntityCase.printedName }
            try #require(!nameWrites.isEmpty, "\(representation): the premise — \(namedEntityCase.printedName) is written as an identifier")
            for nameWrite in nameWrites {
                #expect(
                    nameWrite.parentKind == namedEntityCase.entityKind,
                    "\(representation): \(namedEntityCase.printedName) arrived with parentKind \(nameWrite.parentKind.map { "\($0)" } ?? "nil")"
                )
                if namedEntityCase.isTypeReference {
                    #expect(
                        nameWrite.scopeKind == namedEntityCase.entityKind,
                        "\(representation): \(namedEntityCase.printedName) landed in scope \(nameWrite.scopeKind.map { "\($0)" } ?? "nil")"
                    )
                }
            }
        }
    }

    /// The printer memoizes a node's rendering by its identity — the instance on
    /// the `Node` path, the arena index on the store path, where hash-consing
    /// gives every structurally equal subtree one index. A wrapped name printed
    /// through that cache would replay its first rendering, entity kind
    /// included, wherever the same subtree recurs. Here one `(Shared in _…)`
    /// node names a struct and, under another parent, a protocol.
    @Test func sharedPrivateNameArrivesWithEachEntitysOwnKind() throws {
        func identifier(_ text: String) -> Node {
            Node.createTransient(kind: .identifier, text: text)
        }

        let module = Node.createTransient(kind: .module, text: "Test")
        let sharedPrivateName = Node.createTransient(kind: .privateDeclName, children: [
            identifier("_0123456789ABCDEF0123456789ABCDEF"),
            identifier("Shared"),
        ])
        let structure = Node.createTransient(kind: .structure, children: [module, sharedPrivateName])
        let namespace = Node.createTransient(kind: .enum, children: [module, identifier("Namespace")])
        let protocolNode = Node.createTransient(kind: .protocol, children: [namespace, sharedPrivateName])
        let tuple = Node.createTransient(kind: .type, children: [
            Node.createTransient(kind: .tuple, children: [
                Node.createTransient(kind: .tupleElement, children: [Node.createTransient(kind: .type, children: [structure])]),
                Node.createTransient(kind: .tupleElement, children: [Node.createTransient(kind: .type, children: [protocolNode])]),
            ]),
        ])
        let reference = NodeReference(interning: tuple)

        let nodePathTarget = NodePrinter<IdentifierRecordingTarget>.print(tuple, using: .interfaceTypeBuilderOnly)
        let referencePathTarget = DemanglingPrinter<IdentifierRecordingTarget, NodeReference>.print(reference, options: .interfaceTypeBuilderOnly)

        for (representation, target) in [("Node", nodePathTarget), ("NodeReference", referencePathTarget)] {
            let sharedNameWrites = target.identifierWrites.filter { $0.content == "Shared" }
            #expect(sharedNameWrites.map(\.parentKind) == [.structure, .protocol], "\(representation): \(target.text)")
            #expect(sharedNameWrites.map(\.scopeKind) == [.structure, .protocol], "\(representation): \(target.text)")
        }
    }
}
