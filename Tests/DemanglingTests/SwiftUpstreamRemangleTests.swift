import Testing
@testable import Demangling

@Suite("Upstream: remangle roundtrip on manglings.txt")
struct SwiftUpstreamRemangleTests {
    /// The ported Remangler only emits new-form `$s` mangling. Skip V1 (`_T` / `_T0`) inputs
    /// that this port intentionally does not re-mangle.
    static let cases: [ManglingCase] = UpstreamTestInputLoader
        .load("manglings")
        .filter { testCase in
            let input = testCase.input
            return input.hasPrefix("$s")
                || input.hasPrefix("$S")
                || input.hasPrefix("_$s")
                || input.hasPrefix("_$S")
        }

    @Test(arguments: cases)
    func remangleMatchesInput(_ testCase: ManglingCase) throws {
        let node = try demangleAsNode(testCase.input)
        guard canMangle(node) else {
            Issue.record("canMangle == false for \(testCase)")
            return
        }
        let remangled = try mangleAsString(node)
        let expected = Self.canonicalize(testCase.input)
        #expect(
            remangled == expected,
            """
            \(testCase)
              remangled: \(remangled)
              expected:  \(expected)
            """
        )
    }

    /// Normalize an upstream input into the form the ported Remangler actually emits:
    ///   1. Upstream `$S` (capital) is lowercased to `$s` because the new-mangling Remangler
    ///      only emits the lowercase form.
    ///   2. The ported Remangler always prepends an underscore (`_$s`), whereas `swift-demangle`
    ///      emits a bare `$s`. Force the expected form to match the porter's current output.
    static func canonicalize(_ input: String) -> String {
        var stripped = input
        if stripped.hasPrefix("_") {
            stripped.removeFirst()
        }
        if stripped.hasPrefix("$S") {
            stripped = "$s" + stripped.dropFirst(2)
        }
        return "_" + stripped
    }
}
