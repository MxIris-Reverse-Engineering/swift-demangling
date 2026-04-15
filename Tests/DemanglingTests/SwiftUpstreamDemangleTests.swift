import Testing
@testable import Demangling

@Suite("Upstream: manglings.txt")
struct SwiftUpstreamDemangleTests {
    static let cases = UpstreamTestInputLoader.load("manglings")

    @Test(arguments: cases)
    func demangleMatchesExpected(_ testCase: ManglingCase) throws {
        let node = try demangleAsNode(testCase.input)
        let result = node.print(using: .default.union(.synthesizeSugarOnTypes))
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

@Suite("Upstream: manglings-with-clang-types.txt")
struct SwiftUpstreamClangTypesTests {
    static let cases = UpstreamTestInputLoader.load("manglings-with-clang-types")

    @Test(arguments: cases)
    func demangleMatchesExpected(_ testCase: ManglingCase) throws {
        let node = try demangleAsNode(testCase.input)
        let result = node.print(using: .default.union(.synthesizeSugarOnTypes))
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
