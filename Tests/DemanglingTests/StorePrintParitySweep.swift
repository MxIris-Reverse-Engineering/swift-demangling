import Foundation
import Testing
@_spi(Internals) @testable import Demangling
@testable import DemanglingTestingSupport

/// Proposal 0008 acceptance sweep: store-path printing (the
/// `UnretainedNodeReference` engine) must be byte-identical to `Node`-path
/// printing across the print corpus × three option sets. Opt-in
/// (`DEMANGLING_PRINT_PARITY=1`) because it demangles the corpus twice; run
/// it in release, once per runtime path:
///
/// ```
/// DEMANGLING_PRINT_PARITY=1 swift test -c release --filter StorePrintParitySweep
/// DEMANGLING_PRINT_PARITY=1 DEMANGLING_FORCE_LEGACY_PATH=1 swift test -c release --filter StorePrintParitySweep
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEMANGLING_PRINT_PARITY"] == "1"), .serialized)
final class StorePrintParitySweep: DyldCacheSymbolTests, @unchecked Sendable {
    private static let optionSets: [(name: String, options: DemangleOptions)] = [
        ("default", .default),
        ("simplified", .simplified),
        ("sugared", .default.union(.synthesizeSugarOnTypes)),
    ]

    /// Synchronous so the sync `print(using:)` overloads — the walks under
    /// test — are the ones selected inside this async test.
    private static func comparePrints(_ node: Node, _ reference: NodeReference) -> String? {
        for (name, options) in optionSets {
            let nodePathOutput = node.print(using: options)
            let storePathOutput = reference.print(using: options)
            if nodePathOutput != storePathOutput {
                return name
            }
        }
        return nil
    }

    @Test func storePathPrintingMatchesNodePathAcrossCorpus() async throws {
        let extracted = try await symbols(for: .SwiftUI, .SwiftUICore, .Foundation, .Combine)
        let corpus = Array(Set(extracted.map(\.stringValue))).sorted()
        try #require(!corpus.isEmpty, "print corpus unavailable on this machine")

        var builder = NodeStoreBuilder()
        var rootBySymbol: [(symbol: String, root: NodeStore.NodeIndex)] = []
        rootBySymbol.reserveCapacity(corpus.count)
        for mangled in corpus {
            if let root = try? builder.demangle(mangled) {
                rootBySymbol.append((mangled, root))
            }
        }
        let store = builder.freeze()

        var mismatchCount = 0
        var mismatchSamples: [String] = []
        for (mangled, root) in rootBySymbol {
            guard let node = try? demangleAsNodeTransient(mangled) else { continue }
            if let divergingOptionSet = Self.comparePrints(node, store.reference(at: root)) {
                mismatchCount += 1
                if mismatchSamples.count < 10 {
                    mismatchSamples.append("\(mangled) [\(divergingOptionSet)]")
                }
            }
        }
        print("[0008-print-parity] symbols=\(rootBySymbol.count) optionSets=\(Self.optionSets.count) mismatches=\(mismatchCount)")
        if !mismatchSamples.isEmpty {
            print("[0008-print-parity] samples: \(mismatchSamples.joined(separator: ", "))")
        }
        #expect(mismatchCount == 0, "store-path printing must be byte-identical to the Node path")
    }
}
