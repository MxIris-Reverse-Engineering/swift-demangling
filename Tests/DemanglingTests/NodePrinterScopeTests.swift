import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Guards the type-reference scope seam of `NodePrinterTarget`.
///
/// The engine delivers the nominal reference node to
/// `pushTypeReferenceScope` lazily (autoclosure): rich targets that use
/// scope identity receive the same sequence whether printing a `Node` tree
/// or a store-backed `NodeReference` (which must materialize to service the
/// hook), while scope-ignoring targets (`String`, the default
/// implementation) never evaluate the closure and keep the store's
/// plain-text path materialization-free.
@Suite
struct NodePrinterScopeTests {
    /// A target that mirrors `String`'s writing behavior exactly (so the
    /// print flow is identical) while recording every scope event. Scope
    /// identity is captured as the remangled string of the delivered node,
    /// which is structural — equal across representations exactly when the
    /// delivered subtrees are structurally equal.
    private struct ScopeRecordingTarget: NodePrinterTarget {
        enum ScopeEvent: Equatable, Sendable {
            case push(identity: String?)
            case pop
        }

        var text: String = ""
        var scopeEvents: [ScopeEvent] = []

        init() {}

        var writtenUnitCount: Int { text.utf8.count }

        mutating func write(_ content: String) {
            text.write(content)
        }

        // This target only records scopes, but the requirement carries no
        // default, so it forwards explicitly rather than silently losing the
        // hook to one.
        mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
            write(content)
        }

        mutating func append(_ other: ScopeRecordingTarget) {
            text.append(other.text)
            scopeEvents.append(contentsOf: other.scopeEvents)
        }

        mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {
            let identity = node().flatMap { try? mangleAsString($0) }
            scopeEvents.append(.push(identity: identity))
        }

        mutating func popTypeReferenceScope() {
            scopeEvents.append(.pop)
        }
    }

    @Test func scopeIdentitySequenceMatchesAcrossRepresentations() throws {
        let mangledStrings = [
            "$sSiD",
            "$sSaySiGD",
            "$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC",
            "$s7SwiftUI15ModifiedContentVyxq_GAA0D0AAMc",
            "$sSS7cStringSSSPys4Int8VG_tcfC",
        ]
        for mangled in mangledStrings {
            var storeBuilder = NodeStoreBuilder()
            let rootIndex = try storeBuilder.demangle(mangled)
            let store = storeBuilder.freeze()
            let reference = store.reference(at: rootIndex)

            let nodeTree = try demangleAsNode(mangled, internsSubtrees: false)

            let nodePathTarget = NodePrinter<ScopeRecordingTarget>.print(nodeTree, using: .default)
            let referencePathTarget = DemanglingPrinter<ScopeRecordingTarget, NodeReference>.print(reference, options: .default)

            #expect(referencePathTarget.text == nodePathTarget.text, "print divergence for \(mangled)")
            #expect(referencePathTarget.scopeEvents == nodePathTarget.scopeEvents, "scope divergence for \(mangled)")

            let deliveredIdentityCount = referencePathTarget.scopeEvents.count(where: { scopeEvent in
                if case .push(.some) = scopeEvent { return true }
                return false
            })
            #expect(deliveredIdentityCount > 0, "expected at least one nominal reference scope in \(mangled)")
        }
    }

    /// Records which scope each written run of text landed in, which the
    /// event-sequence target above cannot see: it compares two representations
    /// against each other, so an attribution that is wrong the same way on both
    /// sides passes.
    private struct ScopeAttributionTarget: NodePrinterTarget {
        struct WrittenRun: Equatable, Sendable {
            var content: String
            var scopeIdentity: String?
        }

        var runs: [WrittenRun] = []
        private var scopeStack: [String?] = []

        init() {}

        // Run count, not character count: the probe only needs a value that
        // every non-empty write changes.
        var writtenUnitCount: Int { runs.count }

        mutating func write(_ content: String) {
            runs.append(WrittenRun(content: content, scopeIdentity: scopeStack.last ?? nil))
        }

        mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
            write(content)
        }

        mutating func append(_ other: ScopeAttributionTarget) {
            runs.append(contentsOf: other.runs)
        }

        mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {
            scopeStack.append(node().map { $0.kind.description })
        }

        mutating func popTypeReferenceScope() {
            _ = scopeStack.popLast()
        }
    }

    /// The `" in "` / `" of "` separators between an entity and its postfix
    /// context are written while the enclosing nominal's dispatch scope is
    /// still open, so without a barrier they inherit that nominal's type
    /// reference. A rich target turning scopes into clickable spans then made
    /// the word "in" navigate to the type — while the type's own name, printed
    /// through a nested `printName` into a sub-target whose scope stack is
    /// empty, navigated nowhere.
    ///
    /// This pins the barrier. The sub-target half — fragment contents never see
    /// the enclosing scope, because `printCache` and the scope stack do not
    /// compose — is structural and tracked separately.
    @Test func contextSeparatorsCarryNoTypeReferenceScope() throws {
        let localStructMethod = try demangleAsNode(
            "_$s9localtest5outeryyF11LocalStructL_V6methodyyF",
            internsSubtrees: false
        )
        let target = NodePrinter<ScopeAttributionTarget>.print(localStructMethod, using: .default)

        let separatorRuns = target.runs.filter { $0.content == " in " || $0.content == " of " }
        try #require(!separatorRuns.isEmpty, "the premise: this symbol prints a postfix-context separator")
        for separatorRun in separatorRuns {
            #expect(separatorRun.scopeIdentity == nil, """
                the separator "\(separatorRun.content)" was attributed to scope \
                \(separatorRun.scopeIdentity ?? "nil") — it belongs to no type reference
                """)
        }
    }

    /// `.otherNominalType` took the identical
    /// `printEntity(..., typePrinting: .noType, hasName: true)` call as the
    /// nominal group but sat on its own arm of the dispatch switch, so it never
    /// pushed a type-reference scope. The text it emits is byte-identical
    /// either way, which is why no text-comparison test could see it — and it
    /// reaches the printer from real mangled input, via the `Y` operator.
    @Test func otherNominalTypeGetsTheSameScopeAsOtherNominals() throws {
        func nominal(_ kind: Node.Kind) -> Node {
            Node.createTransient(kind: .type, children: [
                Node.createTransient(kind: kind, children: [
                    Node.createTransient(kind: .module, text: "Swift"),
                    Node.createTransient(kind: .identifier, text: "Thing"),
                ]),
            ])
        }

        func scopePushCount(_ node: Node) -> Int {
            NodePrinter<ScopeRecordingTarget>.print(node, using: .default).scopeEvents.count { scopeEvent in
                if case .push(.some) = scopeEvent { return true }
                return false
            }
        }

        let structureNode = nominal(.structure)
        let otherNominalNode = nominal(.otherNominalType)

        // The premise that makes this invisible to text comparison.
        #expect(
            NodePrinter<String>.print(structureNode, using: .default)
                == NodePrinter<String>.print(otherNominalNode, using: .default)
        )
        #expect(scopePushCount(structureNode) == 1, "the control: a structure nominal pushes one scope")
        #expect(scopePushCount(otherNominalNode) == 1, "`.otherNominalType` must push the same scope")
    }
}
