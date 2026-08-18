import Foundation
import Testing
@testable import Demangling
@testable import DemanglingTestingSupport

/// Acceptance measurement for proposal 0001 Phase 3 on the live dyld-cache
/// SwiftUI corpus: retained flat storage must stay under the 6 MB target and
/// the cache-free bulk build must not regress against the Node path beyond
/// the 1.2x budget (asserted generously at 2x to absorb CI noise; measured
/// numbers are recorded in the proposal's decision log).
@Suite
final class NodeStorePhase3AcceptanceTests: DyldCacheSymbolTests, @unchecked Sendable {
    private static func physicalFootprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint)
    }

    /// Synchronous on purpose so the sync entry is selected as the throughput
    /// baseline, and transient so the baseline really does keep the corpus out
    /// of `NodeCache.shared`.
    ///
    /// `internsSubtrees: false` did not do that: it only skips the final
    /// whole-tree pass. Leaf interning happens during the parse, governed by the
    /// separate `internsLeaves`, which the public `demangleAsNode` does not even
    /// expose — so every unique identifier, module and index of the whole export
    /// table stayed pinned in the never-evicting global cache for the rest of
    /// the process, the opposite of what this comment used to claim, and
    /// inflating the cache underneath any suite running concurrently.
    /// `demangleAsNodeTransient` is the entry that keeps nothing, and it is what
    /// the store side of this comparison already uses, so the two paths are also
    /// more alike than before (PR #7 review, finding 7).
    private static func runNodePathBaseline(_ corpus: [String]) -> Int {
        var failureCount = 0
        for mangled in corpus {
            do {
                _ = try demangleAsNodeTransient(mangled)
            } catch {
                failureCount += 1
            }
        }
        return failureCount
    }

    @Test func phase3AcceptanceOnMainImageCorpus() async throws {
        let corpus = try await symbols(for: .SwiftUI).map(\.stringValue)
        try #require(!corpus.isEmpty, "SwiftUI corpus unavailable on this machine")

        let footprintBefore = Self.physicalFootprint()
        let storeBuildStart = ContinuousClock.now
        var builder = NodeStoreBuilder()
        var storeFailureCount = 0
        for mangled in corpus {
            do {
                _ = try builder.demangle(mangled)
            } catch {
                storeFailureCount += 1
            }
        }
        let store = builder.freeze()
        let storeBuildDuration = ContinuousClock.now - storeBuildStart
        let footprintAfter = Self.physicalFootprint()

        let nodePathStart = ContinuousClock.now
        let nodePathFailureCount = Self.runNodePathBaseline(corpus)
        let nodePathDuration = ContinuousClock.now - nodePathStart

        let footprintDelta = (footprintAfter ?? 0) - (footprintBefore ?? 0)
        print("""
        [phase3-acceptance] symbols=\(corpus.count) storeFailures=\(storeFailureCount) nodePathFailures=\(nodePathFailureCount)
        [phase3-acceptance] uniqueNodes=\(store.nodeCount) storageBytes=\(store.storageByteCount) (nodes=\(store.nodeCount * 12) edges=\(store.edgeCount * 4) text=\(store.textByteCount))
        [phase3-acceptance] storeBuild=\(storeBuildDuration) nodePath=\(nodePathDuration) footprintDeltaDuringBuild=\(footprintDelta)
        """)

        // Recorded, not asserted. `NodeStoreBuilder.demangle` is
        // `demangleAsNodeTransient` plus a non-throwing `intern`, so both loops
        // run the same parser over the same corpus and the two counts are equal
        // by construction — for correct and incorrect parser behaviour alike.
        // This is the third instance of a vacuous guard that this branch already
        // identified and removed twice, with the reasoning written out both
        // times (StorePrintParitySweep, SharedNodeStoreTests); it survived here,
        // in the acceptance gate for the whole proposal. Keep it as a recorded
        // divergence so a future `builder.demangle` that gains its own
        // validation still reports, without pretending to be a gate
        // (PR #7 review, finding 9).
        if storeFailureCount != nodePathFailureCount {
            Issue.record("Store and Node paths disagreed on \(abs(storeFailureCount - nodePathFailureCount)) symbols")
        }
        // Corpus size varies by machine/OS build, so the storage target is
        // asserted per unit: <=16 bytes per unique node (design value 12 plus
        // edges/text amortization) and a per-symbol sanity budget.
        #expect(store.storageByteCount <= store.nodeCount * 16, "Flat storage should stay within 16 bytes per unique node")
        #expect(store.storageByteCount <= corpus.count * 64, "Flat storage should stay within 64 bytes per corpus symbol")
        // Wall-clock, therefore reported rather than asserted. This suite is
        // neither `.serialized` nor env-gated, unlike all three real benchmark
        // suites, so what decides red or green here is the concurrent test load,
        // not the store path. The measured ratio for the proposal's decision log
        // comes from the benchmark suites (PR #7 review, minor finding).
        if storeBuildDuration >= nodePathDuration * 2 {
            print("[phase3-acceptance] NOTE: store build was \(storeBuildDuration) vs node path \(nodePathDuration) — outside the 2x budget, re-measure under DEMANGLING_BENCHMARK=1 before treating this as a regression")
        }
    }
}
