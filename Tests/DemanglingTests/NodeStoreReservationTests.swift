import Foundation
import Testing
@testable import Demangling

/// Functional coverage for `NodeStoreBuilder.reserveCapacity` and
/// `capacityUtilization` (proposal 0009, part A): reserving must pre-size the
/// buffers without changing any interning result, and the utilization report
/// must expose enough to re-calibrate the sizing coefficients.
@Suite struct NodeStoreReservationTests {
    private static let sampleSymbols = [
        "$s7SwiftUI18DynamicViewContentPAAE8onDelete7performQrys8IndexSetVcSg_tF",
        "$s7SwiftUI4ViewPAAE7paddingyQrAA4EdgeO3SetV_12CoreGraphics7CGFloatVSgtF",
        "$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF",
        "$s7SwiftUI15ModifiedContentVyxq_GAA0D0AAMc",
        "$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC",
    ]

    @Test func reservedBuildMatchesUnreservedBuild() throws {
        var unreservedBuilder = NodeStoreBuilder()
        var reservedBuilder = NodeStoreBuilder()
        reservedBuilder.reserveCapacity(expectedSymbolCount: Self.sampleSymbols.count)

        var unreservedRootIndices: [NodeStore.NodeIndex] = []
        var reservedRootIndices: [NodeStore.NodeIndex] = []
        for mangledSymbol in Self.sampleSymbols {
            let unreservedRootIndex = try unreservedBuilder.demangle(mangledSymbol)
            let reservedRootIndex = try reservedBuilder.demangle(mangledSymbol)
            #expect(
                unreservedRootIndex.rawValue == reservedRootIndex.rawValue,
                "Reservation must not change interning order or results"
            )
            unreservedRootIndices.append(unreservedRootIndex)
            reservedRootIndices.append(reservedRootIndex)
        }

        let unreservedStore = unreservedBuilder.freeze()
        let reservedStore = reservedBuilder.freeze()
        #expect(unreservedStore.nodeCount == reservedStore.nodeCount)
        #expect(unreservedStore.edgeCount == reservedStore.edgeCount)
        #expect(unreservedStore.textByteCount == reservedStore.textByteCount)
        for (unreservedRootIndex, reservedRootIndex) in zip(unreservedRootIndices, reservedRootIndices) {
            let unreservedOutput = unreservedStore.reference(at: unreservedRootIndex).print(using: .default)
            let reservedOutput = reservedStore.reference(at: reservedRootIndex).print(using: .default)
            #expect(unreservedOutput == reservedOutput)
        }
    }

    @Test func midBuildReservationKeepsExistingEntriesFindable() throws {
        var builder = NodeStoreBuilder()
        let firstRootIndex = try builder.demangle(Self.sampleSymbols[0])
        // Forces the slot-table rehash path while entries are live.
        builder.reserveCapacity(expectedSymbolCount: 50_000)
        let secondRootIndex = try builder.demangle(Self.sampleSymbols[0])
        #expect(
            firstRootIndex.rawValue == secondRootIndex.rawValue,
            "Rehashed tables must still deduplicate against pre-reservation entries"
        )
    }

    @Test func reservationPreSizesBuffersAndTables() {
        var builder = NodeStoreBuilder()
        let baseline = builder.capacityUtilization
        builder.reserveCapacity(expectedSymbolCount: 100_000)
        let reserved = builder.capacityUtilization

        // At least one node per symbol is a floor no coefficient tuning can
        // go below.
        #expect(reserved.nodes.capacity >= 100_000)
        #expect(reserved.compactInternSlots.capacity > baseline.compactInternSlots.capacity)
        #expect(reserved.manyChildrenInternSlots.capacity > baseline.manyChildrenInternSlots.capacity)
        #expect(reserved.textInternSlots.capacity > baseline.textInternSlots.capacity)
        // The probe masks require power-of-two tables.
        #expect(reserved.compactInternSlots.capacity.nonzeroBitCount == 1)
        #expect(reserved.manyChildrenInternSlots.capacity.nonzeroBitCount == 1)
        #expect(reserved.textInternSlots.capacity.nonzeroBitCount == 1)
    }

    @Test func nonPositiveReservationIsANoOp() {
        var builder = NodeStoreBuilder()
        let baseline = builder.capacityUtilization
        builder.reserveCapacity(expectedSymbolCount: 0)
        builder.reserveCapacity(expectedSymbolCount: -5)
        let after = builder.capacityUtilization
        #expect(after.nodes.capacity == baseline.nodes.capacity)
        #expect(after.compactInternSlots.capacity == baseline.compactInternSlots.capacity)
        #expect(after.manyChildrenInternSlots.capacity == baseline.manyChildrenInternSlots.capacity)
        #expect(after.textInternSlots.capacity == baseline.textInternSlots.capacity)
    }

    @Test func reservationBelowCurrentCapacityDoesNotShrink() {
        var builder = NodeStoreBuilder()
        builder.reserveCapacity(expectedSymbolCount: 10_000)
        let large = builder.capacityUtilization
        builder.reserveCapacity(expectedSymbolCount: 10)
        let after = builder.capacityUtilization
        #expect(after.nodes.capacity >= large.nodes.capacity)
        #expect(after.compactInternSlots.capacity == large.compactInternSlots.capacity)
        #expect(after.manyChildrenInternSlots.capacity == large.manyChildrenInternSlots.capacity)
        #expect(after.textInternSlots.capacity == large.textInternSlots.capacity)
    }

    @Test func utilizationTracksUse() throws {
        var builder = NodeStoreBuilder()
        _ = try builder.demangle(Self.sampleSymbols[0])
        let utilization = builder.capacityUtilization
        #expect(utilization.nodes.usedCount > 0)
        #expect(utilization.nodes.usedCount <= utilization.nodes.capacity)
        #expect(utilization.textBytes.usedCount > 0)
        #expect(utilization.compactInternSlots.utilization > 0)
        // The tables grow before crossing their 3/4 load factor.
        #expect(utilization.compactInternSlots.utilization < 0.75)
        #expect(utilization.textInternSlots.usedCount == utilization.uniqueTexts.usedCount)
    }
}
