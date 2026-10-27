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

    // MARK: - Printed text that diverged while every tree matched

    // The corpus oracle compared node trees and remangled strings but never
    // printed text, so these printer divergences shipped with every tree
    // matching. Each expected value is Xcode 27.2's `swift-demangle` output.

    // Upstream prints "specialized " whenever generic specializations are
    // hidden and "representation changed of " only when they are displayed
    // (4c09fa6805b); the port had the check in the hidden branch.
    @Test func representationChangedSpecializationPrintsLikeTheToolchain() throws {
        let node = try demangleAsNode("$e4test4BaseCyxGAA1PA2aEP3fooyyFTWTfr9")
        #expect(node.print(using: .default.union(.synthesizeSugarOnTypes))
            == "representation changed of protocol witness for test.P.foo() -> () in conformance test.Base<A> : test.P in test")
    }

    // The node printed on its own, as upstream's `case RepresentationChanged`
    // does: the prefix, then the child. Only a hand-built tree reaches it —
    // the demangler creates the node childless under a specialization, where
    // it is never printed on its own.
    @Test func representationChangedNodePrintsItsChildLikeUpstream() {
        let node = Node.create(kind: .representationChanged, child: Node.create(kind: .identifier, text: "foo"))
        #expect(node.print(using: .default) == "representation changed of foo")
    }

    @Test func simplifiedRepresentationChangedSpecializationSaysSpecialized() throws {
        let node = try demangleAsNode("$e4test4BaseCyxGAA1PA2aEP3fooyyFTWTfr9")
        #expect(node.print(using: .simplified) == "specialized protocol witness for P.foo() in conformance Base<A>")
    }

    // A representation-changed child in a later position takes a parameter
    // number, like every other childless specialization child does upstream.
    @Test func representationChangedChildAdvancesTheArgumentNumber() throws {
        let node = try demangleAsNode("$s3foo7closureSSTfar1cC0_n")
        #expect(node.print(using: .default.union(.synthesizeSugarOnTypes))
            == "function signature specialization <Arg[2] = [Closure Propagated : closure, Argument Types : [Swift.String], Arg[3] = [Same As Argument 0]> of foo")
    }

    // Upstream renamed the predefined completion handler to the checked one
    // (2abf087e71f); the port renamed the kind but kept the printed word.
    @Test func checkedObjCCompletionHandlerThunkSaysChecked() throws {
        let node = try demangleAsNode("$sIeyBh_ytTZ_")
        #expect(node.print(using: .default.union(.synthesizeSugarOnTypes))
            == "checked @objc completion handler block implementation for @escaping @callee_unowned @convention(block) @Sendable () -> () with result type ()")
    }

    // Upstream separates two argument types only when the next child carries
    // text, which a type node never does, so they print run together. It reads
    // badly, but it is the toolchain's text, and the port follows upstream's
    // printer rather than getting ahead of it (KnownIssues N1).
    @Test func closurePropagatedArgumentTypesPrintRunTogether() throws {
        let node = try demangleAsNode("$s3foo7closureSSSiTf1cC0_n")
        #expect(node.print(using: .default.union(.synthesizeSugarOnTypes))
            == "function signature specialization <Arg[0] = [Closure Propagated : closure, Argument Types : [Swift.StringSwift.Int], Arg[1] = [Same As Argument 0]> of foo")
    }

    // MARK: - Differences the printed-text oracle found in real binaries

    // A mangled name nested in a specialization parameter prints under the
    // default options, without type sugar, whatever the caller asked for:
    // upstream calls `demangleSymbolAsString(text)` with no options.
    @Test func nameNestedInASpecializationParameterPrintsUnderTheDefaultOptions() throws {
        let node = try demangleAsNode("_$sxq_xq_Iegnnrr_x3key_q_5valuetx_q_tIegnr_SHRzs5ErrorRd__r0__lTRSS_SSs5NeverOTG5064$sSD5merge_16uniquingKeysWithySDyxq_Gn_q_q__q_tqd__YKXEtqd__YKs5c27Rd__lFx_q_tx_q_tcfU_SS_SSs5D4OTG5Tf3nnpf_n")
        #expect(node.print(using: .default.union(.synthesizeSugarOnTypes))
            == "function signature specialization <Arg[2] = [Constant Propagated Function : generic not re-abstracted specialization <Swift.String, Swift.String, Swift.Never> of closure #1 (A, B) -> (A, B) in Swift.Dictionary.merge<A where A1: Swift.Error>(_: __owned Swift.Dictionary<A, B>, uniquingKeysWith: (B, B) throws(A1) -> B) throws(A1) -> ()]> of generic not re-abstracted specialization <Swift.String, Swift.String, Swift.Never> of reabstraction thunk helper <A, B><A1 where A: Swift.Hashable, A1: Swift.Error> from @escaping @callee_guaranteed (@in_guaranteed A, @in_guaranteed B) -> (@out A, @out B) to @escaping @callee_guaranteed (@in_guaranteed (key: A, value: B)) -> (@out (A, B))")
    }

    // The same rule for an attached macro's name, which upstream prints with
    // `nodeToString(Node->getChild(2))`, again without options. Demangled
    // input always carries a bare identifier there, so the tree is hand-built
    // with a qualified name, the one shape where the options show.
    @Test func attachedMacroNamePrintsUnderTheDefaultOptions() {
        let qualifiedMacroName = Node.create(kind: .structure, children: [
            Node.create(kind: .module, text: "Swift"),
            Node.create(kind: .identifier, text: "Int"),
        ])
        let expansion = Node.create(kind: .peerAttachedMacroExpansion, children: [
            Node.create(kind: .module, text: "main"),
            Node.create(kind: .identifier, text: "f"),
            qualifiedMacroName,
            Node.create(kind: .number, index: 0),
        ])
        #expect(expansion.print(using: .simplified).contains("peer macro @Swift.Int expansion #1"))
    }

    // A shortened thunk prints its last child, as upstream's `ShortenThunk`
    // branch does; the port printed the other function type.
    @Test func shortenedThunkPrintsTheLastChildLikeUpstream() throws {
        let node = try demangleAsNode("_$sSo11NSTextRangeCSgSDySo21NSAttributedStringKeyaypGSgIeggg_ACSo12NSDictionaryCSgIeyByy_TR")
        #expect(node.print(using: .simplified)
            == "thunk for @escaping @callee_guaranteed (@guaranteed NSTextRange?, @guaranteed [NSAttributedStringKey : Any]?) -> ()")
    }

    // `.simplified` is upstream's `SimplifiedUIDemangleOptions()`: the default
    // options with a named few changed, every other one keeping its default.
    // A local name therefore keeps its "#1 in" context.
    @Test func simplifiedKeepsTheContextOfALocalName() throws {
        let node = try demangleAsNode("$s4main3fooyyF3BarL_VMa")
        #expect(node.print(using: .simplified) == "type metadata accessor for Bar #1 in foo()")
    }

    // ...and a dependent member type keeps the context of its protocol
    // (`A.Text.Effect.Base.Timing`, not `A.Base.Timing`). The symbol is a
    // shortened thunk too, so it also needs the last-child rule above.
    @Test func simplifiedKeepsTheContextOfADependentMemberType() throws {
        let node = try demangleAsNode("_$s6Timing7SwiftUI4TextV0D16AnimationSupportE6EffectO4BasePQzAG16DrawableFragmentVy__xGAG19QuantizationContextVAG0I0VIegngyo_AjmoQIegnnnr_AE0dG0RzlTRAE05BloomdG0V_TG5TA")
        #expect(node.print(using: .simplified)
            == "partial apply for specialized thunk for @escaping @callee_guaranteed (@in_guaranteed A.Text.Effect.Base.Timing, @guaranteed Text.Effect.DrawableFragment<A>, @unowned Text.Effect.QuantizationContext) -> (@owned Text.Effect.Drawable)")
    }

    // Shortening drops "back deployment thunk for " but never "back deployment
    // fallback for ": upstream gates only the thunk on `ShortenThunk`.
    @Test func simplifiedKeepsTheBackDeploymentFallbackPrefix() throws {
        let node = try demangleAsNode("$ss31_diagnoseUnavailableCodeReacheds5NeverOyFTwB")
        #expect(node.print(using: .simplified) == "back deployment fallback for _diagnoseUnavailableCodeReached()")
    }

    // A value generic parameter prints its `let` marker. Upstream then reads
    // the value type out of bounds of the marker's `.type` wrapper, which the
    // shipping toolchain prints as nothing, so the line reads `<let A, B>`
    // without the `: Swift.Int` the mangling carries.
    @Test func valueGenericParameterPrintsItsLetMarker() throws {
        let node = try demangleAsNode("_$sSWqd__s5Error_pIgyrzo_SWqd__sAA_pIegyrzr_SiRVzs5UInt8VRs_r0__lTRTA")
        #expect(node.print(using: .default.union(.synthesizeSugarOnTypes))
            == "partial apply forwarder for reabstraction thunk helper <let A, B><A1 where B == Swift.UInt8> from @callee_guaranteed (@unowned Swift.UnsafeRawBufferPointer) -> (@out A1, @error @owned Swift.Error) to @escaping @callee_guaranteed (@unowned Swift.UnsafeRawBufferPointer) -> (@out A1, @error @out Swift.Error)")
    }
}
