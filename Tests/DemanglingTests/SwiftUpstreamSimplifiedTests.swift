import Testing
@testable import Demangling

@Suite("Upstream: simplified-manglings.txt")
struct SwiftUpstreamSimplifiedTests {
    static let cases = UpstreamTestInputLoader.load("simplified-manglings")

    @Test(arguments: cases)
    func simplifiedDemangleMatchesExpected(_ testCase: ManglingCase) throws {
        let node = try demangleAsNode(testCase.input)
        let result = node.print(using: .simplified)
        #expect(
            result == testCase.expected,
            """
            \(testCase)
              got:      \(result)
              expected: \(testCase.expected)
            """
        )
    }
}
