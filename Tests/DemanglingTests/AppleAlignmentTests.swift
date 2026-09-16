import Foundation
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

    // A9: 0xFF alignment padding before an operator must be skipped (upstream
    // Demangler.cpp:1029, merged in 8d0b396). Metadata mangled names carry the
    // padding; a Latin-1-decoded String presents it as U+00FF, which reaches
    // the byte scanner as its UTF-8 encoding C3 BF — so the original scalar
    // comparison went dead when the scanner byte-ized and the corpus (all
    // ASCII) could never notice (ReviewFindingsPR7 F2). This is the targeted
    // test 8d0b396 never had.
    @Test func alignmentPaddingBeforeOperatorIsSkipped() throws {
        let padded = try demangleAsNode("$s4main1AV\u{FF}6methodyyF")
        #expect(padded.print(using: .default) == "main.A.method() -> ()")
        let doublyPadded = try demangleAsNode("$s4main1AV\u{FF}\u{FF}6methodyyF")
        #expect(doublyPadded.print(using: .default) == "main.A.method() -> ()")
        let transient = try demangleAsNodeTransient("$s4main1AV\u{FF}6methodyyF")
        #expect(transient.print(using: .default) == "main.A.method() -> ()")
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

    // B-H1 preamble + B-H6: PreambleAttachedMacroExpansion node kind, role char 'q',
    // printed with the "preamble" introducer. Confirmed via `xcrun swift-demangle`:
    // "...preamble macro @Foo expansion #1 of P in main".
    @Test func preambleAttachedMacroRoundTripsAndPrints() throws {
        let input = "$s4main3FooVAA1P0B0fMq_"
        let node = try demangleAsNode(input)
        #expect(node.print(using: .default).contains("preamble macro"))
        let remangled = try mangleAsString(node)
        #expect(remangled.contains("fMq"))
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

    // MARK: - Swift 6.4 (Apple Swift 6.4, Xcode 27.0; evolution 0015)

    /// Every symbol upstream added to `test/Demangle/Inputs/manglings.txt`
    /// between swift-6.3.2-RELEASE and swift-6.4.0-RELEASE, plus the two whose
    /// expected text changed. The printed text is pinned in
    /// `DemangleSwiftProjectDerivedTests`; here each one must remangle to
    /// itself byte for byte, because the corpus oracle cannot see them — no
    /// shipping dyld cache carries them yet. Every expected value was confirmed
    /// with Xcode 27.0's `xcrun swift-demangle`.
    static let swift64UpstreamSymbols: [String] = [
        "$s3foo7closureSSTf1EC0_n",
        "$s4mini3SeqPxAA06BorrowB0TN",
        "$s4mini3SeqPxAA06BorrowB0Tn",
        "$s5assoc9ncElementyyxAA1PRz0C0Rj_zlF",
        "$s5assoc6ncIteryyxAA1PRzlF",
        "$s5assoc6ncBothyyxAA1PRz7ElementRj_zlF",
        "$s5assoc12bothCopyableyyxAA1PRzs0C08IteratorRpzlF",
        "$s5assoc6HolderVAARi_z7ElementRj_zrlE02ncC0yyqd__AA1PRd__ADRj_d__lF",
        "$s5assoc6HolderVAA7ElementRj_zrlE19forceIntoInterface5yyF",
        "$s5assoc6HolderVAARi_z7ElementRj_zrlE12copyableIteryyqd__AA1PRd__s8Copyable8IteratorRpd__lF",
        "$s5thing1PP1sAA1SVvxTwc",
        "$s7Library1BC1iSivxTwd",
        "$s7Library1BC1iSivxTwdTwc",
        "$sSiBW",
        "$sBAIeNghHgIL_BAytIeNghHgILr_TR",
        "$s2hi1SV1iSivx",
        "$s2hi1SV1iSivy",
    ]

    @Test(arguments: swift64UpstreamSymbols)
    func swift64UpstreamSymbolRemanglesToItself(symbol: String) throws {
        let node = try demangleAsNode(symbol)
        // The remangler always writes the linker-visible `_$s` prefix.
        #expect(try mangleAsString(node) == "_" + symbol)
    }

    // Read2Accessor / Modify2Accessor became YieldingBorrowAccessor /
    // YieldingMutateAccessor (SE-0474). The mangling characters y / x are
    // unchanged, so the tree differs from 6.3 by the kind name only — which is
    // exactly what the corpus oracle compares in `kind=` lines.
    @Test func yieldingAccessorsDemangleToTheSwift64Kinds() throws {
        let borrow = try demangleAsNode("$s2hi1SV1iSivy")
        let mutate = try demangleAsNode("$s2hi1SV1iSivx")
        #expect(borrow.contains(.yieldingBorrowAccessor))
        #expect(mutate.contains(.yieldingMutateAccessor))
        #expect(borrow.description.contains("kind=YieldingBorrowAccessor"))
        #expect(mutate.description.contains("kind=YieldingMutateAccessor"))
    }

    // ImplFunctionType: 'N' right after the 'A' slot is nonisolated(nonsending),
    // printed @caller_isolated. The thunk has two impl function types, so the
    // marker appears twice and the erased-isolation marker not at all.
    @Test func callerIsolatedImplFunctionCarriesTheIsolationNode() throws {
        let node = try demangleAsNode("$sBAIeNghHgIL_BAytIeNghHgILr_TR")
        #expect(node.all(of: .implNonisolatedNonsendingIsolation).count == 2)
        #expect(!node.contains(.implErasedIsolation))
    }

    // ARG-SPEC-KIND 'E' is EscapingClosureProp (kind 12) with the same payload
    // shape as 'c': the closure identifier followed by the captured types.
    @Test func escapingClosurePropagationCarriesKindTwelve() throws {
        let node = try demangleAsNode("$s3foo7closureSSTf1EC0_n")
        let kinds = node.all(of: .functionSignatureSpecializationParamKind).compactMap(\.index)
        #expect(kinds.first == FunctionSigSpecializationParamKind.escapingClosureProp.rawValue)
    }

    // 'Rj' is an inverse requirement on an associated type: parsed like 'p'
    // (assoc subject, pushed as a substitution) but producing an inverse node.
    @Test func inverseRequirementOnAssociatedTypeDemangles() throws {
        let node = try demangleAsNode("$s5assoc9ncElementyyxAA1PRz0C0Rj_zlF")
        let inverse = try #require(node.first(of: .dependentGenericInverseConformanceRequirement))
        #expect(inverse.children.first?.contains(.dependentMemberType) == true)
    }

    // 'Tn' / 'TN': since 6.4 the subject may be a bare generic parameter
    // (`type type protocol 'Tn'`); the associated-type-path form still parses.
    @Test func associatedConformanceDescriptorAcceptsGenericParameterSubject() throws {
        let generic = try demangleAsNode("$s4mini3SeqPxAA06BorrowB0Tn")
        let genericDescriptor = try #require(generic.first(of: .associatedConformanceDescriptor))
        #expect(genericDescriptor.children.count == 3)
        #expect(genericDescriptor.children[1].isGenericParamType)

        let path = try demangleAsNode("$S1t1PP10AssocType2_AA1QTn")
        let pathDescriptor = try #require(path.first(of: .associatedConformanceDescriptor))
        #expect(pathDescriptor.children[1].kind == .assocTypePath)
    }

    // An attached macro expansion has three children when it is itself the
    // context of another expansion (no attached name). Upstream 4542ea9904f
    // fixed the remangler to mangle the discriminator last for both shapes;
    // Apple 6.4's printer crashes on this shape, so only the round trip is
    // pinned here.
    @Test func attachedMacroExpansionWithThreeChildrenRemangles() throws {
        let symbol = "$s4main1AV3foo7MyMacrofMp_5OtherfMp0_"
        let node = try demangleAsNode(symbol)
        let outer = try #require(node.first(of: .peerAttachedMacroExpansion))
        #expect(outer.children.count == 3)
        #expect(outer.children[0].kind == .peerAttachedMacroExpansion)
        #expect(try mangleAsString(node) == "_" + symbol)
    }

    // The retired names stay usable as deprecated aliases and as encoded raw
    // values, so a consumer written against 6.3 keeps compiling and decoding.
    @available(*, deprecated)
    @Test func retiredAccessorKindNamesAliasTheSwift64Kinds() {
        #expect(Node.Kind.read2Accessor == .yieldingBorrowAccessor)
        #expect(Node.Kind.modify2Accessor == .yieldingMutateAccessor)
    }

    @Test func retiredAccessorKindRawValuesStillDecode() throws {
        let decoder = JSONDecoder()
        func decode(_ rawValue: String) throws -> Node.Kind {
            try decoder.decode(Node.Kind.self, from: Data("\"\(rawValue)\"".utf8))
        }
        #expect(try decode("read2Accessor") == .yieldingBorrowAccessor)
        #expect(try decode("modify2Accessor") == .yieldingMutateAccessor)
        #expect(try decode("yieldingBorrowAccessor") == .yieldingBorrowAccessor)
        #expect(throws: DecodingError.self) { try decode("noSuchKind") }
    }
}
