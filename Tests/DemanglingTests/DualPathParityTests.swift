import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Proposal 0008 dual-path parity: on a modern OS the default entry takes the
/// `utf8Span` path (revalidation-free materialization, inline word table)
/// while the legacy leg (`withUTF8` borrowing, validating materialization,
/// heap word table) is driven *directly* through its internal entry. The two
/// must agree byte for byte on every product — tree dump, printed output,
/// remangled string — and throw identical errors on invalid input.
///
/// The suite deliberately never touches
/// ``DemanglingRuntimePath/forcesLegacyPath``: the seam is process-wide, and
/// flipping it here silently dragged every concurrently running suite onto
/// the legacy path — `.serialized` only orders tests *within* a suite
/// (ReviewFindingsPR7 F12).
@Suite("0008 dual-path parity")
struct DualPathParityTests {
    private struct PathOutcome: Equatable {
        var treeDump: String?
        var printedDefault: String?
        var printedSugared: String?
        var remangled: String?
        var errorDescription: String?
    }

    private static func outcome(
        for mangled: String,
        isType: Bool,
        demangle: (String, Bool) throws(DemanglingError) -> Node
    ) -> PathOutcome {
        do {
            let node = try demangle(mangled, isType)
            return PathOutcome(
                treeDump: node.description,
                printedDefault: node.print(using: .default),
                printedSugared: node.print(using: .default.union(.synthesizeSugarOnTypes)),
                remangled: try? mangleAsString(node),
                errorDescription: nil
            )
        } catch {
            return PathOutcome(errorDescription: String(describing: error))
        }
    }

    /// Whether the default entry can actually take the modern leg in this
    /// process. Both routes that collapse it are checked: the process-wide
    /// environment seam, and the OS version the `#available` guard tests.
    ///
    /// - SeeAlso: ``dualPathParityCoversTheModernLeg()``, which turns "no" into
    ///   a visible result instead of a vacuous pass.
    static var modernLegIsReachable: Bool {
        if DemanglingRuntimePath.forcesLegacyPath { return false }
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
            return true
        }
        return false
    }

    /// Guards every `assertParity` below. The comparison is only meaningful
    /// when the default entry is on the *modern* leg; otherwise both sides run
    /// the legacy path, every expectation is trivially equal, and the suite is
    /// green while covering nothing.
    ///
    /// The suite's own doc comment anticipated the environment-variable route
    /// and called it harmless. The OS-version route is not harmless: a
    /// developer or CI runner on a host older than macOS 26 gets zero coverage
    /// of the modern leg with no signal at all. This is precisely the blind
    /// spot `BorrowedTextViewTests.lifetimesFeatureIsEnabledInTestTarget`
    /// documents about itself — "blind to gates in *other* targets and to
    /// `#available` runtime guards" — applied to the axis it could not see
    /// (PR #7 review, fourth round).
    @Test func dualPathParityCoversTheModernLeg() {
        if DemanglingRuntimePath.forcesLegacyPath {
            // Deliberate: the CI double-run pins the legacy leg process-wide
            // and this pass is *expected* to compare legacy against legacy.
            return
        }
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
            // The default entry is the modern leg; the parity tests are real.
        } else {
            Issue.record("""
            This host predates the modern demangling leg (macOS 26 / iOS 26 / \
            tvOS 26 / watchOS 26 / visionOS 26 / macCatalyst 26), so \
            `demangleAsNode` already resolves to the legacy path and every \
            parity test in this suite compares the legacy leg against itself. \
            The suite passes without exercising the utf8Span scanner, \
            InlineWordRanges or prevalidated materialization at all. Run the \
            0008 parity suite on a modern host before trusting it as evidence.
            """)
        }
    }

    /// Under a CI double-run (`DEMANGLING_FORCE_LEGACY_PATH=1`, set at
    /// process launch) the default entry is already on the legacy leg and
    /// the comparison degrades to legacy vs legacy — trivially equal,
    /// harmless. The OS-version route to the same degradation is *not*
    /// harmless and is reported by ``dualPathParityCoversTheModernLeg()``.
    private static func assertParity(_ mangled: String, isType: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        let defaultPathOutcome = outcome(for: mangled, isType: isType) { (mangledSymbol, isTypeSymbol) throws(DemanglingError) in
            try demangleAsNode(mangledSymbol, isType: isTypeSymbol, internsSubtrees: false)
        }
        let legacyPathOutcome = outcome(for: mangled, isType: isType) { (mangledSymbol, isTypeSymbol) throws(DemanglingError) in
            try demangleAsNodeOnLegacyRuntimePath(mangledSymbol, isType: isTypeSymbol, internsSubtrees: false)
        }
        #expect(defaultPathOutcome == legacyPathOutcome, "path divergence for \(mangled)", sourceLocation: sourceLocation)
    }

    /// Long multi-word identifiers exercise the word-substitution table — the
    /// storage that differs per path (`InlineWordRanges` vs
    /// `ArrayWordRanges`).
    @Test func wordSubstitutionHeavySymbols() {
        Self.assertParity("$s7SwiftUI4ViewPAAE4task8priority_QrScP_yyYaYbScMYccntF")
        Self.assertParity("$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF")
        Self.assertParity("$s7Combine9PublisherPAAE4sink18receiveCompletion0C5ValueAA14AnyCancellableCyAA11SubscribersO0D0Oy_7FailureQZGc_y6OutputQZctF")
        Self.assertParity("$s7SwiftUI18DynamicViewContentPAAE8onDelete7performQrys8IndexSetVcSg_tF")
    }

    /// Punycoded identifiers take the decode-then-append assembly branch.
    @Test func punycodedSymbols() {
        Self.assertParity("_T08mangling0022egbpdajGbuEbxfgehfvwxnyyF")
        Self.assertParity("$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF")
    }

    /// Operator identifiers route through the operator character table.
    @Test func operatorSymbols() {
        Self.assertParity("$ss2eeoiySbx_xtSQRzlF")
        Self.assertParity("$ss1poiyxx_xtSjRzlF")
    }

    /// Unmangled-suffix and whole-input materialization points.
    @Test func suffixAndTypeFallback() {
        Self.assertParity("$s4main3fooyyF.resume.0")
        Self.assertParity("Si", isType: true)
        Self.assertParity("not-a-type-mangle-at-all", isType: true)
    }

    /// The extinct Swift 3 grammar still routes through the same scanner.
    @Test func swift3Symbols() {
        Self.assertParity("_T03foo3barC3basyAA3zimCAE_tFTo")
        Self.assertParity("_TtC5AppKit10NSDocument")
    }

    /// Local and private declaration names.
    @Test func localAndPrivateDeclarationNames() {
        Self.assertParity("_$s9localtest5outeryyF11LocalStructL_V6methodyyF")
        Self.assertParity("$s4main3FooV33_A2D9A3E6C7F8B9C0D1E2F3A4B5C6D7E8LLyyF")
    }

    /// Invalid inputs must fail with identical byte offsets on both paths,
    /// including non-ASCII bytes (where the modern path selects validating
    /// materialization via `isKnownASCII`).
    @Test func invalidInputErrorParity() {
        Self.assertParity("$s")
        Self.assertParity("$sBoom")
        Self.assertParity("$s4main")
        Self.assertParity("$s99999999999999999999999999999999999999994abcd")
        Self.assertParity("$s4mainλλλyyF")
        Self.assertParity("$s4main00XyyF")
    }
}
