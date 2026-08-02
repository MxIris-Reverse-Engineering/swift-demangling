import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Guards two things the printer has to get right that no output-fidelity test
/// covers: state that belongs to one walk rather than to the printer instance,
/// and node shapes that reach the printer without having come from the
/// demangler.
///
/// Both are real: `printRoot(_:)` resets every piece of walk state so the
/// engine can be reused (the public static `print` builds a fresh engine per
/// call, but the internal walk must not rely on that); and
/// `NodeStoreBuilder.intern(kind:...)`, `Node.createTransient` and
/// `Node.Rewriter` all hand the printer trees the demangler never built.
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
                var freshPrinter = DemanglingPrinter<String, Node>(options: optionSet.options)
                return freshPrinter.printRoot(tree)
            }
            var reusedPrinter = DemanglingPrinter<String, Node>(options: optionSet.options)
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

    /// `printExtendedExistentialTypeShape` reads its children at 1 and 2 while
    /// the demangler builds them at 0 and 1, so the type position always comes
    /// out as `<null node pointer>`. That off-by-one is upstream's, and this
    /// port keeps it: reproducing `swift demangle` byte for byte outranks
    /// producing nicer output, because a consumer diffing against the toolchain
    /// must see what the toolchain sees.
    ///
    /// This test exists to make the divergence loud if anyone "fixes" the
    /// indices to 0 and 1 — which has been proposed in review and rejected
    /// (`Documentations/KnownIssues.md`, adjudicated non-defects). It pins
    /// upstream's behavior, not desirable behavior.
    @Test func printsExtendedExistentialTypeShapeTheWayUpstreamDoes() throws {
        let intType = try #require(demangleAsNode("$sSiD", internsSubtrees: false).first(of: .type))

        // One child: the printer reads index 1, which does not exist.
        let shapeWithoutSignature = Node.create(kind: .extendedExistentialTypeShape, child: intType)
        #expect(
            shapeWithoutSignature.print(using: .default) == "existential shape for any <null node pointer>",
            "the one-child shape must match upstream's output, null pointer included"
        )

        // Two children: the printer reads 1 (the type, printed in the
        // signature position) and 2 (absent).
        let genericSignature = try #require(
            demangleAsNode("$sSUss17FixedWidthIntegerRzrlEyxqd__cSzRd__lufCSu_SiTg5", internsSubtrees: false)
                .first(of: .dependentGenericSignature)
        )
        let shapeWithSignature = Node.create(kind: .extendedExistentialTypeShape, children: [genericSignature, intType])
        #expect(
            shapeWithSignature.print(using: .default) == "existential shape for Swift.Int any <null node pointer>",
            "the two-child shape must match upstream's output, null pointer included"
        )
    }
}
