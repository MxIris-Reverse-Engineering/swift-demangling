import Foundation
import Testing
@_spi(Internals) @testable import Demangling
@testable import DemanglingTestingSupport

/// Evolution 0010, step 4: the appendable shared interning arena.
///
/// The contract under test: `intern`/`demangle` return immediately usable,
/// permanently valid references; structurally equal trees resolve to one
/// reference across the store's whole lifetime (persistent hash-consing);
/// growth never invalidates anything already handed out; and the whole read
/// surface (printing, equality, traversal) behaves exactly as it does on a
/// frozen store.
@Suite struct SharedNodeStoreTests {
    /// A small, distinct name tree — built cache-free so tests do not grow
    /// the global `NodeCache` by thousands of synthetic leaves.
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

    private static let paritySymbols: [String] = [
        "$s4main8MyStructV6doWorkyySayAA9SomeThingVGF",
        "$s7Example11OtherThingsV7processyySDySSAA05InnerD0VGF",
        "$sSUss17FixedWidthIntegerRzrlEyxqd__cSzRd__lufCSu_SiTg5",
        "$s3use1xAA3OfPVy3lib1GVyAA1fQryFQOyQo_GAjE1PAAxAeKHD1_AIHO_HCg_Gvp",
        "$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF",
        "$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF",
    ]

    // MARK: - Interning semantics

    @Test func structurallyEqualTreesResolveToOneReference() {
        let sharedStore = SharedNodeStore()
        let firstReference = sharedStore.intern(Self.nameTree(42))
        let laterReference = sharedStore.intern(Self.nameTree(42))
        // Intrinsic ==: store identity + index — within one shared store this
        // is structural equality, exactly as within one frozen arena.
        #expect(firstReference == laterReference)
        #expect(Set([firstReference, laterReference]).count == 1)

        let differentReference = sharedStore.intern(Self.nameTree(43))
        #expect(firstReference != differentReference)
    }

    @Test func dedupPersistsAcrossInterveningInterns() {
        let sharedStore = SharedNodeStore()
        let earlyReference = sharedStore.intern(Self.nameTree(0))
        // Enough distinct trees to force several buffer growths in between.
        for treeIndex in 1 ..< 3000 {
            _ = sharedStore.intern(Self.nameTree(treeIndex))
        }
        let lateReference = sharedStore.intern(Self.nameTree(0))
        #expect(earlyReference == lateReference,
                "the interning tables must survive growth — freeze-style table dropping would mint a duplicate")
    }

    @Test func referencesSurviveGrowth() {
        let sharedStore = SharedNodeStore()
        let earlyReference = sharedStore.intern(Self.nameTree(0))
        let expectedPrint = earlyReference.print(using: .default)
        let expectedTree = earlyReference.materialize()

        for treeIndex in 1 ..< 3000 {
            _ = sharedStore.intern(Self.nameTree(treeIndex))
        }
        #expect(sharedStore.retiredBufferCountForTesting > 0,
                "the premise: growth actually happened and generations retired")

        // The early reference — minted against the very first generation —
        // must still resolve through the current view: same print, same
        // structure.
        #expect(earlyReference.print(using: .default) == expectedPrint)
        #expect(earlyReference.structurallyEquals(expectedTree))
    }

    @Test func reservationKeepsTheRetirementChainEmpty() {
        let sharedStore = SharedNodeStore()
        // The 0009 coefficients are calibrated per real-corpus symbol (heavy
        // text dedup, ~2.2 text bytes each); these synthetic name trees carry
        // ~12 unique text bytes apiece, so the reservation must be sized for
        // that ratio — an undersized reservation correctly degrades to
        // growth, which is exactly what this test must rule out.
        sharedStore.reserveCapacity(expectedSymbolCount: 30_000)
        var references: [NodeReference] = []
        for treeIndex in 0 ..< 3000 {
            references.append(sharedStore.intern(Self.nameTree(treeIndex)))
        }
        #expect(sharedStore.retiredBufferCountForTesting == 0,
                "a sufficient up-front reservation means growth never happens, so nothing retires")
        // Reservation must not change interning results.
        let unreservedStore = SharedNodeStore()
        for treeIndex in 0 ..< 3000 {
            let unreservedReference = unreservedStore.intern(Self.nameTree(treeIndex))
            #expect(references[treeIndex].structurallyEquals(unreservedReference))
        }
    }

    @Test func referencesOutliveTheSharedStore() {
        var survivingReference: NodeReference?
        var expectedPrint = ""
        do {
            let sharedStore = SharedNodeStore()
            let reference = sharedStore.intern(Self.nameTree(7))
            expectedPrint = reference.print(using: .default)
            survivingReference = reference
        }
        // The SharedNodeStore (and with it the writer) is gone; the reference
        // keeps the backing NodeStore — and through it every buffer
        // generation — alive.
        let reference = survivingReference!
        #expect(reference.print(using: .default) == expectedPrint)
        #expect(reference.kind == .global)
    }

    // MARK: - Read-surface parity with the established paths

    @Test(arguments: paritySymbols)
    func sharedStorePrintingMatchesTheNodePath(symbol: String) throws {
        let sharedStore = SharedNodeStore()
        let reference = try sharedStore.demangle(symbol)
        let nodeTree = try demangleAsNodeTransient(symbol)
        for options in [DemangleOptions.default, .simplified, .default.union(.synthesizeSugarOnTypes)] {
            #expect(reference.print(using: options) == nodeTree.print(using: options))
        }
    }

    @Test(arguments: paritySymbols)
    func sharedStoreDemangleMatchesTheFrozenBuilderPath(symbol: String) throws {
        let sharedStore = SharedNodeStore()
        let sharedReference = try sharedStore.demangle(symbol)

        var builder = NodeStoreBuilder()
        let rootIndex = try builder.demangle(symbol)
        let frozenReference = builder.freeze().reference(at: rootIndex)

        #expect(sharedReference.structurallyEquals(frozenReference))
    }

    @Test func capacityUtilizationReportsLiveState() {
        let sharedStore = SharedNodeStore()
        _ = sharedStore.intern(Self.nameTree(1))
        let utilization = sharedStore.capacityUtilization
        #expect(utilization.nodes.usedCount > 0)
        #expect(utilization.nodes.usedCount <= utilization.nodes.capacity)
        #expect(sharedStore.nodeCount == utilization.nodes.usedCount)
        #expect(sharedStore.storageByteCount > 0)
    }

    // MARK: - Concurrency

    /// Writers intern overlapping symbol sets while readers print and
    /// structurally compare references already handed out. Run under TSan for
    /// the 0010 acceptance (`swift test --sanitize=thread --filter
    /// SharedNodeStoreTests`); in a plain run it still pins the functional
    /// half: cross-thread dedup (same tree from two writers resolves to one
    /// reference) and read consistency during concurrent growth.
    @Test func concurrentInternAndReadStaysConsistent() async {
        let sharedStore = SharedNodeStore()
        let writerCount = 4
        let treesPerWriter = 400

        let referencesByWriter = await withTaskGroup(of: [Int: NodeReference].self) { group in
            for writerIndex in 0 ..< writerCount {
                group.addTask {
                    var minted: [Int: NodeReference] = [:]
                    for step in 0 ..< treesPerWriter {
                        // Overlapping ranges: every tree is interned by two
                        // writers, so cross-thread dedup is exercised on
                        // every step.
                        let treeIndex = (writerIndex % 2) * (treesPerWriter / 2) + step
                        let reference = sharedStore.intern(Self.nameTree(treeIndex))
                        minted[treeIndex] = reference

                        // Read while other writers keep growing the store.
                        if step % 16 == 0 {
                            _ = reference.print(using: .default)
                        }
                    }
                    return minted
                }
            }
            var merged: [[Int: NodeReference]] = []
            for await minted in group {
                merged.append(minted)
            }
            return merged
        }

        // Cross-thread dedup: wherever two writers interned the same index,
        // they must hold the identical reference.
        var canonicalByIndex: [Int: NodeReference] = [:]
        for minted in referencesByWriter {
            for (treeIndex, reference) in minted {
                if let canonical = canonicalByIndex[treeIndex] {
                    #expect(canonical == reference,
                            "two writers interning one structure received different references")
                } else {
                    canonicalByIndex[treeIndex] = reference
                }
            }
        }
        // And every reference still reads correctly after all growth settled.
        for (treeIndex, reference) in canonicalByIndex {
            #expect(reference.structurallyEquals(Self.nameTree(treeIndex)))
        }
    }

    // MARK: - Debug provenance

    #if DEBUG
    /// The 0009 issuance-tag check must hold for the shared store's identity
    /// anchor exactly as for frozen stores: an in-range foreign index traps
    /// instead of silently resolving.
    @Test func foreignIndexIntoSharedStoreTraps() async {
        await #expect(processExitsWith: .failure) {
            var foreignBuilder = NodeStoreBuilder()
            let foreignIndex = foreignBuilder.intern(kind: .identifier, text: "foreign")
            let sharedStore = SharedNodeStore()
            _ = sharedStore.intern(Node.createTransient(kind: .identifier, text: "occupant of index zero"))
            // In range for the shared store, so only the issuance-tag check
            // can catch it.
            _ = sharedStore.backingStore.reference(at: foreignIndex)
        }
    }
    #endif
}

/// Corpus leg of the 0010 acceptance: shared-store printing must be
/// byte-identical to the `Node` path across the print corpus, exactly like
/// the frozen-store sweep (0008). Env-gated with the same switch; run in
/// release, once per runtime path:
///
/// ```
/// DEMANGLING_PRINT_PARITY=1 swift test -c release --filter SharedStorePrintParitySweep
/// DEMANGLING_PRINT_PARITY=1 DEMANGLING_FORCE_LEGACY_PATH=1 swift test -c release --filter SharedStorePrintParitySweep
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEMANGLING_PRINT_PARITY"] == "1"), .serialized)
final class SharedStorePrintParitySweep: DyldCacheSymbolTests, @unchecked Sendable {
    private static let optionSets: [(name: String, options: DemangleOptions)] = [
        ("default", .default),
        ("simplified", .simplified),
        ("sugared", .default.union(.synthesizeSugarOnTypes)),
    ]

    /// Synchronous so the sync `print(using:)` overloads — the walks under
    /// test — are the ones selected inside this async test.
    private static func comparePrints(_ node: Node, _ reference: NodeReference) -> String? {
        for (name, options) in optionSets {
            if node.print(using: options) != reference.print(using: options) {
                return name
            }
        }
        return nil
    }

    @Test func sharedStorePrintingMatchesNodePathAcrossCorpus() async throws {
        let extracted = try await symbols(for: .SwiftUI, .SwiftUICore, .Foundation, .Combine)
        let corpus = Array(Set(extracted.map(\.stringValue))).sorted()
        try #require(!corpus.isEmpty, "print corpus unavailable on this machine")

        let sharedStore = SharedNodeStore()
        sharedStore.reserveCapacity(expectedSymbolCount: corpus.count)

        var comparedCount = 0
        var mismatchCount = 0
        var mismatchSamples: [String] = []
        for mangled in corpus {
            guard let reference = try? sharedStore.demangle(mangled),
                  let node = try? demangleAsNodeTransient(mangled) else { continue }
            comparedCount += 1
            if let divergingOptionSet = Self.comparePrints(node, reference) {
                mismatchCount += 1
                if mismatchSamples.count < 10 {
                    mismatchSamples.append("\(mangled) [\(divergingOptionSet)]")
                }
            }
        }
        print("[0010-shared-print-parity] symbols=\(comparedCount) optionSets=\(Self.optionSets.count) mismatches=\(mismatchCount) retiredBuffers=\(sharedStore.retiredBufferCountForTesting)")
        if !mismatchSamples.isEmpty {
            print("[0010-shared-print-parity] samples: \(mismatchSamples.joined(separator: ", "))")
        }
        #expect(mismatchCount == 0, "shared-store printing must be byte-identical to the Node path")
    }
}
