import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Proposal 0008 B1/B2: borrowed text views on the store path and the
/// ARC-free print walk. Print parity against the `Node` path is the
/// authoritative check that `UnretainedNodeReference` walks the same tree the
/// retained handle does.
@Suite("0008 borrowed views and store print")
struct BorrowedTextViewTests {
    private static let sampleSymbols = [
        "$s7SwiftUI4ViewPAAE4task8priority_QrScP_yyYaYbScMYccntF",
        "$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF",
        "$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF", // punycoded, non-ASCII stored text
        "$ss2eeoiySbx_xtSQRzlF",
        "$s4main3fooyyF.resume.0",
    ]

    private static func storeAndRoots(for symbols: [String]) throws -> (NodeStore, [NodeStore.NodeIndex]) {
        var builder = NodeStoreBuilder()
        let roots = try symbols.map { try builder.demangle($0) }
        return (builder.freeze(), roots)
    }

    @Test func withTextUTF8MatchesTextAndSliceView() throws {
        let (store, roots) = try Self.storeAndRoots(for: Self.sampleSymbols)
        var visitedTextNodeCount = 0
        for root in roots {
            for node in store.reference(at: root) where node.kind == .identifier || node.kind == .module {
                let borrowedBytes: [UInt8]? = node.withTextUTF8 { spanBytes in
                    var copied = [UInt8]()
                    copied.reserveCapacity(spanBytes.count)
                    for byteOffset in 0 ..< spanBytes.count {
                        copied.append(spanBytes[byteOffset])
                    }
                    return copied
                }
                let copiedBytes = node.textUTF8Bytes
                #expect(borrowedBytes == copiedBytes, "withTextUTF8 and textUTF8Bytes must expose the same bytes")
                if let borrowedBytes {
                    visitedTextNodeCount += 1
                    #expect(String(decoding: borrowedBytes, as: UTF8.self) == node.text)
                }
            }
        }
        #expect(visitedTextNodeCount > 0, "corpus should contain stored-text nodes")
    }

    @Test func withTextUTF8IsNilForSynthesizedAndNonTextNodes() throws {
        let (store, roots) = try Self.storeAndRoots(for: ["$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF"])
        var checkedSynthesizedName = false
        for node in store.reference(at: roots[0]) {
            if node.kind == .dependentGenericParamType {
                // Synthesized name: `text` composes it, but no bytes are stored.
                #expect(node.text != nil)
                #expect(node.withTextUTF8 { _ in true } == nil)
                checkedSynthesizedName = true
            }
            if node.kind == .type {
                #expect(node.withTextUTF8 { _ in true } == nil)
            }
        }
        #expect(checkedSynthesizedName, "symbol should contain a dependent generic parameter")
    }

    /// Guards the gate right below: without `Lifetimes` enabled on the *test*
    /// target, `directReturnSpanAgreesWithClosureForm` silently drops out of
    /// the test binary and the suite stays green with the direct-return
    /// borrowed views never executed (ReviewFindingsPR7 F3). This meta-test is
    /// blind to gates in *other* targets and to `#available` runtime guards —
    /// it only proves the feature flag reaches this target's compilation.
    @Test func lifetimesFeatureIsEnabledInTestTarget() {
        #if hasFeature(Lifetimes)
        // Enabled: the gated test below is part of the binary.
        #else
        Issue.record("""
        The DemanglingTests target compiles without the Lifetimes experimental \
        feature, so every #if hasFeature(Lifetimes) test in this target is \
        silently excluded from the test binary. Mirror the Demangling target's \
        .enableExperimentalFeature("Lifetimes") in Package.swift's testTarget.
        """)
        #endif
    }

    #if hasFeature(Lifetimes)
    @Test func directReturnSpanAgreesWithClosureForm() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) else { return }
        let (store, roots) = try Self.storeAndRoots(for: Self.sampleSymbols)
        for root in roots {
            for node in store.reference(at: root) {
                var directBytes: [UInt8]?
                if let spanBytes = node.textUTF8Span() {
                    var copied = [UInt8]()
                    copied.reserveCapacity(spanBytes.count)
                    for byteOffset in 0 ..< spanBytes.count {
                        copied.append(spanBytes[byteOffset])
                    }
                    directBytes = copied
                }
                #expect(directBytes == node.textUTF8Bytes)
            }
        }
        // Store-level span accessor covers the whole table.
        let wholeTable = store.textBytesSpan()
        #expect(wholeTable.count == store.textByteCount)
    }
    #endif

    /// `textUTF8Bytes` (formerly `textUTF8: ArraySlice<UInt8>?`) pins its
    /// bytes without `Array(...)` normalization — the old suite normalized
    /// every comparison, which is exactly how the slice's index base silently
    /// changing from store-table offsets to 0 went unseen
    /// (ReviewFindingsPR7 F10). The `[UInt8]` return type now carries the
    /// 0-base in the signature; this test pins the content for a node whose
    /// text does *not* start the string table, the case where the two bases
    /// diverged.
    @Test func copiedTextBytesMatchTheStoredTextForALaterTableEntry() throws {
        var builder = NodeStoreBuilder()
        _ = builder.intern(kind: .identifier, text: "AAAAAAAA")
        let laterIndex = builder.intern(kind: .identifier, text: "BBBB")
        let store = builder.freeze()
        let laterBytes = try #require(store.reference(at: laterIndex).textUTF8Bytes)
        #expect(laterBytes == Array("BBBB".utf8))
        #expect(laterBytes.startIndex == 0)
    }

    /// The store-side materialization gate (ReviewFindingsPR7 F11) keys off
    /// the builder-maintained whole-table ASCII flag: an all-ASCII table
    /// licenses revalidation-free materialization for *any* in-bounds
    /// subrange (even a wrong index's), a non-ASCII table (punycode-decoded
    /// identifiers) demotes to the validating decode. This pins the flag's
    /// bookkeeping; byte-parity of the two materializations is pinned by
    /// `nonASCIIStoredTextMaterializesExactly` below.
    @Test func textMaterializationGateTracksTableASCIIness() throws {
        var asciiBuilder = NodeStoreBuilder()
        _ = asciiBuilder.intern(kind: .identifier, text: "plainASCII")
        let asciiStore = asciiBuilder.freeze()
        #expect(asciiStore.currentView.textTableIsKnownASCII)

        var nonASCIIBuilder = NodeStoreBuilder()
        _ = try nonASCIIBuilder.demangle("$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF")
        let nonASCIIStore = nonASCIIBuilder.freeze()
        #expect(!nonASCIIStore.currentView.textTableIsKnownASCII,
                "the punycode-decoded identifier must flip the whole-table ASCII flag")
    }

    /// Non-ASCII stored text (punycode-decoded identifiers) must round-trip
    /// identically through the revalidation-free materialization path.
    @Test func nonASCIIStoredTextMaterializesExactly() throws {
        let mangled = "$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF"
        let node = try demangleAsNode(mangled, internsSubtrees: false)
        let (store, roots) = try Self.storeAndRoots(for: [mangled])
        let reference = store.reference(at: roots[0])
        #expect(reference.print(using: .default) == node.print(using: .default))
        #expect(reference.structurallyEquals(node))
    }

    /// Synchronous on purpose: inside an async test the bare calls would
    /// resolve to the async `print(using:)` overloads, and the sync store
    /// walk is exactly what is under test.
    private static func printedSynchronously(_ node: Node, _ reference: NodeReference, options: DemangleOptions) -> (nodePath: String, storePath: String) {
        (node.print(using: options), reference.print(using: options))
    }

    /// Synchronous for the same overload-resolution reason as
    /// ``printedSynchronously(_:_:options:)``.
    private static func demangledSynchronously(_ mangled: String) throws(DemanglingError) -> Node {
        try demangleAsNode(mangled, internsSubtrees: false)
    }

    /// The ARC-free store print walk must be byte-identical to the `Node`
    /// path, sync and async.
    @Test func unretainedPrintWalkMatchesNodePath() async throws {
        let (store, roots) = try Self.storeAndRoots(for: Self.sampleSymbols)
        let optionSets: [DemangleOptions] = [.default, .simplified, .default.union(.synthesizeSugarOnTypes)]
        for (symbol, root) in zip(Self.sampleSymbols, roots) {
            let node = try Self.demangledSynchronously(symbol)
            let reference = store.reference(at: root)
            for options in optionSets {
                let (nodePathOutput, storePathOutput) = Self.printedSynchronously(node, reference, options: options)
                #expect(storePathOutput == nodePathOutput, "sync store print diverged for \(symbol)")
                let asyncOutput = await reference.print(using: options)
                #expect(asyncOutput == nodePathOutput, "async store print diverged for \(symbol)")
            }
        }
    }

    /// The witnesses that moved onto the shared store core keep their
    /// semantics: ASCII byte compare, `String` fallback for synthesized text.
    @Test func textWitnessesKeepSemantics() throws {
        let (store, roots) = try Self.storeAndRoots(for: ["$ss2eeoiySbx_xtSQRzlF"])
        var sawSwiftModule = false
        for node in store.reference(at: roots[0]) {
            if node.isSwiftModule {
                sawSwiftModule = true
                #expect(node.kind == .module)
                #expect(node.text == stdlibName)
            }
            if node.kind == .identifier, let identifierText = node.text {
                #expect(node.isIdentifier(desired: identifierText))
                #expect(!node.isIdentifier(desired: identifierText + "x"))
            }
        }
        #expect(sawSwiftModule, "operator symbol should reference the Swift module")
    }
}
