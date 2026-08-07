import Testing
@testable import Demangling

@Suite("Embedded flavor detection")
struct EmbeddedFlavorTests {
    /// The demangler is `~Escapable` over the input bytes, so the whole run —
    /// construction, demangle, flavor read — happens inside the `withUTF8`
    /// borrow scope; only the flavor escapes.
    private static func flavorAfterDemangling(_ mangled: String) throws -> ManglingFlavor {
        var utf8Copy = mangled
        let outcome = utf8Copy.withUTF8 { buffer in
            Result { () throws(DemanglingError) -> ManglingFlavor in
                var demangler = Demangler<ArrayWordRanges>(bytes: buffer.span, materialization: .decoding)
                _ = try demangler.demangleSymbol()
                return demangler.flavor
            }
        }
        return try outcome.get()
    }

    @Test("$e prefix sets flavor to .embedded")
    func dollarEPrefixSetsEmbeddedFlavor() throws {
        #expect(try Self.flavorAfterDemangling("$e4main4testyyF") == .embedded)
    }

    @Test("_$e prefix sets flavor to .embedded")
    func underscoreDollarEPrefixSetsEmbeddedFlavor() throws {
        #expect(try Self.flavorAfterDemangling("_$e4main4testyyF") == .embedded)
    }

    @Test("$s prefix keeps flavor at .default")
    func dollarSPrefixKeepsDefaultFlavor() throws {
        #expect(try Self.flavorAfterDemangling("$s4main4testyyF") == .default)
    }
}
