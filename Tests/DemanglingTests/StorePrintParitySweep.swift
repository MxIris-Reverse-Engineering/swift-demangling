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
        var storePathFailedSymbols: [String] = []
        for mangled in corpus {
            do {
                rootBySymbol.append((mangled, try builder.demangle(mangled)))
            } catch {
                storePathFailedSymbols.append(mangled)
            }
        }
        let store = builder.freeze()

        // Failure visibility (ReviewFindingsPR7 F4): failures used to be
        // swallowed with `try?` before the comparison, making the sweep blind
        // to any regression that turns success into failure — F2 (the 0xFF
        // padding regression) escaped exactly that way. A one-sided failure is
        // a parity mismatch. A both-sided failure is classified against the
        // Swift runtime's own demangler, the same referee the default-run
        // corpus oracle uses: rejected by stdlib too → consistent rejection
        // (symbol-table junk, counted and reported); demangled by stdlib →
        // regression, asserted to zero. The classification stays blind to a
        // symbol class absent from the all-ASCII symbol-table corpus —
        // targeted unit tests carry those.
        var oneSidedFailureCount = 0
        var oneSidedFailureSamples: [String] = []
        var consistentlyRejectedCount = 0
        var consistentlyRejectedSamples: [String] = []
        var regressedSymbolCount = 0
        var regressedSymbolSamples: [String] = []
        for mangled in storePathFailedSymbols {
            do {
                _ = try demangleAsNodeTransient(mangled)
                oneSidedFailureCount += 1
                if oneSidedFailureSamples.count < 10 {
                    oneSidedFailureSamples.append("\(mangled) [store failed, transient succeeded]")
                }
            } catch {
                if stdlib_demangleNodeTree(mangled) == nil {
                    consistentlyRejectedCount += 1
                    if consistentlyRejectedSamples.count < 20 {
                        consistentlyRejectedSamples.append(mangled)
                    }
                } else {
                    regressedSymbolCount += 1
                    if regressedSymbolSamples.count < 10 {
                        regressedSymbolSamples.append(mangled)
                    }
                }
            }
        }

        var mismatchCount = 0
        var mismatchSamples: [String] = []
        for (mangled, root) in rootBySymbol {
            let node: Node
            do {
                node = try demangleAsNodeTransient(mangled)
            } catch {
                oneSidedFailureCount += 1
                if oneSidedFailureSamples.count < 10 {
                    oneSidedFailureSamples.append("\(mangled) [store succeeded, transient failed]")
                }
                continue
            }
            if let divergingOptionSet = Self.comparePrints(node, store.reference(at: root)) {
                mismatchCount += 1
                if mismatchSamples.count < 10 {
                    mismatchSamples.append("\(mangled) [\(divergingOptionSet)]")
                }
            }
        }
        print("[0008-print-parity] symbols=\(rootBySymbol.count) optionSets=\(Self.optionSets.count) mismatches=\(mismatchCount) oneSidedFailures=\(oneSidedFailureCount) consistentlyRejected=\(consistentlyRejectedCount) regressed=\(regressedSymbolCount)")
        if !mismatchSamples.isEmpty {
            print("[0008-print-parity] samples: \(mismatchSamples.joined(separator: ", "))")
        }
        if !oneSidedFailureSamples.isEmpty {
            print("[0008-print-parity] one-sided failures: \(oneSidedFailureSamples.joined(separator: ", "))")
        }
        if !consistentlyRejectedSamples.isEmpty {
            print("[0008-print-parity] consistently rejected (stdlib fails these too): \(consistentlyRejectedSamples.joined(separator: ", "))")
        }
        if !regressedSymbolSamples.isEmpty {
            print("[0008-print-parity] regressed (stdlib demangles these, this library does not): \(regressedSymbolSamples.joined(separator: ", "))")
        }
        #expect(oneSidedFailureCount == 0, "both paths must agree on which symbols demangle")
        #expect(regressedSymbolCount == 0, "symbols the stdlib demangler handles must not fail here")
        #expect(mismatchCount == 0, "store-path printing must be byte-identical to the Node path")
    }
}
