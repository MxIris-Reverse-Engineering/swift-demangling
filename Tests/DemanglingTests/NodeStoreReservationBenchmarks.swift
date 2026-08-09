import Foundation
import Testing
@_spi(Internals) @testable import Demangling
@testable import DemanglingTestingSupport

/// Release-build acceptance benchmark for proposal 0009 (part A): builds the
/// store corpus with and without `reserveCapacity(expectedSymbolCount:)` and
/// reports, per mode:
///
/// - wall time (best of the timed passes),
/// - gross allocation events (`MallocCounter`, final pass),
/// - large-allocation events (≥ 1 MiB — buffer-regrowth copies live here,
///   invisible in the tens of millions of total events),
/// - sampled peak physical-footprint growth during the **cold pass** (the
///   first build in the process) and during the final pass,
/// - and the capacity-utilization report the coefficients are calibrated
///   against.
///
/// The footprint comparison is only meaningful across **separate
/// processes**: after the first build, freed pages stay resident and the
/// allocator reuses them, so regrowth spikes in later passes never reach
/// `phys_footprint`. Select one mode per process with
/// `DEMANGLING_RESERVATION_MODE=unreserved|reserved` (default: both in one
/// process, which still measures time and allocation events faithfully).
///
/// Deliberately opt-in (`DEMANGLING_BENCHMARK=1`) and only meaningful in
/// release:
///
/// ```
/// DEMANGLING_BENCHMARK=1 DEMANGLING_RESERVATION_MODE=unreserved swift test -c release --filter NodeStoreReservationBenchmarks
/// DEMANGLING_BENCHMARK=1 DEMANGLING_RESERVATION_MODE=reserved swift test -c release --filter NodeStoreReservationBenchmarks
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEMANGLING_BENCHMARK"] == "1"), .serialized)
final class NodeStoreReservationBenchmarks: DyldCacheSymbolTests, @unchecked Sendable {
    private static let timedPassCount = 3

    /// Buffer-regrowth copies on this corpus are multi-megabyte; per-symbol
    /// scratch allocations stay far below this.
    private static let largeAllocationThresholdBytes: UInt64 = 1 << 20

    /// Same image set as the 0008 store-build benchmark (the "234k corpus"
    /// lineage), so numbers stay comparable across proposals.
    private func storeCorpus() async throws -> [String] {
        let extracted = try await symbols(for: .AppKit, .UIKitCore, .SwiftUI, .SwiftUICore, .AttributeGraph, .Foundation, .Combine)
        return Array(Set(extracted.map(\.stringValue))).sorted()
    }

    /// Modes to run in this process; see the suite comment for why footprint
    /// comparisons want one mode per process.
    private static var selectedModes: [Bool] {
        switch ProcessInfo.processInfo.environment["DEMANGLING_RESERVATION_MODE"] {
        case "unreserved": return [false]
        case "reserved": return [true]
        default: return [false, true]
        }
    }

    @Test func reservedVersusUnreservedBuild() async throws {
        let corpus = try await storeCorpus()
        try #require(!corpus.isEmpty, "store corpus unavailable on this machine")
        MallocCounter.setLargeAllocationThreshold(Self.largeAllocationThresholdBytes)

        // Measurement inside the cross-suite exclusive window
        // (ReviewFindingsPR7 F13); the corpus load above stays outside.
        ExclusiveMeasurementWindow.run {
        for reservesCapacity in Self.selectedModes {
            let modeName = reservesCapacity ? "reserved" : "unreserved"
            var durations: [Duration] = []
            var allocationEventCount: UInt64 = 0
            var largeAllocationEventCount: UInt64 = 0
            var coldPassFootprintGrowth: UInt64 = 0
            var finalPassFootprintGrowth: UInt64 = 0
            var utilizationReport = ""
            for passIndex in 0 ..< (Self.timedPassCount + 1) {
                let isColdPass = passIndex == 0
                let isFinalPass = passIndex == Self.timedPassCount
                let footprintSampler = PhysicalFootprintSampler()
                if isColdPass { footprintSampler.start() }
                if isFinalPass {
                    // Sampler before counter: its thread creation (stack,
                    // lock context) must not land inside the malloc window.
                    // The stop order below keeps the other end clean too —
                    // the counter stops first, so the sampler's thread join
                    // never enters the window either (ReviewFindingsPR7 F13;
                    // the review suggested stopping the sampler first, which
                    // would put the join's allocations back in the window —
                    // the footprint peak is insensitive to stop order, so
                    // malloc purity wins).
                    footprintSampler.start()
                    MallocCounter.start()
                }
                let start = ContinuousClock.now
                var builder = NodeStoreBuilder()
                if reservesCapacity {
                    builder.reserveCapacity(expectedSymbolCount: corpus.count)
                }
                for mangled in corpus {
                    _ = try? builder.demangle(mangled)
                }
                if isFinalPass {
                    utilizationReport = Self.format(builder.capacityUtilization)
                }
                let store = builder.freeze()
                if !isColdPass { durations.append(ContinuousClock.now - start) }
                if isColdPass {
                    coldPassFootprintGrowth = footprintSampler.stop()
                }
                if isFinalPass {
                    allocationEventCount = MallocCounter.stop()
                    largeAllocationEventCount = MallocCounter.largeAllocationEventCount
                    finalPassFootprintGrowth = footprintSampler.stop()
                }
                withExtendedLifetime(store) {}
            }

            let secondsPerPass = durations.map { Double($0.components.seconds) + Double($0.components.attoseconds) * 1e-18 }
            let bestSeconds = secondsPerPass.min() ?? .nan
            print(
                "[0009-benchmark] store-build(\(modeName)): symbols=\(corpus.count)"
                    + " passes=\(secondsPerPass.map { String(format: "%.3fs", $0) }.joined(separator: ", "))"
                    + " best=\(String(format: "%.3fs", bestSeconds))"
                    + " mallocs=\(allocationEventCount)"
                    + " largeAllocations(≥1MiB)=\(largeAllocationEventCount)"
                    + " coldPassFootprintGrowth=\(String(format: "%.1f", Double(coldPassFootprintGrowth) / 1_048_576)) MiB"
                    + " finalPassFootprintGrowth=\(String(format: "%.1f", Double(finalPassFootprintGrowth) / 1_048_576)) MiB"
            )
            print("[0009-benchmark] store-build(\(modeName)) utilization: \(utilizationReport)")
        }
        }
    }

    private static func format(_ utilization: NodeStoreBuilder.CapacityUtilization) -> String {
        func formatBuffer(_ name: String, _ buffer: NodeStoreBuilder.CapacityUtilization.BufferUtilization) -> String {
            "\(name)=\(buffer.usedCount)/\(buffer.capacity) (\(String(format: "%.0f", buffer.utilization * 100))%)"
        }
        return [
            formatBuffer("nodes", utilization.nodes),
            formatBuffer("edges", utilization.edges),
            formatBuffer("textBytes", utilization.textBytes),
            formatBuffer("compactSlots", utilization.compactInternSlots),
            formatBuffer("manyChildrenSlots", utilization.manyChildrenInternSlots),
            formatBuffer("textSlots", utilization.textInternSlots),
            formatBuffer("uniqueTexts", utilization.uniqueTexts),
        ].joined(separator: " ")
    }
}
