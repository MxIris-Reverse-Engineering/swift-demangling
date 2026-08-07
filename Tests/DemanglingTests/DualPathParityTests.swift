import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Proposal 0008 dual-path parity: on a modern OS the default entry takes the
/// `utf8Span` path (revalidation-free materialization, inline word table)
/// while ``DemanglingRuntimePath/forcesLegacyPath`` forces the `withUTF8`
/// path (validating materialization, heap word table). The two must agree
/// byte for byte on every product — tree dump, printed output, remangled
/// string — and throw identical errors on invalid input.
///
/// Serialized because the seam is process-wide state; each assertion restores
/// it before returning.
@Suite("0008 dual-path parity", .serialized)
struct DualPathParityTests {
    private struct PathOutcome: Equatable {
        var treeDump: String?
        var printedDefault: String?
        var printedSugared: String?
        var remangled: String?
        var errorDescription: String?
    }

    private static func outcome(for mangled: String, isType: Bool) -> PathOutcome {
        do {
            let node = try demangleAsNode(mangled, isType: isType, internsSubtrees: false)
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

    /// Under a CI double-run (`DEMANGLING_FORCE_LEGACY_PATH=1`) the first
    /// outcome is already legacy and the comparison degrades to legacy vs
    /// legacy — trivially equal, harmless. The seam is snapshotted and
    /// restored rather than asserted clean so that mode does not trap.
    private static func assertParity(_ mangled: String, isType: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        let originalSeamValue = DemanglingRuntimePath.forcesLegacyPath
        let firstOutcome = outcome(for: mangled, isType: isType)
        DemanglingRuntimePath.forcesLegacyPath = true
        defer { DemanglingRuntimePath.forcesLegacyPath = originalSeamValue }
        let legacyOutcome = outcome(for: mangled, isType: isType)
        #expect(firstOutcome == legacyOutcome, "path divergence for \(mangled)", sourceLocation: sourceLocation)
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
