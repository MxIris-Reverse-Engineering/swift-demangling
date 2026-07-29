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

        var count: Int { text.count }

        mutating func write(_ content: String) {
            text.write(content)
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
}
