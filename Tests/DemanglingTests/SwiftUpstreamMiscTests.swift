import Testing
@testable import Demangling

@Suite("Upstream: standalone cases")
struct SwiftUpstreamMiscTests {
    @Test("demangle-embedded.swift: `$e` prefix with leading `$`")
    func embeddedPrefixWithDollar() throws {
        let input = "$e4main8MyStructV3fooyyFAA1XV_Tg5"
        let expected = "generic specialization <main.X> of main.MyStruct.foo() -> ()"
        let node = try demangleAsNode(input)
        let result = node.print(using: .default.union(.synthesizeSugarOnTypes))
        #expect(result == expected)
    }
}
