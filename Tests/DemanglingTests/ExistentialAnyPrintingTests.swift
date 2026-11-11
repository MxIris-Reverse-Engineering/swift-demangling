import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// `DemangleOptions.useExistentialAny` spells existential types with the `any`
/// keyword, following the rules the compiler applies when it writes a
/// `.swiftinterface` (evolution proposal `existential-any`).
///
/// The expected spellings with the keyword are the compiler's own
/// (`ExistentialType::get`, `TypePrinter::visitAnyMetatypeType`,
/// `isSimpleUnderPrintOptions`); `any Any.Type` and `(any Swift::Error)?` are
/// how the macOS 27.2 SDK's Foundation interface spells them. The spelling
/// without the option is pinned beside each one, so a case also proves the
/// option changes nothing but the keyword and the parentheses it needs.
@Suite
struct ExistentialAnyPrintingTests {
    struct SpellingCase: Sendable, CustomTestStringConvertible {
        let summary: String
        let mangledName: String
        let options: DemangleOptions
        let spellingWithoutKeyword: String
        let spellingWithKeyword: String

        var testDescription: String { summary }
    }

    static let spellingCases: [SpellingCase] = [
        SpellingCase(
            summary: "a single protocol",
            mangledName: "$s4main1P_pD",
            options: .default,
            spellingWithoutKeyword: "main.P",
            spellingWithKeyword: "any main.P"
        ),
        SpellingCase(
            summary: "a composition writes one keyword",
            mangledName: "$s4main1P_AA1QpD",
            options: .default,
            spellingWithoutKeyword: "main.P & main.Q",
            spellingWithKeyword: "any main.P & main.Q"
        ),
        SpellingCase(
            summary: "a protocol with associated types",
            mangledName: "$sSl_pD",
            options: .default,
            spellingWithoutKeyword: "Swift.Collection",
            spellingWithKeyword: "any Swift.Collection"
        ),
        SpellingCase(
            summary: "Any stays bare",
            mangledName: "$sypD",
            options: .default,
            spellingWithoutKeyword: "Any",
            spellingWithKeyword: "Any"
        ),
        SpellingCase(
            summary: "AnyObject stays bare",
            mangledName: "$syXlD",
            options: .default,
            spellingWithoutKeyword: "Swift.AnyObject",
            spellingWithKeyword: "Swift.AnyObject"
        ),
        SpellingCase(
            summary: "a composition with AnyObject",
            mangledName: "$s4main1P_XlD",
            options: .default,
            spellingWithoutKeyword: "main.P & Swift.AnyObject",
            spellingWithKeyword: "any main.P & Swift.AnyObject"
        ),
        SpellingCase(
            summary: "a composition with a superclass",
            mangledName: "$s4main1P_AA1CCXcD",
            options: .default,
            spellingWithoutKeyword: "main.C & main.P",
            spellingWithKeyword: "any main.C & main.P"
        ),
        SpellingCase(
            summary: "an optional existential is parenthesized",
            mangledName: "$ss5Error_pSgD",
            options: .default,
            spellingWithoutKeyword: "Swift.Error?",
            spellingWithKeyword: "(any Swift.Error)?"
        ),
        SpellingCase(
            summary: "an optional composition",
            mangledName: "$s4main1P_AA1QpSgD",
            options: .default,
            spellingWithoutKeyword: "(main.P & main.Q)?",
            spellingWithKeyword: "(any main.P & main.Q)?"
        ),
        SpellingCase(
            summary: "an optional synthesized from Optional<…>",
            mangledName: "$sSqy4main1P_pGD",
            options: .interface,
            spellingWithoutKeyword: "main.P?",
            spellingWithKeyword: "(any main.P)?"
        ),
        SpellingCase(
            summary: "an optional of Any stays unparenthesized",
            mangledName: "$sypSgD",
            options: .default,
            spellingWithoutKeyword: "Any?",
            spellingWithKeyword: "Any?"
        ),
        SpellingCase(
            summary: "an existential metatype",
            mangledName: "$s4main1P_pXpD",
            options: .default,
            spellingWithoutKeyword: "main.P.Type",
            spellingWithKeyword: "any main.P.Type"
        ),
        SpellingCase(
            summary: "an existential metatype of a composition parenthesizes it",
            mangledName: "$s4main1P_AA1QpXpD",
            options: .default,
            spellingWithoutKeyword: "main.P & main.Q.Type",
            spellingWithKeyword: "any (main.P & main.Q).Type"
        ),
        SpellingCase(
            summary: "the existential metatype of Any gets the keyword",
            mangledName: "$sypXpD",
            options: .default,
            spellingWithoutKeyword: "Any.Type",
            spellingWithKeyword: "any Any.Type"
        ),
        SpellingCase(
            summary: "the existential metatype of AnyObject gets the keyword",
            mangledName: "$syXlXpD",
            options: .default,
            spellingWithoutKeyword: "Swift.AnyObject.Type",
            spellingWithKeyword: "any Swift.AnyObject.Type"
        ),
        SpellingCase(
            summary: "an optional existential metatype is parenthesized",
            mangledName: "$s4main1P_pXpSgD",
            options: .default,
            spellingWithoutKeyword: "main.P.Type?",
            spellingWithKeyword: "(any main.P.Type)?"
        ),
        SpellingCase(
            summary: "an existential metatype of an existential metatype writes one keyword",
            mangledName: "$s4main1P_pXpXpD",
            options: .default,
            spellingWithoutKeyword: "main.P.Type.Type",
            spellingWithKeyword: "any main.P.Type.Type"
        ),
        SpellingCase(
            summary: "the metatype of an existential",
            mangledName: "$s4main1P_pmD",
            options: .default,
            spellingWithoutKeyword: "main.P.Protocol",
            spellingWithKeyword: "(any main.P).Type"
        ),
        SpellingCase(
            summary: "the metatype of Any gets the keyword",
            mangledName: "$sypmD",
            options: .default,
            spellingWithoutKeyword: "Any.Protocol",
            spellingWithKeyword: "(any Any).Type"
        ),
        SpellingCase(
            summary: "the metatype of AnyObject gets the keyword",
            mangledName: "$syXlmD",
            options: .default,
            spellingWithoutKeyword: "Swift.AnyObject.Protocol",
            spellingWithKeyword: "(any Swift.AnyObject).Type"
        ),
        SpellingCase(
            summary: "the metatype of an existential metatype",
            mangledName: "$s4main1P_pXpmD",
            options: .default,
            spellingWithoutKeyword: "main.P.Type.Protocol",
            spellingWithKeyword: "(any main.P.Type).Type"
        ),
        SpellingCase(
            summary: "a parameterized existential keeps its one keyword",
            mangledName: "$sSl_pSi7ElementRts_XPD",
            options: .default,
            spellingWithoutKeyword: "any Swift.Collection<Self.Element == Swift.Int>",
            spellingWithKeyword: "any Swift.Collection<Self.Element == Swift.Int>"
        ),
        SpellingCase(
            summary: "the existential metatype of a parameterized existential writes one keyword",
            mangledName: "$sSl_pSi7ElementRts_XPXpD",
            options: .default,
            spellingWithoutKeyword: "any Swift.Collection<Self.Element == Swift.Int>.Type",
            spellingWithKeyword: "any Swift.Collection<Self.Element == Swift.Int>.Type"
        ),
        SpellingCase(
            summary: "an optional parameterized existential",
            mangledName: "$sSl_pSi7ElementRts_XPSgD",
            options: .default,
            spellingWithoutKeyword: "(any Swift.Collection<Self.Element == Swift.Int>)?",
            spellingWithKeyword: "(any Swift.Collection<Self.Element == Swift.Int>)?"
        ),
        SpellingCase(
            summary: "the metatype of a parameterized existential",
            mangledName: "$sSl_pSi7ElementRts_XPmD",
            options: .default,
            spellingWithoutKeyword: "(any Swift.Collection<Self.Element == Swift.Int>).Type",
            spellingWithKeyword: "(any Swift.Collection<Self.Element == Swift.Int>).Type"
        ),
        SpellingCase(
            summary: "a parameter",
            mangledName: "$s4main3fooyyAA1P_pF",
            options: .default,
            spellingWithoutKeyword: "main.foo(main.P) -> ()",
            spellingWithKeyword: "main.foo(any main.P) -> ()"
        ),
        SpellingCase(
            summary: "an inout parameter",
            mangledName: "$s4main3fooyyAA1P_pzF",
            options: .default,
            spellingWithoutKeyword: "main.foo(inout main.P) -> ()",
            spellingWithKeyword: "main.foo(inout any main.P) -> ()"
        ),
        SpellingCase(
            summary: "the same existential alone, then under a metatype",
            mangledName: "$s4main1P_p_AA1P_pXptD",
            options: .default,
            spellingWithoutKeyword: "(main.P, main.P.Type)",
            spellingWithKeyword: "(any main.P, any main.P.Type)"
        ),
        SpellingCase(
            summary: "the same existential under a metatype, then alone",
            mangledName: "$s4main1P_pXp_AA1P_ptD",
            options: .default,
            spellingWithoutKeyword: "(main.P.Type, main.P)",
            spellingWithKeyword: "(any main.P.Type, any main.P)"
        ),
        SpellingCase(
            summary: "a print without module names",
            mangledName: "$ss5Error_pSgD",
            options: .simplified,
            spellingWithoutKeyword: "Error?",
            spellingWithKeyword: "(any Error)?"
        ),
    ]

    @Test(arguments: spellingCases)
    func optionSpellsExistentialsWithAny(_ spellingCase: SpellingCase) throws {
        let node = try demangleAsNode(spellingCase.mangledName)
        #expect(node.print(using: spellingCase.options) == spellingCase.spellingWithoutKeyword)
        #expect(node.print(using: spellingCase.options.union(.useExistentialAny)) == spellingCase.spellingWithKeyword)
    }

    @Test(arguments: spellingCases)
    func storeBackedPrintingSpellsTheSameKeyword(_ spellingCase: SpellingCase) throws {
        let node = try demangleAsNode(spellingCase.mangledName)
        let reference = NodeReference(interning: node)
        #expect(reference.print(using: spellingCase.options) == spellingCase.spellingWithoutKeyword)
        #expect(reference.print(using: spellingCase.options.union(.useExistentialAny)) == spellingCase.spellingWithKeyword)
    }

    @Test func keywordFollowsModuleSelectors() throws {
        let node = try demangleAsNode("$s4main1P_XlD")
        #expect(node.print(using: DemangleOptions.default.union([.useModuleSelectors, .useExistentialAny])) == "any main::P & Swift::AnyObject")
    }

    /// The fragment cache is keyed by node identity, and an existential prints
    /// with the keyword in one position and bare under an existential
    /// metatype's keyword. A tree whose two tuple elements hold the same
    /// protocol-list instance must not replay one spelling at the other
    /// position — in either order.
    @Test func sharedExistentialPrintsItsOwnSpellingInEachPosition() throws {
        let existentialType = try #require(try demangleAsNode("$s4main1P_pD").children.first?.children.first)
        #expect(existentialType.kind == .type)
        let existentialMetatype = Node.create(kind: .type, child: Node.create(kind: .existentialMetatype, child: existentialType))
        let existentialFirst = Node.create(kind: .tuple, children: [
            Node.create(kind: .tupleElement, child: existentialType),
            Node.create(kind: .tupleElement, child: existentialMetatype),
        ])
        let metatypeFirst = Node.create(kind: .tuple, children: [
            Node.create(kind: .tupleElement, child: existentialMetatype),
            Node.create(kind: .tupleElement, child: existentialType),
        ])
        let options = DemangleOptions.default.union(.useExistentialAny)
        #expect(existentialFirst.print(using: options) == "(any main.P, any main.P.Type)")
        #expect(metatypeFirst.print(using: options) == "(any main.P.Type, any main.P)")
    }

    /// Writes text exactly like `String` and records each module-name write
    /// with the kind of the type-reference scope it landed in.
    private struct ModuleWriteRecordingTarget: NodePrinterTarget {
        struct ModuleWrite: Equatable, Sendable {
            var moduleName: String
            /// The kind of the innermost open type-reference scope; `nil` for
            /// no scope or a barrier.
            var scopeKind: Node.Kind?
        }

        var text: String = ""
        var moduleWrites: [ModuleWrite] = []
        private var scopeKinds: [Node.Kind?] = []

        init() {}

        var writtenUnitCount: Int { text.utf8.count }

        mutating func write(_ content: String) {
            text.write(content)
        }

        mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
            text.write(content)
            guard let context = context(), context.state == .printModule else { return }
            moduleWrites.append(ModuleWrite(moduleName: content, scopeKind: scopeKinds.last ?? nil))
        }

        mutating func append(_ other: ModuleWriteRecordingTarget) {
            text.append(other.text)
            moduleWrites.append(contentsOf: other.moduleWrites)
        }

        mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {
            scopeKinds.append(node()?.kind)
        }

        mutating func popTypeReferenceScope() {
            _ = scopeKinds.popLast()
        }
    }

    /// The protocols of an existential printed bare under a metatype's keyword
    /// are still printed as protocol references: a rich target sees each one
    /// inside its own type-reference scope, as it does at the top level.
    @Test func bareCompositionKeepsEachProtocolsReferenceScope() throws {
        let node = try demangleAsNode("$s4main1P_AA1QpXpD")
        let target = NodePrinter<ModuleWriteRecordingTarget>.print(node, using: DemangleOptions.default.union(.useExistentialAny))
        #expect(target.text == "any (main.P & main.Q).Type")
        #expect(target.moduleWrites == [
            .init(moduleName: "main", scopeKind: .protocol),
            .init(moduleName: "main", scopeKind: .protocol),
        ])
    }
}
