import Foundation
import Testing
@testable import Demangling

#if DEBUG
/// Debug-build validation of `NodeIndex` issuance tags (proposal 0009,
/// part B): an index minted by one builder must fail the tag precondition
/// deterministically when it crosses into another builder or store, instead
/// of silently resolving in-range — the worst of the three failure shapes
/// evolution 0001 recorded for foreign indices. Release builds compile the
/// tag out entirely, so this suite exists only in debug configurations
/// (release behavior is covered by the pre-0009 suites, which are unchanged).
@Suite struct NodeIndexProvenanceTests {
    @Test func indicesRemainValidAcrossFreeze() throws {
        var builder = NodeStoreBuilder()
        let rootIndex = try builder.demangle("$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF")
        let store = builder.freeze()
        #expect(store.reference(at: rootIndex).kind == .global)
    }

    @Test func crossBuilderChildIndexTraps() async {
        await #expect(processExitsWith: .failure) {
            var foreignBuilder = NodeStoreBuilder()
            let foreignIndex = foreignBuilder.intern(kind: .identifier, text: "foreign")
            var localBuilder = NodeStoreBuilder()
            _ = localBuilder.intern(kind: .identifier, text: "occupant of index zero")
            // In range for localBuilder (raw index 0 < 1 node), so only the
            // issuance-tag check can catch it.
            _ = localBuilder.intern(kind: .type, children: [foreignIndex])
        }
    }

    @Test func crossStoreReferenceTraps() async {
        await #expect(processExitsWith: .failure) {
            var foreignBuilder = NodeStoreBuilder()
            let foreignIndex = foreignBuilder.intern(kind: .identifier, text: "foreign")
            var localBuilder = NodeStoreBuilder()
            _ = localBuilder.intern(kind: .identifier, text: "occupant of index zero")
            let localStore = localBuilder.freeze()
            // In range for localStore, so only the issuance-tag check can
            // catch it.
            _ = localStore.reference(at: foreignIndex)
        }
    }
}
#endif
