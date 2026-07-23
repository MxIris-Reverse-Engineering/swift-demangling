import Foundation
import Testing
@testable import Demangling

/// Unit tests for SymbolStore — arena-based compact node storage (proposal 0001, Phase 1).
@Suite
struct SymbolStoreTests {

    // MARK: - Kind Ordinal Mapping

    @Test func kindOrdinalRoundTripsForAllKinds() {
        for kind in Node.Kind.allCases {
            let compact = CompactNode(kind: kind, payloadKind: .none, payloadWord0: 0, payloadWord1: 0)
            #expect(compact.kind == kind, "Kind \(kind) should round-trip through the 9-bit ordinal")
            #expect(compact.payloadKind == .none)
        }
    }

    @Test func compactNodeIsTwelveBytes() {
        #expect(MemoryLayout<CompactNode>.size == 12)
        #expect(MemoryLayout<CompactNode>.stride == 12)
    }

    // MARK: - Import / Materialize Round-Trip

    @Test func importAndMaterializeRoundTrip() {
        var builder = SymbolStoreBuilder()

        let tree = Node(kind: .global, children: [
            Node(kind: .type, children: [
                Node(kind: .structure, children: [
                    Node(kind: .module, text: "Swift"),
                    Node(kind: .identifier, text: "Int"),
                ]),
            ]),
            Node(kind: .index, index: 42),
            Node(kind: .index, index: UInt64.max),
            Node(kind: .emptyList),
        ])

        let rootIndex = builder.intern(tree)
        let store = builder.freeze()
        let materialized = store.reference(at: rootIndex).materialize()

        #expect(materialized == tree, "Import -> materialize should reproduce a structurally equal tree")
    }

    @Test func largeIndexPayloadRoundTrips() {
        var builder = SymbolStoreBuilder()
        let indexValues: [UInt64] = [0, 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64.max]

        var rootIndices = [SymbolStore.NodeIndex]()
        for indexValue in indexValues {
            rootIndices.append(builder.intern(Node(kind: .index, index: indexValue)))
        }
        let store = builder.freeze()

        for (rootIndex, indexValue) in zip(rootIndices, indexValues) {
            #expect(store.reference(at: rootIndex).index == indexValue)
        }
    }

    // MARK: - Hash-Consing

    @Test func structurallyEqualTreesShareOneIndex() {
        var builder = SymbolStoreBuilder()

        func makeTree() -> Node {
            Node(kind: .type, children: [
                Node(kind: .structure, children: [
                    Node(kind: .module, text: "Swift"),
                    Node(kind: .identifier, text: "Int"),
                ]),
            ])
        }

        let firstIndex = builder.intern(makeTree())
        let nodeCountAfterFirst = builder.nodeCount
        let secondIndex = builder.intern(makeTree())

        #expect(firstIndex == secondIndex, "Structurally equal trees should intern to the same index")
        #expect(builder.nodeCount == nodeCountAfterFirst, "Re-interning an equal tree should not add nodes")
    }

    @Test func manyChildrenNodesDeduplicate() {
        var builder = SymbolStoreBuilder()

        func makeWideTree() -> Node {
            Node(kind: .tuple, children: [
                Node(kind: .identifier, text: "a"),
                Node(kind: .identifier, text: "b"),
                Node(kind: .identifier, text: "c"),
                Node(kind: .identifier, text: "d"),
            ])
        }

        let firstIndex = builder.intern(makeWideTree())
        let secondIndex = builder.intern(makeWideTree())
        let store = builder.freeze()

        #expect(firstIndex == secondIndex, "Equal many-children trees should intern to the same index")
        #expect(store.edgeCount == 4, "The edges of an equal many-children node should be stored once")
        #expect(store.reference(at: firstIndex).children.count == 4)
    }

    @Test func textBytesDeduplicate() {
        var builder = SymbolStoreBuilder()

        _ = builder.intern(Node(kind: .identifier, text: "duplicated"))
        _ = builder.intern(Node(kind: .module, text: "duplicated"))
        let store = builder.freeze()

        #expect(store.textByteCount == "duplicated".utf8.count, "Equal text should be stored once across kinds")
    }

    // MARK: - Reference Accessors

    @Test func referenceAccessorsMatchMaterializedTree() throws {
        var builder = SymbolStoreBuilder()
        let mangled = "$s7SwiftUI4TextV_10FoundationE9formatterAcA20LocalizedStringStyleV_xtcSyRzlufc"
        let rootIndex = try builder.demangle(mangled)
        let store = builder.freeze()

        let expectedTree = try demangleAsNode(mangled, internsSubtrees: false)

        func compare(_ reference: NodeReference, _ node: Node) {
            #expect(reference.kind == node.kind)
            #expect(reference.text == node.text)
            #expect(reference.index == node.index)
            #expect(reference.children.count == node.children.count)
            for (childReference, childNode) in zip(reference.children, node.children) {
                compare(childReference, childNode)
            }
        }

        compare(store.reference(at: rootIndex), expectedTree)
    }

    // MARK: - Demangle Parity

    @Test func demangleParityWithNodePath() throws {
        // Zero-materialization store printing must be byte-identical to the Node
        // path across option sets, including generic params (dependentGenericParamType
        // text synthesis) and sugared types.
        let mangledSymbols = [
            "$sSiD",
            "$sSaySiGD",
            "$s7SwiftUI4TextV_10FoundationE9formatterAcA20LocalizedStringStyleV_xtcSyRzlufc",
            "$s4main3FooVAA1P0B0fMq_",
            "$s7SwiftUI4ViewP",
            "$s4main1gyxxlF",                                   // g<A>(A) -> A
            "$s7SwiftUI15ModifiedContentVyxq_GAA0D0AAMc",        // ModifiedContent<A, B> conformance
        ]
        let optionSets: [DemangleOptions] = [
            .default,
            .simplified,
            .default.union(.synthesizeSugarOnTypes),
        ]

        var builder = SymbolStoreBuilder()
        var rootIndices = [SymbolStore.NodeIndex]()
        for mangled in mangledSymbols {
            rootIndices.append(try builder.demangle(mangled))
        }
        let store = builder.freeze()

        for options in optionSets {
            for (rootIndex, mangled) in zip(rootIndices, mangledSymbols) {
                let storePrinted = store.reference(at: rootIndex).print(using: options)
                let nodePrinted = try demangleAsNode(mangled, internsSubtrees: false).print(using: options)
                #expect(storePrinted == nodePrinted, "Store-backed printing should match the Node path for \(mangled)")
            }
        }
    }

    @Test func materializePreservesSubtreeSharing() throws {
        // g<A>(A) -> A: the generic parameter type occurs as both argument and
        // return type, so the hash-consed store holds one index for it. The
        // materialized tree must keep that sharing as one Node instance rather
        // than expanding the DAG into duplicates.
        var builder = SymbolStoreBuilder()
        let rootIndex = try builder.demangle("$s4main1gyxxlF")
        let store = builder.freeze()

        let materialized = store.reference(at: rootIndex).materialize()
        let nodePathTree = try demangleAsNode("$s4main1gyxxlF", internsSubtrees: false)
        #expect(materialized == nodePathTree)

        let genericParameterNodes = materialized.all(of: .dependentGenericParamType)
        #expect(genericParameterNodes.count >= 2, "Expected the generic parameter to occur in multiple positions")
        for genericParameterNode in genericParameterNodes.dropFirst() {
            #expect(genericParameterNode === genericParameterNodes[0], "Shared store subtrees should materialize as one shared instance")
        }
    }

    @Test func sharedSubtreesAcrossSymbolsShareIndices() throws {
        var builder = SymbolStoreBuilder()
        let firstRootIndex = try builder.demangle("$sSiD")
        let secondRootIndex = try builder.demangle("$sSaySiGD")
        let store = builder.freeze()

        func findIntStructure(_ reference: NodeReference) -> NodeReference? {
            if reference.kind == .structure, reference.children.contains(where: { $0.text == "Int" }) {
                return reference
            }
            for child in reference.children {
                if let found = findIntStructure(child) {
                    return found
                }
            }
            return nil
        }

        let firstIntStructure = findIntStructure(store.reference(at: firstRootIndex))
        let secondIntStructure = findIntStructure(store.reference(at: secondRootIndex))
        #expect(firstIntStructure != nil)
        #expect(secondIntStructure != nil)
        #expect(firstIntStructure == secondIntStructure, "The Swift.Int subtree should share one index across symbols")
    }

    // MARK: - Reference Identity

    @Test func referenceEqualityIsStoreAndIndexBased() {
        var firstBuilder = SymbolStoreBuilder()
        _ = firstBuilder.intern(Node(kind: .identifier, text: "same"))
        let firstStore = firstBuilder.freeze()

        var secondBuilder = SymbolStoreBuilder()
        _ = secondBuilder.intern(Node(kind: .identifier, text: "same"))
        let secondStore = secondBuilder.freeze()

        let firstReference = firstStore.reference(at: SymbolStore.NodeIndex(rawValue: 0))
        let secondReference = secondStore.reference(at: SymbolStore.NodeIndex(rawValue: 0))

        #expect(firstReference != secondReference, "References into different stores should not be equal")
        #expect(firstReference == firstStore.reference(at: SymbolStore.NodeIndex(rawValue: 0)))
    }
}
