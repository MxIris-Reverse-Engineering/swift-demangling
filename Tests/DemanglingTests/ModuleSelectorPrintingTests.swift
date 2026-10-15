import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// `DemangleOptions.useModuleSelectors` spells qualified names with SE-0491
/// module selectors, following the rules the Swift 6.4 compiler applies when
/// it writes a `.swiftinterface` (evolution proposal `module-selectors`).
///
/// The expected spellings with selectors are the compiler's own, taken from
/// the Xcode 27 SDK interfaces where a declaration appears there
/// (`Swift::Duration.Foundation::TimeFormatStyle`, `Builtin::RawPointer`,
/// `~Swift::Copyable`, `Swift::AnyObject`); the rest apply the same rules. The
/// spelling without the option is pinned beside each one, so a case also
/// proves the option changes nothing but the qualification.
@Suite
struct ModuleSelectorPrintingTests {
    struct SpellingCase: Sendable, CustomTestStringConvertible {
        let summary: String
        let mangledName: String
        let options: DemangleOptions
        let spellingWithoutSelectors: String
        let spellingWithSelectors: String

        var testDescription: String { summary }
    }

    static let spellingCases: [SpellingCase] = [
        SpellingCase(
            summary: "a top-level type",
            mangledName: "$sSiD",
            options: .default,
            spellingWithoutSelectors: "Swift.Int",
            spellingWithSelectors: "Swift::Int"
        ),
        SpellingCase(
            summary: "a type nested in a generic type carries a selector of its own",
            mangledName: "$sSD5IndexVySSSi_GD",
            options: .default,
            spellingWithoutSelectors: "Swift.Dictionary<Swift.String, Swift.Int>.Index",
            spellingWithSelectors: "Swift::Dictionary<Swift::String, Swift::Int>.Swift::Index"
        ),
        SpellingCase(
            summary: "every level of a nested type in the same module",
            mangledName: "$s4main3FooV3BarV3BazCD",
            options: .default,
            spellingWithoutSelectors: "main.Foo.Bar.Baz",
            spellingWithSelectors: "main::Foo.main::Bar.main::Baz"
        ),
        SpellingCase(
            summary: "a nested type an extension in another module declares names that module",
            mangledName: "$ss8DurationV10FoundationE15TimeFormatStyleVD",
            options: .interface,
            spellingWithoutSelectors: "Swift.Duration.TimeFormatStyle",
            spellingWithSelectors: "Swift::Duration.Foundation::TimeFormatStyle"
        ),
        SpellingCase(
            summary: "the debug extension prefix stays beside the selectors",
            mangledName: "$ss8DurationV10FoundationE15TimeFormatStyleVD",
            options: .default,
            spellingWithoutSelectors: "(extension in Foundation):Swift.Duration.TimeFormatStyle",
            spellingWithSelectors: "(extension in Foundation):Swift::Duration.Foundation::TimeFormatStyle"
        ),
        SpellingCase(
            summary: "a hidden module gets no selector while a shown one keeps its own",
            mangledName: "$ss8DurationV10FoundationE15TimeFormatStyleVD",
            options: DemangleOptions.interface.subtracting(.displayStdlibModule),
            spellingWithoutSelectors: "Duration.TimeFormatStyle",
            spellingWithSelectors: "Duration.Foundation::TimeFormatStyle"
        ),
        SpellingCase(
            summary: "no module names means no selectors",
            mangledName: "$ss8DurationV10FoundationE15TimeFormatStyleVD",
            options: .simplified,
            spellingWithoutSelectors: "Duration.TimeFormatStyle",
            spellingWithSelectors: "Duration.TimeFormatStyle"
        ),
        SpellingCase(
            summary: "a function and the types in its signature",
            mangledName: "$ss5print_9separator10terminatoryypd_S2StF",
            options: .default,
            spellingWithoutSelectors: "Swift.print(_: Any..., separator: Swift.String, terminator: Swift.String) -> ()",
            spellingWithSelectors: "Swift::print(_: Any..., separator: Swift::String, terminator: Swift::String) -> ()"
        ),
        SpellingCase(
            summary: "a member is qualified through its type, without a selector of its own",
            mangledName: "$sSTsE7reverseSay7ElementQzGyF",
            options: .default,
            spellingWithoutSelectors: "(extension in Swift):Swift.Sequence.reverse() -> Swift.Array<A.Element>",
            spellingWithSelectors: "(extension in Swift):Swift::Sequence.reverse() -> Swift::Array<A.Element>"
        ),
        SpellingCase(
            summary: "a local type gets no selector, its enclosing function does",
            mangledName: "$s4main3fooyyF3BarL_VD",
            options: .default,
            spellingWithoutSelectors: "Bar #1 in main.foo() -> ()",
            spellingWithSelectors: "Bar #1 in main::foo() -> ()"
        ),
        SpellingCase(
            summary: "a builtin type",
            mangledName: "$sBpD",
            options: .default,
            spellingWithoutSelectors: "Builtin.RawPointer",
            spellingWithSelectors: "Builtin::RawPointer"
        ),
        SpellingCase(
            summary: "AnyObject in a composition",
            mangledName: "$ss5Error_XlD",
            options: .default,
            spellingWithoutSelectors: "Swift.Error & Swift.AnyObject",
            spellingWithSelectors: "Swift::Error & Swift::AnyObject"
        ),
        SpellingCase(
            summary: "a suppressed conformance",
            mangledName: "$s4main1fyyxRi_zlF",
            options: .default,
            spellingWithoutSelectors: "main.f<A where A: ~Swift.Copyable>(A) -> ()",
            spellingWithSelectors: "main::f<A where A: ~Swift::Copyable>(A) -> ()"
        ),
    ]

    @Test(arguments: spellingCases)
    func optionSpellsQualifiedNamesWithModuleSelectors(_ spellingCase: SpellingCase) throws {
        let node = try demangleAsNode(spellingCase.mangledName)
        #expect(node.print(using: spellingCase.options) == spellingCase.spellingWithoutSelectors)
        #expect(node.print(using: spellingCase.options.union(.useModuleSelectors)) == spellingCase.spellingWithSelectors)
    }

    @Test(arguments: spellingCases)
    func storeBackedPrintingSpellsTheSameSelectors(_ spellingCase: SpellingCase) throws {
        let node = try demangleAsNode(spellingCase.mangledName)
        let reference = NodeReference(interning: node)
        #expect(reference.print(using: spellingCase.options.union(.useModuleSelectors)) == spellingCase.spellingWithSelectors)
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

    /// A rich target colors and links module names by the write's state, so a
    /// nested type's selector has to reach it as a module name inside that
    /// type's own reference scope — the way the top-level module does.
    @Test func nestedSelectorReachesARichTargetAsAModuleName() throws {
        let node = try demangleAsNode("$ss8DurationV10FoundationE15TimeFormatStyleVD")
        let target = NodePrinter<ModuleWriteRecordingTarget>.print(node, using: DemangleOptions.interface.union(.useModuleSelectors))
        #expect(target.text == "Swift::Duration.Foundation::TimeFormatStyle")
        #expect(target.moduleWrites == [
            .init(moduleName: "Swift", scopeKind: .structure),
            .init(moduleName: "Foundation", scopeKind: .structure),
        ])
    }
}
