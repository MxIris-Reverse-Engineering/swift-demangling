import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Unit tests for NodeStore — arena-based compact node storage (proposal 0001, Phase 1).
@Suite
struct NodeStoreTests {

    // MARK: - Buffer bounds

    /// The checked range read must trap deterministically in every
    /// configuration when the range leaves the initialized prefix — the
    /// `ContiguousArray` range-subscript semantics the self-managed storage
    /// replaced. The raw `UnsafeBufferPointer` range subscript the builder's
    /// probes used before only bounds-checks in debug, and a release
    /// over-read would compare against uninitialized capacity — a false
    /// interning hit aliasing two different trees to one index, silent data
    /// corruption rather than a crash (ReviewFindingsPR7 F6).
    @Test func rangeReadPastTheInitializedCountTraps() async {
        await #expect(processExitsWith: .failure) {
            var buffer = GrowableStoreBuffer<UInt8>()
            buffer.append(7)
            // Capacity is at least 16 after one append, so this range is
            // inside the *allocation* — only the initialized-count check can
            // catch it.
            _ = buffer.withBuffer(in: 0 ..< 2) { $0.count }
        }
    }

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
        var builder = NodeStoreBuilder()

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
        var builder = NodeStoreBuilder()
        let indexValues: [UInt64] = [0, 1, UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64.max]

        var rootIndices = [NodeStore.NodeIndex]()
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
        var builder = NodeStoreBuilder()

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
        var builder = NodeStoreBuilder()

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
        var builder = NodeStoreBuilder()

        _ = builder.intern(Node(kind: .identifier, text: "duplicated"))
        _ = builder.intern(Node(kind: .module, text: "duplicated"))
        let store = builder.freeze()

        #expect(store.textByteCount == "duplicated".utf8.count, "Equal text should be stored once across kinds")
    }

    // MARK: - Reference Accessors

    @Test func referenceAccessorsMatchMaterializedTree() throws {
        var builder = NodeStoreBuilder()
        let mangled = "$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC"
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
            "$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC",
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

        var builder = NodeStoreBuilder()
        var rootIndices = [NodeStore.NodeIndex]()
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
        var builder = NodeStoreBuilder()
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

    @Test func traversalParityWithNodePath() throws {
        // NodeReference's Sequence conformance and kind-lookup helpers must
        // walk the store in the same order the Node path walks the class tree.
        let mangledSymbols = [
            "$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC",
            "$s4main1gyxxlF",
            "$s7SwiftUI15ModifiedContentVyxq_GAA0D0AAMc",
        ]
        var builder = NodeStoreBuilder()
        var rootIndices = [NodeStore.NodeIndex]()
        for mangled in mangledSymbols {
            rootIndices.append(try builder.demangle(mangled))
        }
        let store = builder.freeze()

        for (rootIndex, mangled) in zip(rootIndices, mangledSymbols) {
            let nodePathTree = try demangleAsNode(mangled, internsSubtrees: false)
            let reference = store.reference(at: rootIndex)

            let referenceKinds = reference.map(\.kind)
            let nodeKinds = nodePathTree.map(\.kind)
            #expect(referenceKinds == nodeKinds, "Preorder kind sequences should match for \(mangled)")

            let referencePostorderKinds = Array(reference.postorder().map(\.kind))
            let nodePostorderKinds = Array(nodePathTree.postorder().map(\.kind))
            #expect(referencePostorderKinds == nodePostorderKinds, "Postorder kind sequences should match for \(mangled)")

            #expect(reference.first(of: .identifier)?.text == nodePathTree.first(of: .identifier)?.text)
            #expect(reference.all(of: .type).count == nodePathTree.all(of: .type).count)
            #expect(reference.contains(.functionType) == nodePathTree.contains(.functionType))
            #expect(reference.identifier == nodePathTree.identifier, "identifier should match for \(mangled)")
        }
    }

    @Test func bridgeDemanglingLeavesNodeCacheUntouched() throws {
        // Phase 3: the builder's demangle bridge must be fully cache-free.
        // Cache-free demangling constructs fresh leaves every time, so two
        // transient runs share no instances; the cached path interns leaves
        // eagerly, so the same leaf is one canonical instance across runs.
        // (Identity-based so concurrent suites interning into the global
        // NodeCache cannot flake this test.)
        let mangled = "$s4main27TestPhase3CacheFreeSentinelVD"

        let transientFirst = try demangleAsNodeTransient(mangled)
        let transientSecond = try demangleAsNodeTransient(mangled)
        let transientIdentifierFirst = try #require(transientFirst.first(of: .identifier))
        let transientIdentifierSecond = try #require(transientSecond.first(of: .identifier))
        #expect(transientIdentifierFirst.text == "TestPhase3CacheFreeSentinel")
        #expect(transientIdentifierFirst !== transientIdentifierSecond, "Transient demangling should not canonicalize leaves")

        let cachedFirst = try demangleAsNode(mangled, internsSubtrees: false)
        let cachedSecond = try demangleAsNode(mangled, internsSubtrees: false)
        let cachedIdentifierFirst = try #require(cachedFirst.first(of: .identifier))
        let cachedIdentifierSecond = try #require(cachedSecond.first(of: .identifier))
        #expect(cachedIdentifierFirst === cachedIdentifierSecond, "Cached demangling interns leaves globally")

        // The transient tree still interns into the store correctly.
        var builder = NodeStoreBuilder()
        let rootIndex = try builder.demangle(mangled)
        let store = builder.freeze()
        #expect(store.reference(at: rootIndex).print(using: .default) == cachedFirst.print(using: .default))
    }

    @Test func directConstructionSharesHashConsingWithTreeInterning() {
        // Building Swift.Int by hand and interning the equivalent Node tree
        // must collapse to the same index, and print identically.
        var builder = NodeStoreBuilder()

        let moduleIndex = builder.intern(kind: .module, text: "Swift")
        let identifierIndex = builder.intern(kind: .identifier, text: "Int")
        let structureIndex = builder.intern(kind: .structure, children: [moduleIndex, identifierIndex])
        let typeIndex = builder.intern(kind: .type, children: [structureIndex])

        let equivalentTree = Node(kind: .type, children: [
            Node(kind: .structure, children: [
                Node(kind: .module, text: "Swift"),
                Node(kind: .identifier, text: "Int"),
            ]),
        ])
        let internedTreeIndex = builder.intern(equivalentTree)
        #expect(internedTreeIndex == typeIndex, "Direct construction and tree interning should hash-cons to one index")

        let emptyListIndex = builder.intern(kind: .emptyList)
        let indexNodeIndex = builder.intern(kind: .index, index: 42)

        let store = builder.freeze()
        #expect(store.reference(at: typeIndex).print(using: .default) == equivalentTree.print(using: .default))
        #expect(store.reference(at: emptyListIndex).kind == .emptyList)
        #expect(store.reference(at: indexNodeIndex).index == 42)
    }

    @Test func byteLevelTextWitnessesMatchNodePath() throws {
        // The allocation-free isIdentifier/isSwiftModule witnesses and the
        // zero-copy textUTF8 view must agree with the Node path everywhere.
        let mangledSymbols = [
            "$sSaySiGD",
            "$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC",
        ]
        var builder = NodeStoreBuilder()
        var rootIndices = [NodeStore.NodeIndex]()
        for mangled in mangledSymbols {
            rootIndices.append(try builder.demangle(mangled))
        }
        let store = builder.freeze()

        for (rootIndex, mangled) in zip(rootIndices, mangledSymbols) {
            let nodePathTree = try demangleAsNode(mangled, internsSubtrees: false)
            for (reference, node) in zip(store.reference(at: rootIndex), nodePathTree) {
                #expect(reference.isSwiftModule == node.isSwiftModule)
                #expect(reference.isIdentifier(desired: "Array") == node.isIdentifier(desired: "Array"))
                #expect(reference.isIdentifier(desired: "Int") == node.isIdentifier(desired: "Int"))
                if let bytes = reference.textUTF8Bytes {
                    #expect(bytes == Array((node.text ?? "").utf8), "textUTF8Bytes should be the exact stored bytes")
                }
            }
        }
    }

    @Test func remangleParityWithNodePath() throws {
        // Remangling a NodeReference (bridged through materialization) must
        // produce the same mangled string as the Node path.
        let mangledSymbols = [
            "$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC",
            "$s4main1gyxxlF",
            "$s7SwiftUI15ModifiedContentVyxq_GAA0D0AAMc",
            "$s4main3FooVAA1P0B0fMq_",
        ]
        var builder = NodeStoreBuilder()
        var rootIndices = [NodeStore.NodeIndex]()
        for mangled in mangledSymbols {
            rootIndices.append(try builder.demangle(mangled))
        }
        let store = builder.freeze()

        for (rootIndex, mangled) in zip(rootIndices, mangledSymbols) {
            let nodePathTree = try demangleAsNode(mangled, internsSubtrees: false)
            let nodePathMangled = try mangleAsString(nodePathTree)
            let storePathMangled = try mangleAsString(store.reference(at: rootIndex))
            #expect(storePathMangled == nodePathMangled, "Store-backed remangling should match the Node path for \(mangled)")
        }
    }

    @Test func sharedSubtreesAcrossSymbolsShareIndices() throws {
        var builder = NodeStoreBuilder()
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
        var firstBuilder = NodeStoreBuilder()
        let firstRootIndex = firstBuilder.intern(Node(kind: .identifier, text: "same"))
        let firstStore = firstBuilder.freeze()

        var secondBuilder = NodeStoreBuilder()
        let secondRootIndex = secondBuilder.intern(Node(kind: .identifier, text: "same"))
        let secondStore = secondBuilder.freeze()

        let firstReference = firstStore.reference(at: firstRootIndex)
        let secondReference = secondStore.reference(at: secondRootIndex)

        #expect(firstReference != secondReference, "References into different stores should not be equal")
        #expect(firstReference == firstStore.reference(at: firstRootIndex))
    }
}

// MARK: - Cross-Representation Structural Equality

@Suite
struct NodeReferenceStructuralEqualityTests {
    private static let mangledSymbol = "$s7SwiftUI4ViewPAAE7paddingyQrAA4EdgeO3SetV_12CoreGraphics7CGFloatVSgtF"

    @Test func structurallyEqualsMatchesEquivalentNodeTree() throws {
        var builder = NodeStoreBuilder()
        let nodeIndex = try builder.demangle(Self.mangledSymbol)
        let reference = builder.freeze().reference(at: nodeIndex)

        let equivalentTree = try demangleAsNode(Self.mangledSymbol)
        #expect(reference.structurallyEquals(equivalentTree))

        let differentTree = try demangleAsNode("$s7SwiftUI4ViewP")
        #expect(!reference.structurallyEquals(differentTree))
    }

    @Test func structurallyEqualsDistinguishesTextAndIndexPayloads() {
        var builder = NodeStoreBuilder()
        let identifierIndex = builder.intern(kind: .identifier, text: "padding")
        let store = builder.freeze()
        let reference = store.reference(at: identifierIndex)

        #expect(reference.structurallyEquals(Node.create(kind: .identifier, text: "padding")))
        #expect(!reference.structurallyEquals(Node.create(kind: .identifier, text: "spacing")))
        #expect(!reference.structurallyEquals(Node.create(kind: .module, text: "padding")))
        #expect(!reference.structurallyEquals(Node.create(kind: .identifier)))
    }

    @Test func structurallyEqualsWalksChildren() throws {
        var builder = NodeStoreBuilder()
        let childIndex = builder.intern(kind: .identifier, text: "padding")
        let wrapperIndex = builder.intern(kind: .type, children: [childIndex])
        let store = builder.freeze()
        let wrapperReference = store.reference(at: wrapperIndex)

        #expect(wrapperReference.structurallyEquals(Node.create(kind: .type, child: Node.create(kind: .identifier, text: "padding"))))
        #expect(!wrapperReference.structurallyEquals(Node.create(kind: .type, child: Node.create(kind: .identifier, text: "spacing"))))
        #expect(!wrapperReference.structurallyEquals(Node.create(kind: .identifier, text: "padding")))
    }
}

// MARK: - Interning convenience (Stage 5 upstream additions)

@Suite
struct NodeReferenceInterningConvenienceTests {
    @Test func interningInitializerRoundTrip() throws {
        let tree = try demangleAsNodeTransient("$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC")
        let reference = NodeReference(interning: tree)
        #expect(reference.structurallyEquals(tree))
        #expect(reference.print(using: .default) == tree.print(using: .default))
    }

    @Test func asyncPrintMatchesSyncPrintOnBothRepresentations() async throws {
        let tree = try demangleAsNodeTransient("$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC")
        let reference = NodeReference(interning: tree)
        // The immediately-invoked closures pin the sync overload; a bare call
        // in this async context would resolve to the async variant.
        let syncTreeOutput = { tree.print(using: .default) }()
        let syncReferenceOutput = { reference.print(using: .default) }()
        let asyncTreeOutput = await tree.print(using: .default)
        let asyncReferenceOutput = await reference.print(using: .default)
        #expect(!asyncTreeOutput.isEmpty)
        #expect(asyncTreeOutput == syncTreeOutput)
        #expect(asyncReferenceOutput == syncReferenceOutput)
    }

    @Test func crossStoreStructuralEquality() throws {
        let mangled = "$sSaySiGD"
        var firstBuilder = NodeStoreBuilder()
        let firstIndex = try firstBuilder.demangle(mangled)
        let firstReference = firstBuilder.freeze().reference(at: firstIndex)

        var secondBuilder = NodeStoreBuilder()
        _ = try secondBuilder.demangle("$sS2iIegyd_D")
        let secondIndex = try secondBuilder.demangle(mangled)
        let secondReference = secondBuilder.freeze().reference(at: secondIndex)

        #expect(firstReference != secondReference)
        #expect(firstReference.structurallyEquals(secondReference))
        #expect(secondReference.structurallyEquals(firstReference))

        let differentReference = NodeReference(interning: try demangleAsNodeTransient("$sSiD"))
        #expect(!firstReference.structurallyEquals(differentReference))
    }

    @Test func sameStoreStructuralEqualityIsIndexEquality() throws {
        var builder = NodeStoreBuilder()
        let firstIndex = try builder.demangle("$sSaySiGD")
        let secondIndex = try builder.demangle("$sSaySiGD")
        let store = builder.freeze()
        #expect(firstIndex == secondIndex)
        #expect(store.reference(at: firstIndex).structurallyEquals(store.reference(at: secondIndex)))
    }

    /// Pins the property that makes store-identity `==` the right choice:
    /// inside one arena it *is* structural equality, so hashed collections
    /// deduplicate normally. Read this before concluding that `NodeReference`
    /// "cannot deduplicate" — that only holds when every element brought its
    /// own arena, which is what `init(interning:)` does by design.
    @Test func hashedCollectionsDeduplicateWithinOneArena() throws {
        var builder = NodeStoreBuilder()
        var indices: [NodeStore.NodeIndex] = []
        for _ in 0 ..< 100 {
            indices.append(try builder.demangle("$sSaySiGD"))
        }
        let store = builder.freeze()

        let references = indices.map { store.reference(at: $0) }
        #expect(Set(references).count == 1, "hash-consing must collapse identical trees to one index")
        #expect(Dictionary(grouping: references, by: { $0 }).count == 1)
    }

    /// The mirror image, so the boundary is explicit rather than folklore:
    /// one arena per reference means no two are `==`, while the structural
    /// pair still reports them equal.
    @Test func separateArenasAreUnequalButStructurallyEqual() throws {
        let tree = try demangleAsNodeTransient("$sSaySiGD")
        let references = (0 ..< 10).map { _ in NodeReference(interning: tree) }

        #expect(Set(references).count == 10, "each interning call mints its own arena")
        for reference in references.dropFirst() {
            #expect(reference != references[0])
            #expect(reference.structurallyEquals(references[0]))

            var firstHasher = Hasher(), otherHasher = Hasher()
            references[0].structuralHash(into: &firstHasher)
            reference.structuralHash(into: &otherHasher)
            #expect(firstHasher.finalize() == otherHasher.finalize())
        }
    }

    /// The documented use for `structurallyEquals(_ node: Node)` is finding an
    /// externally demangled `Node` among `NodeReference` dictionary keys. That
    /// only works if the two representations also *hash* alike: a key whose
    /// hash comes from `structuralHash` and whose equality comes from
    /// `structurallyEquals` lands in a different bucket than the `Node` looking
    /// for it if the two encode their payloads differently.
    @Test func structuralHashAgreesWithNodeHash() throws {
        let mangledStrings = [
            "$sSiD",
            "$sSaySiGD",
            "$sS2iIegyd_D",
            "$s11ExampleBase0A4TextV0A6AddonsE9formatter7subjectAcA0A5StyleV_xtcSyRzlufC",
            "$s7SwiftUI15ModifiedContentVyxq_GAA0D0AAMc",
        ]

        for mangled in mangledStrings {
            let tree = try demangleAsNodeTransient(mangled)
            let reference = NodeReference(interning: tree)
            #expect(reference.structurallyEquals(tree), "structural equality broke for \(mangled)")

            var referenceHasher = Hasher()
            reference.structuralHash(into: &referenceHasher)
            var nodeHasher = Hasher()
            tree.hash(into: &nodeHasher)
            #expect(referenceHasher.finalize() == nodeHasher.finalize(), "structural hash diverged for \(mangled)")
        }
    }

    /// Store-backed printing is documented as touching no global state, and
    /// bulk indexers rely on it: a whole binary printed through
    /// `NodeReference.print` must not grow `NodeCache.shared` without bound.
    /// The nested-mangled-name path went through the *public* `demangleAsNode`,
    /// which interns by default.
    @Test func storeBackedPrintingDoesNotPopulateTheGlobalCache() throws {
        // A payload whose text is itself a mangled name is what sends the
        // printer back through the demangler mid-walk. The module name is
        // deliberately unique to this test so the probe below cannot collide
        // with a symbol another suite demangles concurrently — asserting on
        // `NodeCache.shared.count` would be a race, asserting on one specific
        // leaf is not.
        let probeModuleName = "ZzStorePrintProbe"
        let payloadNode = Node.createTransient(
            kind: .functionSignatureSpecializationParamPayload,
            text: "$s\(probeModuleName.count)\(probeModuleName)1TVD"
        )
        let reference = NodeReference(interning: payloadNode)

        #expect(
            !NodeCache.shared.containsCanonicalLeaf(kind: .module, contents: .text(probeModuleName)),
            "the probe module name must not already be canonical, or this test proves nothing"
        )

        let printed = reference.print(using: .default)
        #expect(printed == "\(probeModuleName).T", "the nested mangled name should still be demangled for display")

        #expect(
            !NodeCache.shared.containsCanonicalLeaf(kind: .module, contents: .text(probeModuleName)),
            "store-backed printing interned its nested mangled name into NodeCache.shared"
        )
    }
}
