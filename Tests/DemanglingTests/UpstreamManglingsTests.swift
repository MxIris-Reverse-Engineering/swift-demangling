import Foundation
import Testing
@testable import Demangling

/// Every test line of upstream's `test/Demangle/Inputs/manglings.txt` at
/// swift-6.4.0-RELEASE (vendored as `Resources/manglings.txt`), printed the
/// way `swift-demangle` prints it and compared against the text the file
/// expects.
///
/// `DemangleSwiftProjectDerivedTests` pins 286 of these lines, one test each.
/// The other lines were never checked, and one of them — the
/// representation-changed specialization — printed differently from the
/// toolchain without any test noticing.
@Suite("Upstream manglings.txt")
struct UpstreamManglingsTests {
    struct TestLine: Sendable, CustomTestStringConvertible {
        let mangledName: String
        let expectedText: String

        var testDescription: String { mangledName }
    }

    /// The file's test lines, extracted the way upstream's own test extracts
    /// them (`test/Demangle/demangle.swift`): only a line containing `--->` is
    /// a test case; its input is the text before the first arrow without
    /// trailing spaces, its expectation the text after the last arrow without
    /// leading spaces.
    static let testLines: [TestLine] = {
        guard let fileURL = Bundle.module.url(forResource: "manglings", withExtension: "txt"),
              let contents = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return [] }
        return contents.split(separator: "\n").compactMap { line in
            guard let firstArrow = line.range(of: "--->"),
                  let lastArrow = line.range(of: "--->", options: .backwards)
            else { return nil }
            var mangledName = line[..<firstArrow.lowerBound]
            while mangledName.last == " " {
                mangledName = mangledName.dropLast()
            }
            var expectedText = line[lastArrow.upperBound...]
            while expectedText.first == " " {
                expectedText = expectedText.dropFirst()
            }
            return TestLine(
                mangledName: String(mangledName),
                expectedText: strippingClassification(String(expectedText))
            )
        }
    }()

    /// Upstream runs the file through `swift-demangle -classify`, which puts a
    /// `{N}`, `{T:<thunk target>}` or `{C}` group (or a comma-joined mix) in
    /// front of some lines. That is the tool's annotation, not printer output.
    private static func strippingClassification(_ text: String) -> String {
        guard text.hasPrefix("{"), let groupEnd = text.range(of: "} ") else { return text }
        return String(text[groupEnd.upperBound...])
    }

    /// What `swift-demangle` prints for `mangledName` with its default options:
    /// the demangled text, or the name itself when it does not demangle.
    private static func printedText(for mangledName: String) -> String {
        guard let node = try? demangleAsNode(mangledName) else { return mangledName }
        let text = node.print(using: .default.union(.synthesizeSugarOnTypes))
        return text.isEmpty ? mangledName : text
    }

    // An empty parse would turn the parameterized test below into zero cases
    // that all pass.
    @Test func everyTestLineOfTheVendoredFileIsRead() {
        #expect(Self.testLines.count == 512)
    }

    /// Swift 3 manglings (`_T` without the `0`) the port prints differently
    /// from upstream, adjudicated not to fix (`KnownIssues.md` N24): the
    /// prefix is effectively extinct. Marked rather than skipped, so a fix
    /// that makes one of them pass fails here until its entry is removed.
    static let adjudicatedSwift3Lines: Set<String> = [
        "_TTSf1cl35_TFF7specgen6callerFSiT_U_FTSiSi_T_Si___TF7specgen12take_closureFFTSiSi_T_T_",
        "_TTSf1cl35_TFF7specgen6callerFSiT_U_FTSiSi_T_Si___TTSg5Si___TF7specgen12take_closureFFTSiSi_T_T_",
        "_TTSf1cpfr24_TF8capturep6helperFSiT__n___TTRXFo_dSi_DT__XFo_iSi_DT__",
        "_TTSf1cpfr24_TF8capturep6helperFSiT__n___TTRXFo_dSi_dT__XFo_iSi_dT__",
        "_TTSf1cpi0_cpfl0_cpse0v4u123_cpg53globalinit_33_06E7F1D906492AE070936A9B58CBAE1C_token8_cpfr36_TFtest_capture_propagation2_closure___TF7specgen12take_closureFFTSiSi_T_T_",
        "_TTSfq1cl35_TFF7specgen6callerFSiT_U_FTSiSi_T_Si___TF7specgen12take_closureFFTSiSi_T_T_",
        "_TTSg5Si___TTSf1cl35_TFF7specgen6callerFSiT_U_FTSiSi_T_Si___TF7specgen12take_closureFFTSiSi_T_T_",
        "_Ttu4222222222222222222222222_rW_2T_2TJ_",
    ]

    @Test(arguments: testLines)
    func printsTheTextUpstreamExpects(line: TestLine) {
        let printedText = Self.printedText(for: line.mangledName)
        if Self.adjudicatedSwift3Lines.contains(line.mangledName) {
            withKnownIssue("Swift 3 mangling, not fixed by decision (KnownIssues N24)") {
                #expect(printedText == line.expectedText)
            }
        } else {
            #expect(printedText == line.expectedText)
        }
    }
}
