import Testing
@testable import Demangling

/// Regression tests for alignment gaps fixed against the Apple toolchain
/// demangler (Apple Swift 6.3.2). Each expected value was confirmed with
/// `xcrun swift-demangle` on the same symbol. These guard cache-external
/// behavior that the dyld-cache test cannot reach.
@Suite("Apple alignment regressions")
struct AppleAlignmentTests {
    // B-M1: popAnyProtocolConformance must accept DependentProtocolConformanceOpaque
    // so an opaque-conformance-bearing symbol demangles instead of throwing.
    @Test func opaqueResultConformanceDemangles() throws {
        let node = try demangleAsNode("$s3use1xAA3OfPVy3lib1GVyAA1fQryFQOyQo_GAjE1PAAxAeKHD1_AIHO_HCg_Gvp")
        #expect(node.print(using: .default) == "use.x : use.OfP<lib.G<<<opaque return type of use.f() -> some>>.0>>")
    }

    // B-H2 + B-H3: attached-macro remangling must put the discriminator (child 3)
    // AFTER the "fM<role>" code, and use role char 'e' for extension (and 'r' for
    // member-attribute). A stable round-trip proves the child order is correct.
    @Test func extensionAttachedMacroRoundTrips() throws {
        let input = "$s4main3FooVAA1P0B0fMe_"
        let node = try demangleAsNode(input)
        let remangled = try mangleAsString(node)
        #expect(remangled.contains("fMe"))
        // Re-demangling the remangled string yields an equal tree only if the
        // discriminator was placed after the code (otherwise it is malformed).
        let node2 = try demangleAsNode(remangled)
        #expect(node == node2)
    }

    // B-M6: the "Swift." prefix on AnyObject is gated on BOTH qualifyEntities
    // AND displayStdlibModule (matches `swift-demangle -display-stdlib-module=...`).
    @Test func anyObjectStdlibModuleGate() throws {
        let node = try demangleAsNode("$s6anyobj7takesItyyAA1P_XlF")
        #expect(node.print(using: .default).contains("Swift.AnyObject"))
        var noStdlib = DemangleOptions.default
        noStdlib.remove(.displayStdlibModule)
        let out = node.print(using: noStdlib)
        #expect(out.contains("AnyObject"))
        #expect(!out.contains("Swift.AnyObject"))
    }

    // B-M2: displayLocalNameContexts (default true) gates the " #N" suffix and the
    // local-name postfix context. Default output matches Apple; clearing the flag
    // drops the "#N".
    @Test func localNameContextsGate() throws {
        let node = try demangleAsNode("_$s9localtest5outeryyF11LocalStructL_V6methodyyF")
        #expect(node.print(using: .default).contains("#1"))
        var noLocal = DemangleOptions.default
        noLocal.remove(.displayLocalNameContexts)
        #expect(!node.print(using: noLocal).contains("#1"))
    }
}
