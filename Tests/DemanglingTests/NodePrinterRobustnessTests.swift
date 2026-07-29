import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Guards two things the printer has to get right that no output-fidelity test
/// covers: state that belongs to one walk rather than to the printer instance,
/// and node shapes that reach the printer without having come from the
/// demangler.
///
/// Both became reachable at the same time. `printRoot(_:)` re-derives the stack
/// budget on every call, which is a statement that reusing a printer is
/// supported; and `NodeStoreBuilder.intern(kind:...)`, `Node.createTransient`
/// and `Node.Rewriter` all hand the printer trees the demangler never built.
@Suite
struct NodePrinterRobustnessTests {
    // MARK: - Reuse

    /// A reused printer must produce exactly what a fresh one would. Only the
    /// stack budget was reset per walk; the output target, the memoized
    /// fragment cache and the "specialized " latch all survived into the next
    /// root.
    @Test func reusedPrinterMatchesFreshPrinters() throws {
        let mangledStrings = [
            "$sSaySiGD",
            "$sSaySSGD",
            "$s4main8MyStructV3fooyyFAA1XV_Tg5",
            "$sSUss17FixedWidthIntegerRzrlEyxqd__cSzRd__lufCSu_SiTg5",
            "$sSiD",
        ]
        let optionSets: [(name: String, options: DemangleOptions)] = [
            ("default", .default),
            ("simplified", .simplified),
        ]
        let trees = try mangledStrings.map { try demangleAsNode($0, internsSubtrees: false) }

        for optionSet in optionSets {
            let expected = trees.map { tree -> String in
                var freshPrinter = NodePrinter<String>(options: optionSet.options)
                return freshPrinter.printRoot(tree)
            }
            var reusedPrinter = NodePrinter<String>(options: optionSet.options)
            let actual = trees.map { reusedPrinter.printRoot($0) }

            #expect(actual == expected, "reused printer diverged with \(optionSet.name) options")
        }
    }

    /// The store path made reuse worse than a stale cache: its cache key is a
    /// per-store node index, so index 0 of one store silently matched index 0
    /// of another and the second symbol printed as the first.
    @Test func reusedStorePrinterKeepsTwoStoresApart() throws {
        var firstBuilder = NodeStoreBuilder()
        let firstRootIndex = try firstBuilder.demangle("$sSaySiGD")
        let firstStore = firstBuilder.freeze()

        var secondBuilder = NodeStoreBuilder()
        let secondRootIndex = try secondBuilder.demangle("$sSaySSGD")
        let secondStore = secondBuilder.freeze()

        var reusedPrinter = DemanglingPrinter<String, NodeReference>(options: .default)
        let firstOutput = reusedPrinter.printRoot(firstStore.reference(at: firstRootIndex))
        let secondOutput = reusedPrinter.printRoot(secondStore.reference(at: secondRootIndex))

        #expect(firstOutput == "Swift.Array<Swift.Int>")
        #expect(secondOutput == "Swift.Array<Swift.String>")
    }

    // MARK: - Node shapes the demangler never produces

    /// `.asyncAwaitResumePartialFunction` and its suspend counterpart were the
    /// only two places in the printer that force-unwrapped a child, and the
    /// option that reaches them is part of `.default`. The demangler always
    /// gives them a child, but a hand-built or rewritten tree need not.
    @Test func printsAsyncResumePartialFunctionWithoutAChild() {
        let awaitNode = Node.create(kind: .asyncAwaitResumePartialFunction)
        let suspendNode = Node.create(kind: .asyncSuspendResumePartialFunction)

        #expect(awaitNode.print(using: .default).contains("await resume partial function for"))
        #expect(suspendNode.print(using: .default).contains("suspend resume partial function for"))
    }

    /// The shape printer read its children at indices 1 and 2 while the
    /// demangler builds them at 0 and 1, so the requirement signature was
    /// printed in the type position and the type itself came out as
    /// `<null node pointer>`. The C++ printer has the same off-by-one; this
    /// port deliberately diverges, because `<null node pointer>` is not usable
    /// output for a tool that displays symbols.
    @Test func printsExtendedExistentialTypeShapeFromItsActualChildren() throws {
        let intType = try #require(demangleAsNode("$sSiD", internsSubtrees: false).first(of: .type))

        let shapeWithoutSignature = Node.create(kind: .extendedExistentialTypeShape, child: intType)
        let printedWithoutSignature = shapeWithoutSignature.print(using: .default)
        #expect(!printedWithoutSignature.contains("<null node pointer>"))
        #expect(printedWithoutSignature == "existential shape for any Swift.Int")

        let genericSignature = try #require(
            demangleAsNode("$sSUss17FixedWidthIntegerRzrlEyxqd__cSzRd__lufCSu_SiTg5", internsSubtrees: false)
                .first(of: .dependentGenericSignature)
        )
        let shapeWithSignature = Node.create(kind: .extendedExistentialTypeShape, children: [genericSignature, intType])
        let printedWithSignature = shapeWithSignature.print(using: .default)
        #expect(!printedWithSignature.contains("<null node pointer>"))
        #expect(printedWithSignature.hasSuffix("Swift.Int"))
    }
}
