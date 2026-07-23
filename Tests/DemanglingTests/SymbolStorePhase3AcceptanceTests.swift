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
final class SymbolStorePhase3AcceptanceTests: DyldCacheSymbolTests, @unchecked Sendable {
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

    /// Synchronous on purpose so the historical (interning) sync overload of
    /// `demangleAsNode` is selected as the throughput baseline.
    private static func runNodePathBaseline(_ corpus: [String]) -> Int {
        var failureCount = 0
        for mangled in corpus {
            do {
                _ = try demangleAsNode(mangled)
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
        var builder = SymbolStoreBuilder()
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

        #expect(storeFailureCount == nodePathFailureCount, "Both paths should fail on exactly the same symbols")
        // Corpus size varies by machine/OS build, so the storage target is
        // asserted per unit: <=16 bytes per unique node (design value 12 plus
        // edges/text amortization) and a per-symbol sanity budget.
        #expect(store.storageByteCount <= store.nodeCount * 16, "Flat storage should stay within 16 bytes per unique node")
        #expect(store.storageByteCount <= corpus.count * 64, "Flat storage should stay within 64 bytes per corpus symbol")
        #expect(storeBuildDuration < nodePathDuration * 2, "Store build should stay within the throughput budget")
    }
}
