import Testing
@testable import Demangling

@Suite("Embedded flavor detection")
struct EmbeddedFlavorTests {
    /// The demangler is `~Escapable` over the input bytes, so the whole run —
    /// construction, demangle, flavor read — happens inside the `withUTF8`
    /// borrow scope; only the flavor escapes.
    ///
    /// Both word-table configurations are exercised on a modern runtime and
    /// must agree — the original shape constructed only the legacy
    /// `ArrayWordRanges` configuration, leaving the `InlineWordRanges` one
    /// (what the default entry actually instantiates on macOS 26) untested
    /// here (PR #7 review, supplementary finding 8).
    private static func flavorAfterDemangling(_ mangled: String) throws -> ManglingFlavor {
        var utf8Copy = mangled
        let outcome = utf8Copy.withUTF8 { buffer in
            Result { () throws(DemanglingError) -> ManglingFlavor in
                var legacyConfigurationDemangler = Demangler<ArrayWordRanges>(bytes: buffer.span, materialization: .decoding)
                _ = try legacyConfigurationDemangler.demangleSymbol()
                let legacyConfigurationFlavor = legacyConfigurationDemangler.flavor
                if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
                    var modernConfigurationDemangler = Demangler<InlineWordRanges>(bytes: buffer.span, materialization: .decoding)
                    _ = try modernConfigurationDemangler.demangleSymbol()
                    guard modernConfigurationDemangler.flavor == legacyConfigurationFlavor else {
                        throw DemanglingError.unexpected(at: 0)
                    }
                }
                return legacyConfigurationFlavor
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
