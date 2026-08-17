import Testing
@testable import Demangling

/// The rich-target example from `README.md`, compiled.
///
/// It is the only worked example for `NodePrinterTarget`, and both of that
/// protocol's rich hooks ship without default implementations specifically so
/// that a near-miss is a compile error rather than a silent no-op — which
/// makes an example that does not compile worse than no example: the reader
/// cannot tell the difference until they paste it in.
///
/// It had already drifted twice inside one PR. `5cc30c9` added the example
/// with a `var count: Int` member; `77cf984` renamed the requirement to
/// `writtenUnitCount` — precisely because grapheme `count` was the bug — and
/// did not update the README, so `HighlightedTarget` stopped conforming.
/// Separately, `NodePrintState` was not `Sendable` across the module boundary
/// (implicit inference does not export for `public` types), so the documented
/// pattern of storing the delivered state could not be written downstream at
/// all under strict concurrency, while every in-module test compiled fine.
///
/// Keeping the example as real code is the only guard that survives a rename:
/// prose is invisible to the compiler, and no output-comparison test can see
/// a target that fails to conform. **When this file changes, change
/// `README.md` in the same commit.**
@Suite
struct ReadmeExampleTests {
    // MARK: - Verbatim from README.md, "Custom Print Targets"

    struct HighlightedTarget: NodePrinterTarget {
        /// Every printed fragment with the semantic state it came from.
        private(set) var fragments: [(text: String, state: NodePrintState?)] = []
        /// The type reference the current writes belong to (innermost wins).
        private var typeReferenceScopes: [Node?] = []

        /// UTF-8 bytes, not `String.count`: the printer uses this purely as a
        /// delta probe to decide whether a nested print emitted anything, so the
        /// one contract is that any non-empty write must change it. Appending a
        /// combining mark leaves `String.count` untouched and would silently drop
        /// a qualified-name separator.
        var writtenUnitCount: Int { fragments.reduce(0) { $0 + $1.text.utf8.count } }

        init() {}

        mutating func write(_ content: String) {
            fragments.append((content, nil))
        }

        // Note `@autoclosure`: the context is built lazily, so a target that
        // ignores it never pays for it. This requirement has no default
        // implementation — an eager `context: NodePrintContext?` parameter is a
        // near-miss that fails to compile instead of silently doing nothing.
        mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
            // context()?.state is .printIdentifier, .printKeyword, .printType, …
            // and context()?.parentKind gives the enclosing node kind.
            fragments.append((content, context()?.state))
        }

        // Required so the printer can splice memoized fragments into the output
        // without dropping the annotations they carry.
        mutating func append(_ other: Self) {
            fragments.append(contentsOf: other.fragments)
        }

        // Also defaultless, for the same near-miss reason as write(_:context:).
        mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {
            typeReferenceScopes.append(node())
        }

        mutating func popTypeReferenceScope() {
            typeReferenceScopes.removeLast()
        }
    }

    // MARK: - Behaviour the example promises

    /// The example compiles (that is most of the point) and actually produces
    /// the annotated fragments its comments advertise, rather than a target
    /// whose hooks were quietly absorbed by a default.
    @Test func readmeRichTargetCollectsAnnotatedFragments() throws {
        let node = try demangleAsNode("$s4main3fooyyF")

        let highlighted = NodePrinter<HighlightedTarget>.print(node, using: .default)

        // Same text as the plain-text target, assembled from the fragments.
        #expect(highlighted.fragments.map(\.text).joined() == node.print(using: .default))
        // The hooks really ran: at least one fragment carries a state, and the
        // identifier is among them. A no-op default would leave every state nil
        // while the joined text stayed byte-identical — the exact failure the
        // defaultless requirements exist to prevent.
        #expect(highlighted.fragments.contains { $0.state != nil })
        #expect(highlighted.fragments.contains { $0.text == "foo" && $0.state == .printIdentifier })
        #expect(highlighted.writtenUnitCount == node.print(using: .default).utf8.count)
    }

}

/// `NodePrintState` must carry an *explicit* `Sendable` conformance, because
/// `HighlightedTarget` above stores it and `NodePrinterTarget` refines
/// `Sendable`.
///
/// This is a compile-time check, not a runtime one: implicit `Sendable`
/// inference for a `public` type does not cross the module boundary, and this
/// test target is a separate module — `@testable import` raises visibility,
/// it does not change conformance inference. So this line fails to compile if
/// the conformance is ever dropped, which is exactly when the downstream
/// breakage would otherwise appear.
private func requiresSendableConformance<Value: Sendable>(_: Value.Type) {}
private let nodePrintStateIsSendable: Void = requiresSendableConformance(NodePrintState.self)
