import Foundation
import Testing
@_spi(Internals) @testable import Demangling
@testable import DemanglingTestingSupport

/// Release-build baselines for proposal 0008 (Phase 0 gate). Three benchmarks:
///
/// 1. pure demangle throughput on the print corpus (String → transient tree),
/// 2. `NodeStoreBuilder.demangle` end-to-end build on the store corpus,
/// 3. store-path print throughput on the print corpus × 3 option sets,
///
/// each with a gross allocation count from `MallocCounter` on the final timed
/// pass. Corpus sizes vary with the machine's dyld shared cache, so recorded
/// numbers always carry the symbol count alongside.
///
/// Deliberately opt-in (`DEMANGLING_BENCHMARK=1`) and only meaningful in
/// release:
///
/// ```
/// DEMANGLING_BENCHMARK=1 swift test -c release --filter SpanBorrowedViewsBenchmarks
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEMANGLING_BENCHMARK"] == "1"), .serialized)
final class SpanBorrowedViewsBenchmarks: DyldCacheSymbolTests, @unchecked Sendable {
    private static let timedPassCount = 3

    /// The demangle/print corpus (historically "the 49k corpus"): exported
    /// Swift symbols of the SwiftUI-family images plus Foundation and Combine,
    /// deduplicated and sorted so the workload is deterministic per machine.
    private func printCorpus() async throws -> [String] {
        let extracted = try await symbols(for: .SwiftUI, .SwiftUICore, .Foundation, .Combine)
        return Array(Set(extracted.map(\.stringValue))).sorted()
    }

    /// The bulk-build corpus (historically "the 234k corpus"): the print
    /// corpus images plus the large AppKit/UIKitCore surfaces.
    private func storeCorpus() async throws -> [String] {
        let extracted = try await symbols(for: .AppKit, .UIKitCore, .SwiftUI, .SwiftUICore, .AttributeGraph, .Foundation, .Combine)
        return Array(Set(extracted.map(\.stringValue))).sorted()
    }

    private static func reportPasses(_ label: String, corpus: [String], durations: [Duration], allocationEventCount: UInt64) {
        let secondsPerPass = durations.map { Double($0.components.seconds) + Double($0.components.attoseconds) * 1e-18 }
        let bestSeconds = secondsPerPass.min() ?? .nan
        let throughput = Double(corpus.count) / bestSeconds
        let allocationsPerSymbol = Double(allocationEventCount) / Double(corpus.count)
        print("[0008-benchmark] \(label): symbols=\(corpus.count) passes=\(secondsPerPass.map { String(format: "%.3fs", $0) }.joined(separator: ", ")) best=\(String(format: "%.3fs", bestSeconds)) throughput=\(String(format: "%.0f", throughput)) symbols/s mallocs/symbol=\(String(format: "%.1f", allocationsPerSymbol)) (final pass)")
    }

    @Test func demangleThroughputOnTransientTrees() async throws {
        let corpus = try await printCorpus()
        try #require(!corpus.isEmpty, "print corpus unavailable on this machine")

        var failureCount = 0
        for mangled in corpus {
            _ = try? demangleAsNodeTransient(mangled)
        }
        var durations: [Duration] = []
        var allocationEventCount: UInt64 = 0
        for passIndex in 0 ..< Self.timedPassCount {
            let isFinalPass = passIndex == Self.timedPassCount - 1
            if isFinalPass { MallocCounter.start() }
            let start = ContinuousClock.now
            for mangled in corpus {
                do {
                    _ = try demangleAsNodeTransient(mangled)
                } catch {
                    failureCount += 1
                }
            }
            durations.append(ContinuousClock.now - start)
            if isFinalPass { allocationEventCount = MallocCounter.stop() }
        }
        Self.reportPasses("demangle-transient", corpus: corpus, durations: durations, allocationEventCount: allocationEventCount)
        print("[0008-benchmark] demangle-transient: failures/pass=\(failureCount / Self.timedPassCount)")
    }

    @Test func storeBuildEndToEnd() async throws {
        let corpus = try await storeCorpus()
        try #require(!corpus.isEmpty, "store corpus unavailable on this machine")

        var durations: [Duration] = []
        var allocationEventCount: UInt64 = 0
        var reportedStoreDescription = ""
        for passIndex in 0 ..< (Self.timedPassCount + 1) {
            let isWarmup = passIndex == 0
            let isFinalPass = passIndex == Self.timedPassCount
            if isFinalPass { MallocCounter.start() }
            let start = ContinuousClock.now
            var builder = NodeStoreBuilder()
            var failureCount = 0
            for mangled in corpus {
                do {
                    _ = try builder.demangle(mangled)
                } catch {
                    failureCount += 1
                }
            }
            let store = builder.freeze()
            if !isWarmup { durations.append(ContinuousClock.now - start) }
            if isFinalPass {
                allocationEventCount = MallocCounter.stop()
                reportedStoreDescription = "uniqueNodes=\(store.nodeCount) storageBytes=\(store.storageByteCount) failures=\(failureCount)"
            }
        }
        Self.reportPasses("store-build", corpus: corpus, durations: durations, allocationEventCount: allocationEventCount)
        print("[0008-benchmark] store-build: \(reportedStoreDescription)")
    }

    @Test func storePrintThroughput() async throws {
        let corpus = try await printCorpus()
        try #require(!corpus.isEmpty, "print corpus unavailable on this machine")

        var builder = NodeStoreBuilder()
        var rootIndices: [NodeStore.NodeIndex] = []
        rootIndices.reserveCapacity(corpus.count)
        for mangled in corpus {
            if let rootIndex = try? builder.demangle(mangled) {
                rootIndices.append(rootIndex)
            }
        }
        let store = builder.freeze()

        let optionSets: [(name: String, options: DemangleOptions)] = [
            ("default", .default),
            ("simplified", .simplified),
            ("sugared", .default.union(.synthesizeSugarOnTypes)),
        ]
        for (name, options) in optionSets {
            var checksum = Self.printAllRoots(rootIndices, store: store, options: options)
            var durations: [Duration] = []
            var allocationEventCount: UInt64 = 0
            for passIndex in 0 ..< Self.timedPassCount {
                let isFinalPass = passIndex == Self.timedPassCount - 1
                if isFinalPass { MallocCounter.start() }
                let start = ContinuousClock.now
                checksum &+= Self.printAllRoots(rootIndices, store: store, options: options)
                durations.append(ContinuousClock.now - start)
                if isFinalPass { allocationEventCount = MallocCounter.stop() }
            }
            Self.reportPasses("store-print(\(name))", corpus: corpus, durations: durations, allocationEventCount: allocationEventCount)
            withExtendedLifetime(checksum) {}
        }
    }

    /// Synchronous on purpose so the sync overload of `print(using:)` is the
    /// one measured (the async test body would otherwise select the async
    /// overload, which suspends per symbol).
    private static func printAllRoots(_ rootIndices: [NodeStore.NodeIndex], store: NodeStore, options: DemangleOptions) -> Int {
        var checksum = 0
        for rootIndex in rootIndices {
            checksum &+= store.reference(at: rootIndex).print(using: options).utf8.count
        }
        return checksum
    }
}
