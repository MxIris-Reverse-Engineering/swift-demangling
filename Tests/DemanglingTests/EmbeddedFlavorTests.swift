import Testing
@testable import Demangling

@Suite("Embedded flavor detection")
struct EmbeddedFlavorTests {
    @Test("$e prefix sets flavor to .embedded")
    func dollarEPrefixSetsEmbeddedFlavor() throws {
        var demangler = Demangler(scalars: "$e4main4testyyF".unicodeScalars)
        _ = try demangler.demangleSymbol()
        #expect(demangler.flavor == .embedded)
    }

    @Test("_$e prefix sets flavor to .embedded")
    func underscoreDollarEPrefixSetsEmbeddedFlavor() throws {
        var demangler = Demangler(scalars: "_$e4main4testyyF".unicodeScalars)
        _ = try demangler.demangleSymbol()
        #expect(demangler.flavor == .embedded)
    }

    @Test("$s prefix keeps flavor at .default")
    func dollarSPrefixKeepsDefaultFlavor() throws {
        var demangler = Demangler(scalars: "$s4main4testyyF".unicodeScalars)
        _ = try demangler.demangleSymbol()
        #expect(demangler.flavor == .default)
    }
}
