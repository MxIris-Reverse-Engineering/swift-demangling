import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Regressions for defects found by review of the node-store work: node shapes
/// and API sequences that public API can produce but the demangler never does,
/// plus contracts (equality transitivity, bounded work on shared DAGs, printer
/// cache vs one-shot state) that the corpus tests cannot see because every
/// corpus tree is demangler-shaped.
@Suite
struct DefectRegressionTests {
    /// Runs `body` on its own thread and reports whether it finished within
    /// `timeout` seconds. The tool for defects whose failure mode is an
    /// unbounded loop or walk: pre-fix the body never returns, and a plain
    /// test would hang the whole process instead of failing.
    private static func completesWithinTimeout(_ timeout: TimeInterval = 30, _ body: @escaping @Sendable () -> Void) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            body()
            finished.signal()
        }
        return finished.wait(timeout: .now() + timeout) == .success
    }

    // MARK: - TypeDecoder bounds (#7)

    /// A `.type` node without children is constructible from public API
    /// (`Node.createTransient`, `NodeStoreBuilder.intern(kind:)`), and
    /// `decodeMangledTypeDecl` unwrapped it with an unchecked `children[0]`.
    /// `decodeMangledType` guards the same shape one function up.
    @Test func typeDecoderRejectsATypeNodeWithoutChildren() {
        let emptyType = Node.createTransient(kind: .type)
        let boundGeneric = Node.createTransient(
            kind: .boundGenericStructure,
            children: [emptyType, Node.createTransient(kind: .typeList)]
        )

        let decoder = TypeDecoder(builder: StringTypeBuilder())
        #expect(throws: TypeLookupError.self) {
            _ = try decoder.decodeMangledType(node: boundGeneric)
        }
    }

    // MARK: - Structural equality transitivity (#8)

    /// `NodeStoreBuilder.internText` deduplicates by raw UTF-8 bytes, so the
    /// NFC and NFD spellings of "é" intern as two indices. Cross-representation
    /// equality used to fall back to `String ==` (Unicode canonical
    /// equivalence), making `refNFC ≠ refNFD` while both equalled the same
    /// `Node` — not an equivalence relation, and a dictionary keyed on it
    /// stored two entries the caller believes are one. Equality is byte-exact
    /// everywhere instead; the deliberate cost is that a canonically equal but
    /// byte-different `Node` no longer matches, which is the documented
    /// divergence from `Node.==`.
    @Test func structuralEqualityIsTransitiveAcrossNormalizationForms() throws {
        let composedText = "caf\u{E9}"
        let decomposedText = "cafe\u{301}"
        #expect(composedText == decomposedText, "the premise: canonically equal")
        #expect(!composedText.utf8.elementsEqual(decomposedText.utf8), "the premise: byte-different")

        var builder = NodeStoreBuilder()
        let composedIndex = builder.intern(kind: .identifier, text: composedText)
        let decomposedIndex = builder.intern(kind: .identifier, text: decomposedText)
        let store = builder.freeze()
        let composedReference = store.reference(at: composedIndex)
        let decomposedReference = store.reference(at: decomposedIndex)

        #expect(composedIndex != decomposedIndex, "byte-level interning keeps the spellings apart")
        #expect(!composedReference.structurallyEquals(decomposedReference))

        let composedNode = Node.createTransient(kind: .identifier, text: composedText)

        // Transitivity: refNFC ≠ refNFD, so at most one of them may equal the
        // same node — byte-exact equality picks the byte-identical one.
        #expect(composedReference.structurallyEquals(composedNode))
        #expect(!decomposedReference.structurallyEquals(composedNode))
    }

    // MARK: - Printer cache vs one-shot state (#10)

    /// `specializationPrefixPrinted` makes "specialized " print once per root.
    /// The fragment cache captured a rendering that included the prefix and
    /// replayed it for the second occurrence of the same (shared) node, where
    /// the uncached walk would have printed nothing.
    @Test func sharedSpecializationSubtreePrintsThePrefixOnce() throws {
        // The one-shot prefix only renders when the options *omit*
        // `.displayGenericSpecializations` — `.simplified` is that preset.
        let options = DemangleOptions.simplified
        let specializedTree = try demangleAsNode("$s4main8MyStructV3fooyyFAA1XV_Tg5", internsSubtrees: false)
        let singleOccurrencePrint = specializedTree.print(using: options)
        #expect(singleOccurrencePrint.components(separatedBy: "specialized ").count - 1 == 1,
                "the premise: one specialized function prints the prefix exactly once")

        // The same instance twice, exactly what hash-consed demangling produces
        // for a repeated subtree — and what makes the second print a cache hit.
        let functionNode = try #require(specializedTree.children.first)
        let root = Node.createTransient(kind: .global, children: [functionNode, functionNode])
        let printed = root.print(using: options)

        let prefixCount = printed.components(separatedBy: "specialized ").count - 1
        #expect(prefixCount == 1, "the one-shot prefix printed \(prefixCount) times in: \(printed)")
    }

    // MARK: - Self-referential type chains (#11)

    /// `NodeBuilder.build()` returns its live node, so `addChild(build())`
    /// creates a node that is its own child. The `.type`-unwrapping loops in
    /// `isSimpleType` / `needSpaceBeforeType` followed that chain with no step
    /// bound: a cycle spun forever, silently — worse to diagnose than the
    /// recursion crash it replaced.
    @Test func selfReferentialTypeChainDoesNotSpinForever() {
        let builder = NodeBuilder(kind: .type)
        let cyclicNode = builder.build()
        builder.addChild(cyclicNode)
        #expect(cyclicNode.children.first === cyclicNode, "the premise: a self-cycle is constructible")

        let finished = Self.completesWithinTimeout {
            _ = cyclicNode.isSimpleType
            _ = cyclicNode.needSpaceBeforeType
        }
        #expect(finished, "the type-unwrapping walk never terminated on a cyclic node")
    }

    // MARK: - Bounded work on shared DAGs (#13)

    /// Builds a store whose tree doubles its expansion at every level: node N
    /// has two children that are both node N−1. 60 levels are 2^60 paths but
    /// only ~4×60 unique nodes — the smoke test for any walk that forgets DAGs
    /// exist.
    private static func doublingDagStore(levels: Int) -> (store: NodeStore, rootIndex: NodeStore.NodeIndex) {
        var builder = NodeStoreBuilder()
        let moduleIndex = builder.intern(kind: .module, text: "Swift")
        let nameIndex = builder.intern(kind: .identifier, text: "Dictionary")
        var currentIndex = builder.intern(kind: .structure, children: [moduleIndex, builder.intern(kind: .identifier, text: "Int")])
        for _ in 0 ..< levels {
            let typeIndex = builder.intern(kind: .type, children: [currentIndex])
            let typeListIndex = builder.intern(kind: .typeList, children: [typeIndex, typeIndex])
            currentIndex = builder.intern(kind: .boundGenericStructure, children: [
                builder.intern(kind: .type, children: [builder.intern(kind: .structure, children: [moduleIndex, nameIndex])]),
                typeListIndex,
            ])
        }
        return (builder.freeze(), currentIndex)
    }

    /// `structuralHash`, `Node.hash(into:)` and the structural-equality walks
    /// all visited every *path* of the DAG rather than every *node*: each
    /// shared level quadrupled the visit count (measured 615,165× amplification
    /// at 137 characters of symbol), with no limit to stop it. Memoized by
    /// node, sixty doubling levels finish in milliseconds; pre-fix they were
    /// 2^60 visits — never.
    @Test func structuralApisFinishOnAMaximallySharedDag() {
        let (store, rootIndex) = Self.doublingDagStore(levels: 60)
        let rootReference = store.reference(at: rootIndex)

        let finished = Self.completesWithinTimeout {
            var hasher = Hasher()
            rootReference.structuralHash(into: &hasher)
            _ = hasher.finalize()

            // `materialize` preserves sharing, so this hands `Node.hash(into:)`
            // and the cross-representation equality the same 2^60-path DAG.
            let materializedRoot = rootReference.materialize()
            var nodeHasher = Hasher()
            materializedRoot.hash(into: &nodeHasher)
            _ = nodeHasher.finalize()

            #expect(rootReference.structurallyEquals(materializedRoot))
        }
        #expect(finished, "a structural walk expanded the DAG instead of memoizing it")
    }

    /// The memoized hashes must still agree across representations — that is
    /// the whole point of `structuralHash`.
    @Test func memoizedStructuralHashStillAgreesWithNodeHash() {
        let (store, rootIndex) = Self.doublingDagStore(levels: 8)
        let rootReference = store.reference(at: rootIndex)
        let materializedRoot = rootReference.materialize()

        var referenceHasher = Hasher()
        rootReference.structuralHash(into: &referenceHasher)
        var nodeHasher = Hasher()
        materializedRoot.structuralHash(into: &nodeHasher)

        #expect(referenceHasher.finalize() == nodeHasher.finalize())
    }

    // MARK: - Rich-target context on the store path (#14)

    /// `NodePrintContext.node` was `name as? Node`, which is always nil for a
    /// `NodeReference` — so the two representations fed rich targets different
    /// context while producing byte-identical text, invisible to every output
    /// comparison test.
    @Test func storePathDeliversContextNodesToRichTargets() throws {
        struct ContextRecordingTarget: NodePrinterTarget {
            var text = ""
            var count: Int { text.count }
            var moduleContextNodeTexts: [String?] = []

            init() {}

            mutating func write(_ content: String) {
                text += content
            }

            mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
                if let evaluatedContext = context(), evaluatedContext.state == .printModule {
                    moduleContextNodeTexts.append(evaluatedContext.node?.text)
                }
                write(content)
            }

            mutating func append(_ other: ContextRecordingTarget) {
                text += other.text
                moduleContextNodeTexts += other.moduleContextNodeTexts
            }
        }

        let mangled = "$sSaySiGD"
        let nodeTree = try demangleAsNode(mangled, internsSubtrees: false)
        var storeBuilder = NodeStoreBuilder()
        let rootIndex = try storeBuilder.demangle(mangled)
        let store = storeBuilder.freeze()

        let nodePathTarget = NodePrinter<ContextRecordingTarget>.print(nodeTree, using: .default)
        let referencePathTarget = DemanglingPrinter<ContextRecordingTarget, NodeReference>.print(store.reference(at: rootIndex), options: .default)

        #expect(referencePathTarget.text == nodePathTarget.text)
        #expect(!nodePathTarget.moduleContextNodeTexts.isEmpty, "the premise: modules were printed with context")
        #expect(referencePathTarget.moduleContextNodeTexts == nodePathTarget.moduleContextNodeTexts,
                "the store path delivered different context nodes than the Node path")
    }

    // MARK: - Bulk-demangle resolver passthrough (A)

    /// `NodeStoreBuilder.demangle` is the bulk-indexing entry, and bulk
    /// indexing is exactly where symbolic references occur — but the method
    /// dropped the resolver parameter its underlying transient demangle
    /// accepts, so those symbols could only be indexed by bypassing it.
    @Test func storeBuilderDemangleResolvesSymbolicReferences() throws {
        let resolver: DemangleSymbolicReferenceResolver = { _, _, _ in
            Node.createTransient(kind: .structure, children: [
                Node.createTransient(kind: .module, text: "Swift"),
                Node.createTransient(kind: .identifier, text: "Int"),
            ])
        }
        let mangledTypeWithSymbolicReference = "\u{01}"

        let expectedTree = try demangleAsNodeTransient(mangledTypeWithSymbolicReference, isType: true, symbolicReferenceResolver: resolver)

        var builder = NodeStoreBuilder()
        let rootIndex = try builder.demangle(mangledTypeWithSymbolicReference, isType: true, symbolicReferenceResolver: resolver)
        let store = builder.freeze()

        #expect(store.reference(at: rootIndex).structurallyEquals(expectedTree))
    }

    // MARK: - Remangler reuse (B)

    /// `mangle(_:)` reset the output buffer but not the word-substitution
    /// table, whose entries hold offsets into that buffer: the second use of
    /// one `Remangler` indexed an empty string and trapped, and anything that
    /// survived would emit back-references into the first tree's output.
    @Test func reusedRemanglerMatchesFreshRemanglers() throws {
        // Word substitutions require multi-word identifiers, back-references
        // require repeated subtrees — both must be live across the two calls.
        let firstMangled = "$s4main8MyStructV6doWorkyySayAA9SomeThingVGF"
        let secondMangled = "$s7Example11OtherThingsV7processyySDySSAA05InnerD0VGF"
        let firstTree = try demangleAsNode(firstMangled, internsSubtrees: false)
        let secondTree = try demangleAsNode(secondMangled, internsSubtrees: false)

        var freshRemangler = Remangler(usePunycode: true)
        let expectedFirst = try freshRemangler.mangle(firstTree)
        var secondFreshRemangler = Remangler(usePunycode: true)
        let expectedSecond = try secondFreshRemangler.mangle(secondTree)

        var reusedRemangler = Remangler(usePunycode: true)
        let actualFirst = try reusedRemangler.mangle(firstTree)
        let actualSecond = try reusedRemangler.mangle(secondTree)

        #expect(actualFirst == expectedFirst)
        #expect(actualSecond == expectedSecond, "a reused remangler emitted different output than a fresh one")
    }

    // MARK: - Printer cache vs options override (C)

    /// `printExtendedExistentialTypeShape` temporarily forces
    /// `.displayWhereClauses` on (an option flip inherited from the C++
    /// printer), but the fragment cache is keyed by node identity alone. A
    /// signature node shared between the shape's subtree and the surrounding
    /// walk therefore replayed with — or without — its where clause depending
    /// on which position rendered first. Both directions are pinned here; the
    /// fix suspends the cache while an options override is active.
    @Test func whereClauseOverrideStaysOutOfSharedCacheFragments() throws {
        let integerType = try #require(
            demangleAsNode("$sSiD", internsSubtrees: false).first(of: .type)
        )
        let genericSignature = try #require(
            demangleAsNode("$sSUss17FixedWidthIntegerRzrlEyxqd__cSzRd__lufCSu_SiTg5", internsSubtrees: false)
                .first(of: .dependentGenericSignature)
        )
        let extendedExistentialShape = Node.create(
            kind: .extendedExistentialTypeShape,
            children: [genericSignature, integerType]
        )

        // Baselines, each printed in its own walk (fresh cache per walk).
        // `.interface` excludes `.displayWhereClauses`; the shape printer
        // force-enables it for its own subtree.
        let signatureAlone = genericSignature.print(using: .interface)
        let shapeAlone = extendedExistentialShape.print(using: .interface)
        try #require(!signatureAlone.contains(" where "), "premise: .interface suppresses the where clause outside a shape")
        try #require(shapeAlone.contains(" where "), "premise: the shape printer forces the where clause on")

        // Same walk, same signature instance visible both outside and inside
        // the shape — exactly what hash-consing produces for real symbols.
        // `.typeList` prints its children back to back, so the correct output
        // is the concatenation of the two baselines in either order.
        let signatureFirstRoot = Node.create(kind: .typeList, children: [genericSignature, extendedExistentialShape])
        #expect(
            signatureFirstRoot.print(using: .interface) == signatureAlone + shapeAlone,
            "a signature cached without its where clause was replayed inside the shape"
        )

        let shapeFirstRoot = Node.create(kind: .typeList, children: [extendedExistentialShape, genericSignature])
        #expect(
            shapeFirstRoot.print(using: .interface) == shapeAlone + signatureAlone,
            "a signature cached with its where clause leaked it outside the shape"
        )
    }

    // MARK: - Transient-tree instance sharing (D)

    /// `demangleAsNodeTransient` once documented "structurally equal nodes
    /// are distinct instances" — never true: parameterless kinds resolve to
    /// process-wide `NodeFactory` singletons regardless of `internsLeaves`,
    /// and substitution back-references reuse instances within a tree. The
    /// docs now say so; this pins the actual behavior so they stay honest.
    @Test func transientTreesShareFactorySingletonsByDesign() throws {
        // `main.foo(inner: () async -> ()) async` carries two
        // `.asyncAnnotation` nodes: one on the parameter's function type, one
        // on foo's own type.
        let transientTree = try demangleAsNodeTransient("$s4main3foo5inneryyyYac_tYaF")
        let asyncAnnotations = transientTree.all(of: .asyncAnnotation)
        try #require(asyncAnnotations.count == 2, "premise: expected two .asyncAnnotation nodes, saw \(asyncAnnotations.count)")

        #expect(asyncAnnotations[0] === asyncAnnotations[1])
        #expect(asyncAnnotations[0] === NodeFactory.asyncAnnotation)
    }

    // MARK: - Materialization identity across representations (E)

    /// On the `Node` path, `NodeCache` interning hands out one canonical
    /// instance for structurally equal trees. `NodeReference.materialize()`
    /// documents the opposite: a fresh, un-interned instance per call. This
    /// pins both halves of that documented divergence so identity-keyed
    /// consumers keep getting steered toward structural keys (or the
    /// `NodeReference` itself) rather than `ObjectIdentifier`.
    @Test func materializationIsFreshPerCallWhileInternedNodesAreCanonical() throws {
        let firstNodeTree = try demangleAsNode("$sSaySiGD")
        let secondNodeTree = try demangleAsNode("$sSaySiGD")
        #expect(firstNodeTree === secondNodeTree, "interned Node path: one canonical instance across demangles")

        var storeBuilder = NodeStoreBuilder()
        let rootIndex = try storeBuilder.demangle("$sSaySiGD")
        let store = storeBuilder.freeze()
        let reference = store.reference(at: rootIndex)
        let firstMaterialization = reference.materialize()
        let secondMaterialization = reference.materialize()
        #expect(firstMaterialization !== secondMaterialization, "store path: fresh instance per materialization, as documented")
        #expect(firstMaterialization == secondMaterialization, "structural equality is unaffected")
    }
}
