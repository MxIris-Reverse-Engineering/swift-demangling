import Foundation
import Testing
@_spi(Internals) @testable import Demangling
@testable import DemanglingTestingSupport

/// Release-build acceptance benchmark for proposal 0010 (step 5): the
/// incremental name-tree workload — the shape the shared store exists for —
/// built the pre-0010 way (one private mini store per unique tree, which is
/// what downstream dedup caches achieved on top of
/// `NodeReference(interning:)`) versus one `SharedNodeStore`.
///
/// The workload mirrors the measured downstream shape: ~14k structurally
/// unique name trees (RV's five-image memory graph counted 14,451 retained
/// `NodeStore` instances) arriving one at a time, each requested more than
/// once (MachOSwiftSection measured 730 requests over 472 unique trees).
///
/// Footprint growth is only meaningful for the first mode a process runs;
/// select one with `DEMANGLING_SHARED_STORE_MODE=mini|shared` (default: both
/// in one process, which still measures time and allocation events
/// faithfully).
///
/// ```
/// DEMANGLING_BENCHMARK=1 DEMANGLING_SHARED_STORE_MODE=mini swift test -c release --filter SharedNodeStoreBenchmarks
/// DEMANGLING_BENCHMARK=1 DEMANGLING_SHARED_STORE_MODE=shared swift test -c release --filter SharedNodeStoreBenchmarks
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEMANGLING_BENCHMARK"] == "1"), .serialized)
struct SharedNodeStoreBenchmarks {
    private static let timedPassCount = 3
    private static let uniqueTreeCount = 14_000
    private static let occurrencesPerTree = 2

    private static var selectedModes: [Bool] {
        switch ProcessInfo.processInfo.environment["DEMANGLING_SHARED_STORE_MODE"] {
        case "mini": return [false]
        case "shared": return [true]
        default: return [false, true]
        }
    }

    /// The same synthetic name-tree shape as `SharedNodeStoreTests`: ~6 nodes
    /// and ~12 unique text bytes per tree, built cache-free so the benchmark
    /// measures store residency, not `NodeCache` growth.
    private static func nameTree(_ index: Int) -> Node {
        Node.createTransient(kind: .global, children: [
            Node.createTransient(kind: .typeMangling, children: [
                Node.createTransient(kind: .type, children: [
                    Node.createTransient(kind: .structure, children: [
                        Node.createTransient(kind: .module, text: "TestModule\(index % 7)"),
                        Node.createTransient(kind: .identifier, text: "TypeName\(index)"),
                    ]),
                ]),
            ]),
        ])
    }

    @Test func miniStoresVersusSharedStore() {
        // Trees are built once, outside every timed region: both modes intern
        // the same instances, and tree construction is not what is measured.
        let uniqueTrees = (0 ..< Self.uniqueTreeCount).map { Self.nameTree($0) }

        // Measurement inside the cross-suite exclusive window
        // (ReviewFindingsPR7 F13).
        ExclusiveMeasurementWindow.run {
        for usesSharedStore in Self.selectedModes {
            let modeName = usesSharedStore ? "shared" : "mini-stores"
            var durations: [Duration] = []
            var allocationEventCount: UInt64 = 0
            var coldPassFootprintGrowth: UInt64 = 0
            var retainedDescription = ""

            for passIndex in 0 ..< (Self.timedPassCount + 1) {
                let isColdPass = passIndex == 0
                let isFinalPass = passIndex == Self.timedPassCount
                let footprintSampler = PhysicalFootprintSampler()
                // The pass body can throw between start() and stop(); a sampler
                // left running keeps a 2 kHz polling thread alive for the rest
                // of the process and leaves `malloc_logger` on the counting
                // hook, degrading every later measurement. A second stop() is a
                // documented no-op returning 0 (PR #7 review, finding 11).
                defer { _ = footprintSampler.stop() }
                if isColdPass { footprintSampler.start() }
                if isFinalPass { MallocCounter.start() }

                let start = ContinuousClock.now
                var retainedReferences: [NodeReference] = []
                retainedReferences.reserveCapacity(Self.uniqueTreeCount * Self.occurrencesPerTree)

                if usesSharedStore {
                    let sharedStore = SharedNodeStore()
                    sharedStore.reserveCapacity(expectedSymbolCount: Self.uniqueTreeCount * 3)
                    for _ in 0 ..< Self.occurrencesPerTree {
                        for tree in uniqueTrees {
                            retainedReferences.append(sharedStore.intern(tree))
                        }
                    }
                    if isFinalPass {
                        let uniqueStoreCount = Set(retainedReferences.map { ObjectIdentifier($0.store) }).count
                        retainedDescription = "storeInstances=\(uniqueStoreCount)"
                            + " storageBytes=\(sharedStore.storageByteCount)"
                            + " nodeCount=\(sharedStore.nodeCount)"
                            + " retiredBuffers=\(sharedStore.retiredBufferCountForTesting)"
                    }
                } else {
                    // The pre-0010 downstream shape: a structural-hash cache
                    // in front of `NodeReference(interning:)` — repeats hand
                    // back the previously minted reference, so the retained
                    // population is one mini store per *unique* tree (the
                    // best case the workaround achieves).
                    var mintedByStructuralHash: [Int: [NodeReference]] = [:]
                    for _ in 0 ..< Self.occurrencesPerTree {
                        for tree in uniqueTrees {
                            var hasher = Hasher()
                            hasher.combine(tree)
                            let structuralHashValue = hasher.finalize()
                            if let existing = mintedByStructuralHash[structuralHashValue]?.first(where: { $0.structurallyEquals(tree) }) {
                                retainedReferences.append(existing)
                            } else {
                                let minted = NodeReference(interning: tree)
                                mintedByStructuralHash[structuralHashValue, default: []].append(minted)
                                retainedReferences.append(minted)
                            }
                        }
                    }
                    if isFinalPass {
                        let uniqueStores = Set(retainedReferences.map { ObjectIdentifier($0.store) })
                        let totalStorageBytes = mintedByStructuralHash.values.joined().reduce(0) { $0 + $1.store.storageByteCount }
                        retainedDescription = "storeInstances=\(uniqueStores.count) storageBytes=\(totalStorageBytes)"
                    }
                }

                if !isColdPass { durations.append(ContinuousClock.now - start) }
                if isColdPass { coldPassFootprintGrowth = footprintSampler.stop() }
                if isFinalPass { allocationEventCount = MallocCounter.stop() }
                withExtendedLifetime(retainedReferences) {}
            }

            let secondsPerPass = durations.map { Double($0.components.seconds) + Double($0.components.attoseconds) * 1e-18 }
            let bestSeconds = secondsPerPass.min() ?? .nan
            print(
                "[0010-benchmark] incremental(\(modeName)): uniqueTrees=\(Self.uniqueTreeCount)"
                    + " occurrences=\(Self.uniqueTreeCount * Self.occurrencesPerTree)"
                    + " passes=\(secondsPerPass.map { String(format: "%.3fs", $0) }.joined(separator: ", "))"
                    + " best=\(String(format: "%.3fs", bestSeconds))"
                    + " mallocs=\(allocationEventCount)"
                    + " coldPassFootprintGrowth=\(String(format: "%.1f", Double(coldPassFootprintGrowth) / 1_048_576)) MiB"
                    + " \(retainedDescription)"
            )
        }
        }
    }
}
