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

    /// The sibling site the guard above did not sweep to:
    /// `decodeTypeSequenceElement` unwrapped `.type` with the same unchecked
    /// `children[0]`, so the identical childless node still killed the process
    /// when it arrived through a tuple element instead of a bound-generic
    /// argument. Fixing one occurrence of a shape and not searching for the
    /// rest is the failure this pins.
    @Test func typeDecoderRejectsAChildlessTypeInsideATupleElement() {
        let tuple = Node.createTransient(kind: .tuple, children: [
            Node.createTransient(kind: .tupleElement, children: [Node.createTransient(kind: .type)]),
        ])

        let decoder = TypeDecoder(builder: StringTypeBuilder())
        #expect(throws: TypeLookupError.self) {
            _ = try decoder.decodeMangledType(node: tuple)
        }
    }

    /// The tuple branch indexed `element.children[typeChildIndex]` with no
    /// bound check, and two shapes overrun it: an empty `.tupleElement` (the
    /// index stays at 0 with nothing there) and one holding only a
    /// `.tupleElementName` (the label consumes index 0 and the index advances
    /// past the end).
    @Test func typeDecoderRejectsTupleElementsWithoutATypeChild() {
        let emptyElement = Node.createTransient(kind: .tuple, children: [
            Node.createTransient(kind: .tupleElement),
        ])
        let labelOnlyElement = Node.createTransient(kind: .tuple, children: [
            Node.createTransient(kind: .tupleElement, children: [
                Node.createTransient(kind: .tupleElementName, text: "label"),
            ]),
        ])

        for malformedTuple in [emptyElement, labelOnlyElement] {
            let decoder = TypeDecoder(builder: StringTypeBuilder())
            #expect(throws: TypeLookupError.self) {
                _ = try decoder.decodeMangledType(node: malformedTuple)
            }
        }
    }

    /// The parameter-pack extraction under `.silBoxTypeWithLayout` narrows a
    /// `UInt64` payload with a trapping `Int(_:)`. `ffd6f87` converted the
    /// five other reachable narrowings in this file to `Int(exactly:)` with a
    /// throw — including the `.dependentGenericParamCount` one sixteen lines
    /// above this in the same block — and its commit message described the
    /// sweep as complete. This site survived verbatim.
    ///
    /// Reachable entirely from public API: `Node.create(kind:index:)` builds
    /// the payload and `decodeMangledType(node:)` is public, so a
    /// caller-assembled tree aborts the process where `try?` cannot reach —
    /// in release too, and at 2^31 rather than 2^63 on 32-bit watchOS.
    ///
    /// `KnownIssues.md` #1 carried this whole family as deferred, which is why
    /// the omission survived a review pass: a reviewer consulting that list
    /// skips the family wholesale. The entry is corrected in the same batch as
    /// this fix.
    @Test func parameterPackDepthAndIndexNearUInt64MaxThrowInsteadOfTrapping() async throws {
        await #expect(processExitsWith: .success) {
            for boundaryIndex in [UInt64.max, UInt64.max - 1, UInt64(Int.max) + 1] {
                let marker = Node.createTransient(kind: .dependentGenericParamType, children: [
                    Node.create(kind: .index, index: boundaryIndex),
                    Node.create(kind: .index, index: boundaryIndex),
                ])
                let packMarker = Node.createTransient(kind: .dependentGenericParamPackMarker, children: [
                    Node.create(kind: .type, child: marker),
                ])
                // Three children: `children.count > 1` gates the block and the
                // body then reads `children[2]`, so a two-child tree never
                // reaches the narrowing (that overrun is upstream-shaped and
                // adjudicated separately in `KnownIssues.md`).
                let root = Node.createTransient(kind: .silBoxTypeWithLayout, children: [
                    Node.create(kind: .typeList),
                    Node.createTransient(kind: .dependentGenericSignature, children: [packMarker]),
                    Node.create(kind: .typeList),
                ])
                let decoder = TypeDecoder(builder: StringTypeBuilder())
                #expect(throws: TypeLookupError.self) {
                    _ = try decoder.decodeMangledType(node: root)
                }
            }
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

    /// `NodeBuilder.build()` used to return its live node, so
    /// `addChild(build())` created a node that was its own child — and every
    /// unbounded walk in the library (the `.type`-unwrapping loops here, plus
    /// `isSpecialized` / `getUnspecialized`, hashing, interning) spun or grew
    /// forever on the cycle. The builder now detaches every node it hands out
    /// (`build()`, the `node` snapshot, and the non-mutating helpers), so the
    /// sequences that used to close a loop build ordinary acyclic shapes, and
    /// cycles are unconstructible from public API.
    @Test func selfReferentialCyclesAreNotConstructible() {
        let builder = NodeBuilder(kind: .type)
        let builtNode = builder.build()
        builder.addChild(builtNode)

        // The old failure: builtNode.children.first === builtNode.
        #expect(builtNode.children.isEmpty, "a node handed out by build() must stay frozen")
        let rebuiltNode = builder.build()
        #expect(rebuiltNode !== builtNode)
        #expect(rebuiltNode.children.first === builtNode, "the mutation lands on the next build, as a plain child")

        // Feeding the snapshot property back in cannot close a loop either.
        builder.addChild(builder.node)
        let snapshotFedNode = builder.build()
        #expect(snapshotFedNode.children.count == 2)
        #expect(snapshotFedNode.children[1] !== snapshotFedNode)

        // Cross-builder feeding — the a ↔ b shape from the defect report —
        // exchanges frozen snapshots, so both results stay acyclic and every
        // formerly cycle-vulnerable walk terminates.
        let firstBuilder = NodeBuilder(kind: .structure)
        let secondBuilder = NodeBuilder(kind: .extension)
        secondBuilder.addChild(firstBuilder.node)
        firstBuilder.addChild(secondBuilder.node)
        let firstTree = firstBuilder.build()
        let secondTree = secondBuilder.build()
        let finished = Self.completesWithinTimeout {
            _ = firstTree.isSimpleType
            _ = firstTree.needSpaceBeforeType
            _ = firstTree.isProtocol
            _ = isSpecialized(firstTree)
            _ = getUnspecialized(secondTree)
            _ = firstTree.hashValue
        }
        #expect(finished, "a formerly cycle-vulnerable walk never terminated")
    }

    /// The `.type`-unwrapping predicates are public, so the tree reaching them
    /// need not have come from the demangler, and none of them sits inside an
    /// engine's stack guard. A hand-built chain far deeper than anything the
    /// demangler emits must answer rather than overflow the stack.
    @Test func typeUnwrappingPredicatesAreBoundedOnAHandBuiltChain() {
        var chain = Node.create(kind: .protocol, children: [
            Node.create(kind: .module, text: "Swift"),
            Node.create(kind: .identifier, text: "Sendable"),
        ])
        for _ in 0 ..< 100_000 {
            chain = Node.create(kind: .type, children: [chain])
        }

        // Past the unwrap limit the answer is the conservative `false`, not a
        // crash — the limit is unreachable on demangled input.
        #expect(chain.isProtocol == false)
        #expect(chain.isSimpleType == false)
        #expect(chain.needSpaceBeforeType == false)

        // Within the limit the wrappers stay transparent, which is the only
        // depth real symbols ever reach.
        let singlyWrapped = Node.create(kind: .type, children: [
            Node.create(kind: .protocol, children: [
                Node.create(kind: .module, text: "Swift"),
                Node.create(kind: .identifier, text: "Sendable"),
            ]),
        ])
        #expect(singlyWrapped.isProtocol)
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

    // MARK: - Remangler substitution equality on shared DAGs

    /// Builds `G<T, T>` nested `levels` deep with both type arguments sharing
    /// one instance — 2^levels paths over ~7×levels unique nodes. Only leaves
    /// intern through `Node.create`, so two calls yield structurally equal but
    /// instance-distinct trees at every interior node.
    private static func doublingGenericType(levels: Int) -> Node {
        var currentType = Node.create(kind: .type, child: Node.create(kind: .structure) {
            Node.create(kind: .module, text: "Swift")
            Node.create(kind: .identifier, text: "Int")
        })
        for _ in 0 ..< levels {
            let genericHead = Node.create(kind: .type, child: Node.create(kind: .structure) {
                Node.create(kind: .module, text: "main")
                Node.create(kind: .identifier, text: "G")
            })
            currentType = Node.create(kind: .type, child: Node.create(kind: .boundGenericStructure) {
                genericHead
                Node.create(kind: .typeList, children: [currentType, currentType])
            })
        }
        return currentType
    }

    /// `main.foo(_: (first, second)) -> ()` — a shape the remangler accepts
    /// and the real demangler round-trips.
    private static func functionTaking(_ firstArgument: Node, _ secondArgument: Node) -> Node {
        let argumentTuple = Node.create(kind: .type, child: Node.create(kind: .tuple, children: [
            Node.create(kind: .tupleElement, child: firstArgument),
            Node.create(kind: .tupleElement, child: secondArgument),
        ]))
        let functionType = Node.create(kind: .type, child: Node.create(kind: .functionType) {
            Node.create(kind: .argumentTuple, child: argumentTuple)
            Node.create(kind: .returnType, child: Node.create(kind: .type, child: Node.create(kind: .tuple)))
        })
        return Node.create(kind: .global, children: [Node.create(kind: .function) {
            Node.create(kind: .module, text: "main")
            Node.create(kind: .identifier, text: "foo")
            Node.create(kind: .labelList)
            functionType
        }])
    }

    /// `SubstitutionEntry.deepEquals` was the one pairwise structural-equality
    /// walk of four with no visited-pair memo: comparing two structurally equal
    /// but instance-distinct DAGs re-descended once per *path*, so a signature
    /// holding two separately built copies of a shared bound-generic subtree
    /// made `mangleAsString` exponential in the sharing depth (measured 4× per
    /// 2 levels; 1.5 s at 22 levels for a 155-character output, `===`-shared
    /// control flat at every depth). Substitutions only cover nominal kinds, so
    /// the DAG must nest bound generics, not tuples — and 60 levels is as deep
    /// as the remangler's 384 depth limit admits for this shape. Memoized like
    /// `Node.==`, 60 doubling levels finish in milliseconds; pre-fix they were
    /// 2^60 pair visits — never.
    @Test func remanglerSubstitutionLookupFinishesOnDistinctCopiesOfASharedDag() {
        let victim = Self.functionTaking(
            Self.doublingGenericType(levels: 60),
            Self.doublingGenericType(levels: 60)
        )
        let sharedInstance = Self.doublingGenericType(levels: 60)
        let control = Self.functionTaking(sharedInstance, sharedInstance)

        let finished = Self.completesWithinTimeout {
            let victimMangled = try? mangleAsString(victim)
            let controlMangled = try? mangleAsString(control)
            #expect(victimMangled != nil)
            // The lookup must also still *match*: the second copy collapses to
            // the same substitution reference the `===`-shared control takes.
            #expect(victimMangled == controlMangled)
        }
        #expect(finished, "SubstitutionEntry.deepEquals expanded the DAG instead of memoizing visited pairs")
    }

    // MARK: - NodeCache tree interning and demangler post-pass on shared DAGs

    /// `NodeCache.internTree` was the one whole-tree canonicalization walk of
    /// nine with no per-walk identity memo. Its `SubtreeKey` probe short-cuts
    /// only while the probed node's own children are already canonical; as
    /// soon as canonicalization replaces a child anywhere below (structural
    /// duplicates inside the tree, or overlap with previously interned
    /// structure — the normal case for every tree after the first in a bulk
    /// run), every repeated instance probe-misses and re-descends its whole
    /// subtree once per *path*: 2^N on a doubling DAG (measured 4× per 2
    /// levels, 5.4s at 18 levels, through public `Node.interned()` and through
    /// default `demangleAsNode` alike). Memoized by source-instance identity,
    /// 60 doubling levels finish in milliseconds; pre-fix they were 2^60
    /// subtree descents — never.
    @Test func nodeCacheInterningFinishesOnADoublingDag() {
        let firstCopy = Self.doublingGenericType(levels: 60)
        let secondCopy = Self.doublingGenericType(levels: 60)

        let finished = Self.completesWithinTimeout {
            let firstCanonical = firstCopy.interned()
            let secondCanonical = secondCopy.interned()
            // Canonicalization semantics must be intact: both instance-distinct
            // copies collapse to the same canonical instance.
            #expect(firstCanonical === secondCanonical)
        }
        #expect(finished, "NodeCache.internTree re-descended the DAG once per path instead of memoizing by instance")
    }

    /// The demangler's `setParentForOpaqueReturnTypeNodes` post-pass walks the
    /// whole function-type subtree on every plain-function symbol, and
    /// substitution back-references make that subtree a DAG — unmemoized, the
    /// walk costs the path count, so even `internsSubtrees: false` demangling
    /// of a substitution-shared symbol was exponential (1.04s at 18 levels for
    /// a 131-character valid symbol, ×4 per 2 levels; the interning pass then
    /// added its own 2^N on top). The symbol here is produced by the library's
    /// own remangler from a 60-level doubling DAG, so a ~450-character string
    /// hung `demangleAsNode` outright.
    @Test func demangleAsNodeFinishesOnASubstitutionSharedSymbol() throws {
        let sharedDag = Self.doublingGenericType(levels: 60)
        let symbol = try mangleAsString(Self.functionTaking(sharedDag, sharedDag))

        let finished = Self.completesWithinTimeout {
            let transient = try? demangleAsNode(symbol, internsSubtrees: false)
            #expect(transient != nil)
            let firstCanonical = try? demangleAsNode(symbol)
            let secondCanonical = try? demangleAsNode(symbol)
            #expect(firstCanonical != nil)
            // Repeat demangling must still collapse to one canonical instance.
            #expect(firstCanonical === secondCanonical)
        }
        #expect(finished, "demangling a substitution-shared symbol re-walked the DAG once per path")
    }

    /// `Node.findGenericParamsDepth()` scanned its subtree with the path-based
    /// `Sequence` traversal — both the `dependentGenericParamCount` existence
    /// guard and the collection loop — so on a shared DAG the query cost the
    /// path count. Both the guard and the max-combine collection are
    /// idempotent per instance, so a deduped walk answers identically at node
    /// count.
    @Test func findGenericParamsDepthFinishesOnADoublingDag() {
        let root = Node.create(kind: .dependentGenericType, children: [
            Node.create(kind: .dependentGenericSignature, children: [
                Node.create(kind: .dependentGenericParamCount, index: 1),
            ]),
            Node.create(kind: .type, child: Node.create(kind: .tuple, children: [
                Node.create(kind: .tupleElement, child: Node.create(kind: .type, child: Node.create(kind: .dependentGenericParamType, children: [
                    Node.create(kind: .index, index: 0),
                    Node.create(kind: .index, index: 0),
                ]))),
                Node.create(kind: .tupleElement, child: Self.doublingGenericType(levels: 60)),
            ])),
        ])

        let finished = Self.completesWithinTimeout {
            let depths = root.findGenericParamsDepth()
            // The answer itself must be unchanged by the deduped walk.
            #expect(depths == [0: 0])
        }
        #expect(finished, "findGenericParamsDepth re-enumerated the DAG once per path instead of once per node")
    }

    /// `identifier` chained three `first(of:)` scans; the operator scan never
    /// matches a type subtree, so it exhausted the full path-based traversal
    /// before the identifier scan even started — 2^N on a shared DAG. One
    /// deduped preorder pass preserves every "first match in preorder" answer:
    /// a repeat visit of a shared instance cannot contain anything its first
    /// visit did not.
    @Test func identifierLookupFinishesOnADoublingDag() {
        let sharedDag = Self.doublingGenericType(levels: 60)

        let finished = Self.completesWithinTimeout {
            // First `.identifier` in preorder is the generic head's name.
            #expect(sharedDag.identifier == "G")
        }
        #expect(finished, "identifier's operator scan re-enumerated the DAG once per path instead of once per node")
    }

    /// `first(of:)` and `contains(_:)` are short-circuit queries: they answer
    /// "which one comes first" and "is there one at all", so how many times a
    /// shared instance occurs cannot change the answer. Evolution 0006 deduped
    /// `identifier` — whose stated justification was that a fruitless
    /// `first(of:)` scan alone cost the path count — but left `first(of:)` and
    /// `contains(_:)` themselves path-priced, so every other caller kept the
    /// exposure. Measured before this fix on the doubling DAG below: 0.005s at
    /// 10 levels, 1.15s at 18, 4.64s at 20, 18.2s at 22 — exactly ×4 per two
    /// levels, with no bound.
    ///
    /// `all(of:)`, `filter(of:)` and the `preorder()` family stay path-based
    /// on purpose: they enumerate the logical tree, where occurrence counts
    /// are the correct answer (`KnownIssues.md` N6).
    @Test func shortCircuitKindQueriesFinishOnADoublingDag() {
        let sharedDag = Self.doublingGenericType(levels: 60)

        let finished = Self.completesWithinTimeout {
            // Nothing here is a `.functionType`, so neither query can
            // short-circuit — the whole graph gets walked either way.
            #expect(!sharedDag.contains(.functionType))
            #expect(sharedDag.first(of: .functionType) == nil)
            // Answers that do exist must stay the preorder-first ones.
            #expect(sharedDag.first(of: .identifier)?.text == "G")
            #expect(sharedDag.contains(.identifier))
        }
        #expect(finished, "a short-circuit kind query re-enumerated the DAG once per path instead of once per node")
    }

    /// The same queries over the store representation. They are one generic
    /// implementation shared by both, so a fix that reached only `Node` would
    /// leave `NodeReference` exposed.
    @Test func shortCircuitKindQueriesFinishOnADoublingDagStore() {
        let (store, rootIndex) = Self.doublingDagStore(levels: 60)
        let rootReference = store.reference(at: rootIndex)

        let finished = Self.completesWithinTimeout {
            #expect(!rootReference.contains(.functionType))
            #expect(rootReference.first(of: .functionType) == nil)
            #expect(rootReference.contains(.identifier))
        }
        #expect(finished, "the store path re-enumerated the DAG once per path instead of once per node")
    }

    // MARK: - Rich-target context on the store path (#14)

    /// `NodePrintContext.node` was `name as? Node`, which is always nil for a
    /// `NodeReference` — so the two representations fed rich targets different
    /// context while producing byte-identical text, invisible to every output
    /// comparison test.
    @Test func storePathDeliversContextNodesToRichTargets() throws {
        struct ContextRecordingTarget: NodePrinterTarget {
            var text = ""
            var writtenUnitCount: Int { text.utf8.count }
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

            // Scopes are not what this target records, but neither hook
            // carries a default, so ignoring them has to be explicit — and
            // `pop` is deliberately paired with `push` here rather than
            // inherited, so a target that tracks scopes cannot forget it.
            mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {}
            mutating func popTypeReferenceScope() {}
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
        // The signature sits at index 1 because that is where the printer
        // reads it from — upstream's off-by-one, kept deliberately (see
        // `NodePrinterRobustnessTests.printsExtendedExistentialTypeShapeTheWayUpstreamDoes`).
        // This test is about the option-override cache interaction, so all it
        // needs is that the signature actually gets printed inside the shape.
        let extendedExistentialShape = Node.create(
            kind: .extendedExistentialTypeShape,
            children: [integerType, genericSignature]
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

    // MARK: - 32-bit Int portability

    /// `Int(UInt32.max)` overflows wherever `Int` is 32 bits — watchOS
    /// `arm64_32` and `armv7k`, both inside `Package.swift`'s declared
    /// platforms — and it does so at constant-folding time: the compiler
    /// reduces the enclosing function body to an unconditional
    /// `assertionFailure` while the build stays green with no diagnostic
    /// (verified against the emitted SIL for both targets). Three store-buffer
    /// guards shipped that spelling, so on watchOS the first node inserted
    /// into any store killed the process. The portable spelling is a
    /// heterogeneous comparison (`count <= UInt32.max`), which compares
    /// mathematically without converting either side — the same idiom as the
    /// standard library's `KeyPath` offset check and swift-syntax's
    /// `AbsoluteSyntaxInfo`. No host-side runtime test can catch this, because
    /// the expression is well-behaved wherever the suite runs — hence a source
    /// scan.
    ///
    /// - Note: the scan matches **three literal spellings**, and that is its
    ///   whole scope by design. It does not see `Int(someUInt32)`,
    ///   `numericCast`, or a sum like `a.count + b.count <= UInt32.max`. Those
    ///   are a different hazard: they convert a *runtime* value, so they trap
    ///   only when the value actually exceeds the platform `Int` — a real but
    ///   ordinarily unreachable condition (an index above `Int32.max` needs a
    ///   store of over two billion nodes, and `NodeStore.NodeIndex.init` is
    ///   not public, so one cannot be conjured). What this test exists for is
    ///   the *constant* spelling, which is categorically worse: it is folded
    ///   at compile time into an unconditional trap, with no diagnostic and no
    ///   input required to reach it. Adjudicated as `KnownIssues.md` N5.
    @Test func librarySourceAvoidsWordSizeDependentIntegerConversions() throws {
        let librarySourcesDirectory = URL(fileURLWithPath: #filePath) // …/Tests/DemanglingTests/DefectRegressionTests.swift
            .deletingLastPathComponent() // …/Tests/DemanglingTests
            .deletingLastPathComponent() // …/Tests
            .deletingLastPathComponent() // package root
            .appendingPathComponent("Sources")
        let forbiddenConversions = ["Int(UInt32.max)", "Int(UInt64.max)", "Int(UInt.max)"]
        let fileEnumerator = try #require(FileManager.default.enumerator(at: librarySourcesDirectory, includingPropertiesForKeys: nil))

        var violations: [String] = []
        for case let fileLocation as URL in fileEnumerator where fileLocation.pathExtension == "swift" {
            let fileContents = try String(contentsOf: fileLocation, encoding: .utf8)
            for (lineOffset, line) in fileContents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                // Comment lines may name the forbidden spelling to explain it.
                guard !trimmedLine.hasPrefix("//") else { continue }
                for forbiddenConversion in forbiddenConversions where trimmedLine.contains(forbiddenConversion) {
                    violations.append("\(fileLocation.lastPathComponent):\(lineOffset + 1): \(trimmedLine)")
                }
            }
        }

        #expect(violations.isEmpty, "word-size-dependent conversions found — compare against the unsigned bound directly (heterogeneous comparison) instead:\n\(violations.sorted().joined(separator: "\n"))")
    }

    /// Companion scan covering the runtime-value side of the same hazard
    /// family: naturals parsed from a mangled string are `UInt64` and
    /// attacker-controlled, so converting one with `Int(_:)` — or doing any
    /// arithmetic on one before its bound check — traps on malformed input.
    /// The demangler bounds these in the unsigned domain (`require`) first.
    /// This scan pins the spellings that used to trap (ReviewFindingsPR7 F1
    /// and its addendum); it cannot see a conversion or an increment
    /// laundered through an intermediate variable — the exit test below is
    /// the behavioral guard for those.
    ///
    /// Lesson encoded in the list's composition: the first sweep searched by
    /// the *narrowing-conversion* feature and missed `demangleSwift3Index`'s
    /// wrap family, whose defect involves no narrowing at all. The sweep
    /// feature for this hazard is "any arithmetic eating a
    /// `conditionalInt()`/`readInt()` result", and new spellings of that
    /// shape belong in this list.
    ///
    /// That lesson was written down correctly and then narrowed twice in the
    /// artifact built from it: the list held only the *increment* direction,
    /// and the scan read only `Demangler.swift`. A fifth round found a
    /// subtraction family (`demangleIndex() - 1`, `index - 2`,
    /// `readScalar().value - '0'`) and an overflow in `NodePrinter.swift` that
    /// neither restriction could ever have surfaced.
    ///
    /// A sixth round removed the third restriction: the scan carried a
    /// hand-maintained `scannedFileNames` set, and its only self-check fired
    /// when a *listed* file was renamed — never when a file that should have
    /// been listed was not, so `TypeDecoder.swift` and `Extensions.swift` were
    /// permanently invisible to it. It now walks every source file, like its
    /// word-size sibling above always did.
    ///
    /// What it still cannot see is an operand laundered through a variable or
    /// a `$0` closure — which was every one of the four traps that round
    /// fixed, all in files this scan already covered. Treat this as a pin for
    /// spellings already known to have trapped, not as the defense: that is
    /// `everyKindSurvivesBoundaryIndicesThroughEveryConsumer` and
    /// `boundaryNumbersInMangledShapesNeverTrap`, which exercise behavior.
    @Test func librarySourceAvoidsUncheckedArithmeticOnParsedNumbers() throws {
        let sourcesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        // Both directions of the hazard. Subtraction is the half that four
        // prior sweeps missed: in the unsigned domain a bound check written
        // *after* the subtraction can never fire, because the subtraction has
        // already trapped.
        let forbiddenSpellings = [
            "Int(demangleIndex",
            "Int(demangleNatural",
            "demangleIndex() + 1",
            "demangleSwift3Index() + 1",
            "readInt()) + 1",
            "demangleIndex() - 1",
            "demangleSwift3Index() - 1",
            "demangleNatural() - 1",
            "readScalar().value - ",
            "readInt()) - 1",
        ]
        let fileEnumerator = try #require(FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil))

        var violations: [String] = []
        var scannedCount = 0
        for case let fileLocation as URL in fileEnumerator where fileLocation.pathExtension == "swift" {
            scannedCount += 1
            let fileContents = try String(contentsOf: fileLocation, encoding: .utf8)
            for (lineOffset, line) in fileContents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.hasPrefix("//") else { continue }
                for forbiddenSpelling in forbiddenSpellings where trimmedLine.contains(forbiddenSpelling) {
                    violations.append("\(fileLocation.lastPathComponent):\(lineOffset + 1): \(trimmedLine)")
                }
            }
        }

        // A scan that silently stops finding its own inputs reports "clean"
        // forever. With the whole tree walked there is no list to fall out of
        // date, so the floor is simply "did we read a plausible number of
        // files at all" — a moved directory or a broken enumerator fails loudly.
        #expect(scannedCount > 30, "expected to scan the whole library, scanned only \(scannedCount) files — did Sources move?")
        #expect(violations.isEmpty, "unchecked arithmetic on a parsed number — bound it in the unsigned domain (require) before the arithmetic, not after:\n\(violations.sorted().joined(separator: "\n"))")
    }

    /// No test may assign `DemanglingRuntimePath.forcesLegacyPath`: the seam
    /// is process-wide, `.serialized` only orders tests within one suite, so
    /// a mid-run flip drags every concurrently running suite onto the legacy
    /// path and non-deterministically un-covers the modern one — the legacy
    /// leg is driven through `demangleAsNodeOnLegacyRuntimePath` instead
    /// (ReviewFindingsPR7 F12). Scan-based, so it is blind to an assignment
    /// laundered through a helper in another module; the reviewable surface
    /// it pins is the test target itself, where the one historical offender
    /// lived.
    @Test func testTargetNeverAssignsTheRuntimePathSeam() throws {
        let testTargetDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let fileEnumerator = try #require(FileManager.default.enumerator(at: testTargetDirectory, includingPropertiesForKeys: nil))
        // Assembled at runtime so this file's own scanning line cannot match
        // itself.
        let seamAssignmentSpelling = "forcesLegacyPath" + " ="
        var violations: [String] = []
        for case let fileLocation as URL in fileEnumerator where fileLocation.pathExtension == "swift" {
            let fileContents = try String(contentsOf: fileLocation, encoding: .utf8)
            for (lineOffset, line) in fileContents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.hasPrefix("//") else { continue }
                if trimmedLine.contains(seamAssignmentSpelling) {
                    violations.append("\(fileLocation.lastPathComponent):\(lineOffset + 1): \(trimmedLine)")
                }
            }
        }
        #expect(violations.isEmpty, "tests must drive the legacy leg via demangleAsNodeOnLegacyRuntimePath, not by mutating the process-wide seam:\n\(violations.sorted().joined(separator: "\n"))")
    }

    /// Mangling-prefix detection must compare bytes, not grapheme clusters:
    /// `String.hasPrefix` honors canonical equivalence, so a combining mark
    /// right after "$s" made `isSwiftSymbol` deny a prefix the byte scanner
    /// would then match — the entry and the scanner disagreed about the same
    /// input, and the symbol mis-routed to the Swift 3 demangler
    /// (ReviewFindingsPR7 F9; only non-ASCII — therefore necessarily
    /// malformed — inputs are affected, which is why no corpus test could
    /// see it). Byte-wise matching restores the `main` behavior.
    @Test func prefixDetectionComparesBytesNotGraphemeClusters() {
        let combiningMarkAfterPrefix = "$s\u{0301}4main4testyyF"
        #expect(combiningMarkAfterPrefix.isSwiftSymbol,
                "the \"$s\" bytes are present, so the prefix must be recognized regardless of what follows")
        #expect(combiningMarkAfterPrefix.stripManglePrefix != combiningMarkAfterPrefix,
                "a recognized prefix must be stripped")
        // Plain ASCII behavior is unchanged in both directions.
        #expect("$s4main4testyyF".isSwiftSymbol)
        #expect(!"NotAMangledName".isSwiftSymbol)
    }

    /// The demangler's index arithmetic must reject numbers that overflow
    /// instead of trapping: `demangleAsNode` is public API fed untrusted
    /// strings (reverse-engineering tools hand it whatever a binary
    /// contains), and an arithmetic trap kills the host process where `try?`
    /// cannot reach (ReviewFindingsPR7 F1 — fourth member of the integer-trap
    /// family after KnownIssues N5's constant folding and `readRange`'s
    /// length prefixes; this is the runtime-value overflow the three-literal
    /// source scan above is deliberately blind to, which is why the guard is
    /// behavioral). Pre-fix the child process dies on the trap; post-fix both
    /// inputs throw `DemanglingError` and the child exits clean.
    @Test func malformedIndexArithmeticThrowsInsteadOfTrapping() async throws {
        await #expect(processExitsWith: .success) {
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$sBi18446744073709551615_")
            }
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$sA18446744073709551000_")
            }
            // The Swift 3 twins (F1 addendum): demangleSwift3Index shares
            // demangleIndex's wrap-then-increment shape, and its callers add
            // another unguarded +1 on top. The first horizontal sweep missed
            // them because it searched by the narrowing-conversion feature,
            // while this family's defect is wrap arithmetic with no
            // narrowing at all — found by re-sweeping for "any arithmetic on
            // a parsed number".
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("_Ttq18446744073709551615_")
            }
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("_Ttq18446744073709551614_")
            }
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("_Ttqd18446744073709551615_0_")
            }
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("_Ttqd0_18446744073709551615_")
            }
        }
    }

    /// The *subtraction* half of the same family. Every input above overflows
    /// upward (`UInt64.max`); every input here underflows, which is the shape
    /// the source scan's `+ 1`-only spelling list could not express — the
    /// reason these survived four prior sweeps of "the integer-trap family".
    ///
    /// All of them trap on `main` too. This is the standing cleanup, not a
    /// regression introduced by this PR.
    @Test func malformedIndexUnderflowThrowsInsteadOfTrapping() async throws {
        await #expect(processExitsWith: .success) {
            // demangleIndex maps a bare `_` to 0, and the builtin sizes
            // subtracted 1 from it before their own bound check could run —
            // `size > 0` can never catch that, the subtraction has already
            // trapped.
            for mangled in ["$sBf_", "$sBi_", "$sBv_"] {
                #expect(throws: DemanglingError.self) {
                    _ = try demangleAsNode(mangled)
                }
            }
            // demangleDependentConformanceIndex subtracts 2; upstream's third
            // arm (`if (index < 2) return nullptr`) was missing here.
            for mangled in ["$sHA_", "$sHD_", "$sHI_"] {
                #expect(throws: DemanglingError.self) {
                    _ = try demangleAsNode(mangled)
                }
            }
            // The dropped-argument count laundered its operand through `$0`,
            // so no spelling of "demangleNatural() + 1" could match it.
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$sTt18446744073709551615")
            }
            // Specialization pass IDs subtract '0' from a raw scalar value, so
            // any byte below '0' underflows UInt32 before the range check runs.
            // Reached through eight dispatch letters, not the one the review
            // first named; the Swift 3 twin (`_TTSg!`) had no range check at all.
            for mangled in ["$sTG$", "$sTg!", "$sTB.", "$sTP%", "$sTi,", "_TTSg!"] {
                #expect(throws: DemanglingError.self) {
                    _ = try demangleAsNode(mangled)
                }
            }
        }
    }

    /// `demangleMultiSubstitutions` must reject a repeat count that is not a
    /// number instead of spinning on it forever.
    ///
    /// `?? 0` swallowed `demangleNatural`'s failure, and since `backtrack()`
    /// had already restored the position and a failed parse consumes nothing,
    /// the enclosing `while true` re-read the same byte with zero net
    /// progress. Upstream bails explicitly (`if (RepeatCount < 0) return
    /// nullptr`); the port dropped that arm. `main` hangs on these too.
    ///
    /// Runs each input on its own thread and waits with a deadline, rather
    /// than through `#expect(processExitsWith:)` like the trap tests above.
    /// A trap gives the child an exit status to assert on; a hang gives
    /// nothing, and `.timeLimit` does not reach inside an exit test's child —
    /// measured: against the unfixed demangler that spelling produced no test
    /// output at all for 300s, i.e. it wedges the suite instead of failing it.
    /// Waiting on a semaphore turns the same regression into a 5s failure per
    /// input. A regressed build leaks the spinning threads for the rest of the
    /// process, which is the acceptable half of the trade.
    ///
    /// The `A` operator is reachable through many one-character prefixes, so
    /// the sample covers several rather than the single input first reported.
    @Test func multiSubstitutionRejectsNonNumericRepeatCount() throws {
        final class DemangleOutcome: @unchecked Sendable {
            var thrownError: (any Error)?
            var acceptedInput = false
        }

        for mangled in ["$sA$", "$sA!", "$sA\"", "$sKA$", "$s_A$", "$sdA$", "$slA$", "$ssA$"] {
            let outcome = DemangleOutcome()
            let finished = DispatchSemaphore(value: 0)
            let worker = Thread {
                do {
                    _ = try demangleAsNode(mangled)
                    outcome.acceptedInput = true
                } catch {
                    outcome.thrownError = error
                }
                finished.signal()
            }
            worker.stackSize = 4 << 20
            worker.start()

            guard finished.wait(timeout: .now() + .seconds(5)) == .success else {
                Issue.record("\(mangled) did not terminate within 5s — demangleMultiSubstitutions is spinning on a non-numeric repeat count again")
                continue
            }
            // The semaphore establishes the ordering for these reads.
            #expect(!outcome.acceptedInput, "\(mangled) is malformed and must be rejected")
            #expect(outcome.thrownError is DemanglingError, "\(mangled) must fail with DemanglingError, got \(String(describing: outcome.thrownError))")
        }
    }

    /// `decodePunycode`'s digit loop must reject a truncated encoded number
    /// instead of trapping. The loop read `input[pos]` at the top of every
    /// iteration while only the *advance* was guarded, so a digit run whose
    /// digits all stay at or above `t` walks `pos` to `endIndex` and the next
    /// iteration subscripts out of bounds. `decodePunycode` is reachable from
    /// any mangled identifier, so `demangleAsNode` on an untrusted symbol
    /// died on the trap where `try?` cannot reach.
    ///
    /// The trigger is pure ASCII: 'J' decodes to 35, which never satisfies
    /// `digit < t`, so the loop never breaks and runs off the end. `main`
    /// traps on it too — the byte-vs-scalar length change only re-partitioned
    /// which inputs reach this loop, it did not introduce the defect.
    @Test func truncatedPunycodeIsRejectedInsteadOfTrapping() async throws {
        await #expect(processExitsWith: .success) {
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$s4main004JJJJyyF")
            }
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$s004JJJJyyF")
            }
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$s4main0010JJJJJJJJJJyyF")
            }
            // A valid punycode identifier still decodes unchanged.
            let valid = try demangleAsNode("$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF")
            #expect(valid.print(using: .default) == "mangling.\u{644}\u{64A}\u{647}\u{645}\u{627}\u{628}\u{62A}\u{643}\u{644}\u{645}\u{648}\u{634}\u{639}\u{631}\u{628}\u{64A}\u{61F}() -> ()")
        }
    }

    /// The printer's discriminator increments must not trap. `demangleIndex`
    /// rejects `UInt64.max` and then returns `value + 1`, so it legitimately
    /// hands back `UInt64.max` for the input one below it; six printer sites
    /// then added 1 again on the same `UInt64`.
    ///
    /// Unlike the demangler members of this family, `print(using:)` is public
    /// and **non-throwing** — there is no error channel, so the saturated case
    /// is wrapped and logged (``DemanglingDiagnostics``) rather than rejected.
    /// `main` traps too.
    ///
    /// Neither existing guard could see these: the source scan reads only
    /// `Demangler.swift`, and the exit test above never prints.
    ///
    /// Asserting the exact rendering, not merely the absence of a trap: `#0`
    /// is reachable only through the guard branch that emits the log, so the
    /// expectations below also pin that the diagnostic path is the one taken.
    @Test func printerDiscriminatorIncrementsDoNotTrap() async throws {
        await #expect(processExitsWith: .success) {
            let explicitClosure = try demangleAsNode("$s4main1fyyFyycfU18446744073709551614_")
            #expect(explicitClosure.print(using: .default) == "closure #0 () -> () in main.f() -> ()")

            let implicitClosure = try demangleAsNode("$s4main1fyyFyycfu18446744073709551614_")
            #expect(implicitClosure.print(using: .default) == "implicit closure #0 () -> () in main.f() -> ()")

            // `.localDeclName` prints its discriminator under `.default`
            // (`displayLocalNameContexts` is in the default option set).
            let localDeclName = try demangleAsNode("_$s9localtest5outeryyF11LocalStructL18446744073709551614_V6methodyyF")
            #expect(localDeclName.print(using: .default) == "method() -> () in LocalStruct #0 in localtest.outer() -> ()")

            // The ordinary discriminators still render as before.
            let closure = try demangleAsNode("$s4main1fyyFyycfU_")
            #expect(closure.print(using: .default) == "closure #1 () -> () in main.f() -> ()")
        }
    }

    /// The substitution-index addition in `demangleMultiSubstitutions`, which
    /// the previous round's bound did not cover: it constrained only the
    /// narrowing of the parsed number, leaving `repeatCount + 27` twenty lines
    /// below to overflow on the top 27 values of `Int`.
    ///
    /// `main` traps on the same inputs. The behavioral guard has to be here
    /// because the source scan cannot see an operand that reached the addition
    /// through a variable.
    @Test func multiSubstitutionIndexAdditionDoesNotTrap() async throws {
        await #expect(processExitsWith: .success) {
            // Int.max, and the first value whose `+ 27` leaves the range.
            for mangled in ["$sA9223372036854775807_", "$sA9223372036854775781_"] {
                #expect(throws: DemanglingError.self) {
                    _ = try demangleAsNode(mangled)
                }
            }
            // One below the boundary still rejects through the ordinary
            // substitution lookup, so the fix did not move the accepted range.
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$sA9223372036854775780_")
            }
        }
    }

    /// Punycode decoding accumulated the encoded number with wrapping
    /// arithmetic, so an uppercase digit run (values 26-51 never satisfy
    /// `digit < t`) drove the weight past Int64 and left the insertion point
    /// negative — `Array.insert(_:at:)` then trapped on a negative index.
    ///
    /// `main` traps on all three. The symbols are ordinary identifier
    /// manglings, so they arrive through plain `demangleAsNode`. Each runs in
    /// its own child process so a regression names the input that brought the
    /// trap back. That well-formed punycode still decodes is the corpus
    /// suite's job — it carries the real identifiers.
    @Test func punycodeAccumulationOverflowIsRejected() async throws {
        await #expect(processExitsWith: .success) {
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$s0022ab_bbZZZZZZZZZZZZZZZZa")
            }
        }
        await #expect(processExitsWith: .success) {
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$s0044ZZZZZZZZZZZZZZZZZZZZZaZZZZZZZZZZZZZZZZZZZZZa")
            }
        }
        await #expect(processExitsWith: .success) {
            #expect(throws: DemanglingError.self) {
                _ = try demangleAsNode("$s4main0021aJJJJJJJJJJJJJJJJJJJbyyF")
            }
        }
    }

    // MARK: - Punycode parity with upstream

    /// Upstream's `digit_index` accepts exactly `a`-`z` (digit values 0-25)
    /// and `A`-`J` (26-35), returning -1 — which rejects the symbol — for
    /// everything else. This port spelled both branches as unbounded `>=`
    /// comparisons, so every scalar from `K` up decodes as a digit: `K`-`Z`
    /// and `[ \ ] ^ _ ` ` land in the 26-based branch (values 36-57), and
    /// `{ | } ~` and beyond land in the 0-based one. The library therefore
    /// accepts punycode the Swift toolchain refuses, and fabricates
    /// identifier text for it.
    ///
    /// `main` carries the identical expressions, so this is a pre-existing
    /// divergence and not a regression from the byte-scanner rewrite. It is
    /// fixed because byte-for-byte agreement with upstream is this library's
    /// first-priority invariant, and it had never been adjudicated — no
    /// `KnownIssues.md` entry covers punycode.
    ///
    /// The `?? "."` substitution (see the test below) is the *other* half of
    /// this divergence and was the only half review named; on a uniform
    /// a-zA-Z corpus this branch is the overwhelming majority of it, so
    /// fixing the substitution alone leaves the divergence essentially
    /// unchanged.
    @Test func punycodeDigitDomainMatchesUpstream() throws {
        // Pre-fix these all decoded successfully, to the scalar named after
        // each one. Upstream rejects every one at `digit_index`.
        let rejectedWithTheirPreFixOutput = [
            ("Ka", "\u{A4}"), ("Za", "\u{B3}"), ("[a", "\u{B4}"),
            ("`a", "\u{B9}"), ("{a", "\u{9A}"), ("~a", "\u{9D}"),
        ]
        for (input, preFixOutput) in rejectedWithTheirPreFixOutput {
            #expect(throws: DemanglingError.self, "\(input) decoded to \(preFixOutput) pre-fix; upstream rejects it") {
                _ = try Punycode.decodePunycode(input)
            }
        }

        // The legal boundaries stay accepted and decode unchanged: `J` is the
        // last 26-based digit (35) and `z` the last 0-based one (25).
        #expect(try Punycode.decodePunycode("Ja") == "\u{A3}")
        #expect(try Punycode.decodePunycode("ja") == "\u{89}")
        #expect(try Punycode.decodePunycode("aa") == "\u{80}\u{80}")
        // A real punycoded identifier — the one the corpus carries — is
        // untouched by the narrowed domain.
        #expect(try Punycode.decodePunycode("egbpdajGbuEbxfgehfvwxn")
            == "\u{644}\u{64A}\u{647}\u{645}\u{627}\u{628}\u{62A}\u{643}\u{644}\u{645}\u{648}\u{634}\u{639}\u{631}\u{628}\u{64A}\u{61F}")

        // End to end: an out-of-domain digit reaches this code from any
        // mangled identifier, so the whole symbol must be rejected.
        #expect(throws: DemanglingError.self) { _ = try demangleAsNode("$s4main002KayyF") }
        #expect(throws: DemanglingError.self) { _ = try demangleAsNode("$s4main002ZayyF") }
        // ...while the in-domain spelling of the same shape still demangles.
        #expect(try demangleAsNode("$s4main002JayyF").print(using: .default) == "main.\u{A3}() -> ()")
    }

    /// A decoded code point that is not a representable Unicode scalar was
    /// substituted with `UnicodeScalar(".")` instead of rejecting the symbol,
    /// so the library invented identifier text. The fabricated character is
    /// `.`, which is also the structural separator in printed output, so the
    /// result is not merely wrong but ambiguous — `main....()` cannot be told
    /// apart from a real nested context.
    ///
    /// Upstream validates in `encodeToUTF8`: `isValidUnicodeScalar(S)` gates
    /// every decoded scalar and fails the whole decode. This port has that
    /// predicate (it is applied on the *encode* path) and simply never called
    /// it while decoding.
    ///
    /// `main` behaves identically — pre-existing, like the digit domain above.
    @Test func punycodeRejectsUnrepresentableScalarsInsteadOfSubstitutingADot() throws {
        // Both decode to a surrogate (U+DCC2 and U+D885), which `UnicodeScalar`
        // cannot represent; pre-fix both produced the single scalar ".".
        for input in ["bbAc", "bfJb"] {
            #expect(throws: DemanglingError.self, "\(input) decoded to \".\" pre-fix; upstream rejects it") {
                _ = try Punycode.decodePunycode(input)
            }
        }

        // End to end. `$s4main005tlDIvyyF` came from the differential fuzz
        // against `xcrun swift-demangle`; pre-fix it printed `main..() -> ()`
        // while the toolchain returned the input unchanged.
        //
        // Both assertions below were confirmed to *fail* before the fix — that
        // is what makes them evidence. The fuzz's other headline symbol,
        // `$s4main0016dlGBHpvDzAmnbBryyF`, is deliberately **not** here: on
        // this branch it is already rejected pre-fix (its 16-character body
        // leaves a trailing `yF` that fails function-type parsing), so
        // asserting on it would pass either way and quietly claim coverage
        // this test does not have.
        #expect(throws: DemanglingError.self) { _ = try demangleAsNode("$s4main005tlDIvyyF") }
        #expect(throws: DemanglingError.self) { _ = try demangleAsNode("$s4main004bbAcyyF") }
    }

    /// The code points before the delimiter are copied to the output verbatim.
    /// Upstream fails on any that is not a basic (< 0x80) code point; this
    /// port copied whatever it found, so a non-ASCII scalar ahead of the
    /// delimiter produced an identifier upstream rejects outright.
    ///
    /// Not named by either review round — found by reading upstream's
    /// `decodePunycode` line by line against this one. Same provenance as the
    /// other two: `main` has it, and it was never adjudicated.
    @Test func punycodeRejectsNonBasicCodePointsBeforeTheDelimiter() throws {
        // Pre-fix "é_a" decoded to "\u{80}é" and "中_a" to "\u{80}中".
        for input in ["\u{E9}_a", "\u{4E2D}_a", "a\u{E9}_ba"] {
            #expect(throws: DemanglingError.self, "\(input) has a non-basic code point before the delimiter") {
                _ = try Punycode.decodePunycode(input)
            }
        }
        // Basic code points before the delimiter are the normal case and stay
        // accepted.
        #expect(try Punycode.decodePunycode("ab_ba") == "a\u{80}b")
    }

    /// Differentiability payloads are narrowed to a single byte on the way to
    /// a `UnicodeScalar`. `print(using:)` is public and non-throwing, so an
    /// index above 255 has to fall back to printing nothing rather than
    /// aborting the process.
    ///
    /// Both indices come from public node construction, and `main` traps on
    /// both. The witness printer next to these sites already used the
    /// failable initializer; these two spellings did not.
    @Test func differentiabilityPayloadPrintingDoesNotTrap() async throws {
        await #expect(processExitsWith: .success) {
            let outOfRange = Node.create(kind: .differentiableFunctionType, index: 300)
            #expect(outOfRange.print(using: .default) == "@differentiable")

            let wrapped = Node.create(kind: .functionType, children: [outOfRange])
            _ = wrapped.print(using: .default)

            // An in-range payload still renders its annotation.
            let reverse = Node.create(kind: .differentiableFunctionType, index: UInt64(UnicodeScalar("r").value))
            #expect(reverse.print(using: .default) == "@differentiable(reverse)")
        }
    }

    /// The remangler's counterpart: `mangleAsString` is a typed-throws API
    /// whose contract is to reject malformed trees, so an index that does not
    /// fit a `UnicodeScalar` must reach that channel instead of trapping.
    ///
    /// `main` traps on both kinds.
    @Test func differentiabilityPayloadManglingDoesNotTrap() async throws {
        await #expect(processExitsWith: .success) {
            let outOfRangeIndex = UInt64(UInt32.max) + 5
            for kind in [Node.Kind.differentiableFunctionType, .autoDiffFunctionKind] {
                let node = Node.create(kind: kind, index: outOfRangeIndex)
                // This test only pins "does not trap". Omitting the payload
                // used to be treated as an acceptable outcome here; it is not,
                // and `differentiabilityMarkersRejectUnrepresentableIndices`
                // now requires the throw. Left as-is so the trap guard stays
                // independent of the stricter contract.
                _ = try? mangleAsString(node)
                _ = canMangle(node)
            }
        }
    }

    /// `NodeStore.NodeIndex` folded a debug-only issuance tag into its
    /// synthesized `Hashable`, so a `Set` of indices from two stores had two
    /// members in Debug and one in Release. Identity must not depend on the
    /// build configuration; cross-store misuse is diagnosed by the explicit
    /// tag checks in `reference(at:)` and `intern`, not by `==`.
    ///
    /// This assertion fails in Debug before the fix and passes in Release,
    /// which is exactly the inconsistency being pinned.
    @Test func nodeIndexIdentityDoesNotDependOnBuildConfiguration() throws {
        var firstBuilder = NodeStoreBuilder()
        let firstIndex = try firstBuilder.demangle("$s4main1fyyF")
        let firstStore = firstBuilder.freeze()

        var secondBuilder = NodeStoreBuilder()
        let secondIndex = try secondBuilder.demangle("$s4main1gyyF")
        let secondStore = secondBuilder.freeze()

        withExtendedLifetime((firstStore, secondStore)) {
            if firstIndex.rawValue == secondIndex.rawValue {
                #expect(firstIndex == secondIndex)
                var indices: Set<NodeStore.NodeIndex> = []
                indices.insert(firstIndex)
                indices.insert(secondIndex)
                #expect(indices.count == 1)
            }
        }
    }

    /// The Swift 3 dependent-member-type branch tested
    /// `c < "0" && c > "9"` — a contradiction no scalar satisfies — so every
    /// `q`-prefixed type fell through to the generic-parameter-index parser
    /// and a legal Swift 3 mangling was rejected.
    ///
    /// `xcrun swift-demangle` accepts this symbol; `main` rejects it.
    @Test func swift3DependentMemberTypeBranchIsReachable() throws {
        let demangled = try demangleAsNode("_TtqCSo8NSObject5Assoc")
        #expect(demangled.print(using: .default) == "__C.NSObject.Assoc")
    }

    // MARK: - Boundary-value matrices

    /// Every index-carrying node kind, at every integer boundary, through
    /// every public consumer of an index.
    ///
    /// This is the guard the spelling scans could not be: the four traps this
    /// round fixed were all "a parsed or constructed number meets a narrowing
    /// conversion", and a blacklist of source spellings sees none of them once
    /// the operand travels through a variable. Enumerating `Node.Kind.allCases`
    /// means a kind added later is covered the day it is added, with nothing to
    /// register by hand — the failure mode that let `TypeDecoder.swift` and
    /// `Extensions.swift` stay permanently invisible to the file-list scan.
    ///
    /// Each node is exercised bare *and* wrapped, because several index reads
    /// only happen when a parent walks its children: the second
    /// differentiability trap fixed this round was reachable only through
    /// `.functionType`, never by printing the node on its own.
    @Test func everyKindSurvivesBoundaryIndicesThroughEveryConsumer() async throws {
        await #expect(processExitsWith: .success) {
            let boundaryIndices: [UInt64] = [
                0, 1,
                255, 256,                              // UInt8 narrowing
                UInt64(UInt32.max), UInt64(UInt32.max) + 1, // UInt32 narrowing
                UInt64(Int32.max) + 1,                 // 32-bit Int narrowing
                UInt64(Int.max), UInt64(Int.max) + 1,  // Int narrowing
                UInt64.max - 1, UInt64.max,            // increment saturation
            ]
            for kind in Node.Kind.allCases {
                for index in boundaryIndices {
                    let node = Node.create(kind: kind, index: index)
                    _ = node.print(using: .default)
                    _ = node.print(using: .simplified)
                    _ = try? mangleAsString(node)
                    _ = canMangle(node)

                    // Contexts whose printers read a child's index.
                    for containerKind in [Node.Kind.type, .functionType, .tuple] {
                        let container = Node.create(kind: containerKind, children: [node])
                        _ = container.print(using: .default)
                        _ = try? mangleAsString(container)
                    }
                }
            }
        }
    }

    /// The demangler half of the same matrix: boundary numbers substituted
    /// into real mangled shapes, and — this is the part that matters —
    /// anything that demangles successfully is then **printed and remangled**.
    ///
    /// Two of this round's four traps lived downstream of a successful
    /// `demangleAsNode`, so a matrix that stopped at "does it demangle without
    /// trapping" would have reported clean on both.
    @Test func boundaryNumbersInMangledShapesNeverTrap() async throws {
        await #expect(processExitsWith: .success) {
            let boundaryNumbers = [
                "0", "1", "26", "27", "255", "256",
                "4294967295", "4294967296",
                "2147483648",
                "9223372036854775780", "9223372036854775781", "9223372036854775807",
                "18446744073709551614", "18446744073709551615",
            ]
            // `#` marks where the number goes. Shapes chosen to reach the
            // index parsers that feed different consumers: substitutions,
            // discriminators, generic parameters, builtin sizes, tuple
            // element counts, and the Swift 3 grammar's own index reader.
            let shapes = [
                "$sA#_",
                "$sBi#_",
                "$sBv#_",
                "$sHA#_",
                "$s4main1fyyFyycfU#_",
                "$s4main1fyyFyycfu#_",
                "_$s9localtest5outeryyF11LocalStructL#_V6methodyyF",
                "$s#xxxxx",
                "$s4mainAAC#_",
                "_TtQ##_",
            ]
            for shape in shapes {
                for number in boundaryNumbers {
                    let mangled = shape.replacingOccurrences(of: "#", with: number)
                    guard let node = try? demangleAsNode(mangled) else { continue }
                    // Downstream of a successful demangle — where two of this
                    // round's traps actually lived.
                    _ = node.print(using: .default)
                    _ = node.print(using: .simplified)
                    _ = node.print(using: .interface)
                    _ = try? mangleAsString(node)
                    _ = canMangle(node)
                }
            }
        }
    }

    /// Wrapping arithmetic must say why it is safe.
    ///
    /// The punycode decoder accumulated with `&+`/`&*` and wrapped past Int64
    /// on an uppercase digit run, landing a negative index in
    /// `Array.insert(_:at:)`. Nothing distinguished that use from the dozen
    /// legitimate ones in this library (hash mixing, a tag increment, capacity
    /// checks) — all of them just looked like someone had silenced a trap.
    ///
    /// So the rule is not "no wrapping operators", which would be wrong: it is
    /// that each one states its reason on the line above, and a reviewer reads
    /// twelve one-line claims instead of re-deriving twelve proofs. A new one
    /// fails this test until its author writes down why wrapping is correct
    /// there. Cheap to satisfy, and it puts the burden on the writer rather
    /// than on whoever finds the crash.
    ///
    /// Deliberately *not* extended to narrowing conversions: there are 136 of
    /// them, nearly all safe and uninteresting (`Int(someCount)`), so requiring
    /// a note on each would produce noise that gets rubber-stamped. The
    /// narrowing family is covered behaviorally by the boundary matrices above.
    @Test func wrappingArithmeticCarriesAnAuditNote() throws {
        let sourcesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        // Assembled at runtime so this file cannot match its own prose.
        let auditMarker = "wrapping" + "-audited:"
        let wrappingOperators = ["&+", "&-", "&*", "&+=", "&-=", "&*="]
        let fileEnumerator = try #require(FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil))

        var unaudited: [String] = []
        for case let fileLocation as URL in fileEnumerator where fileLocation.pathExtension == "swift" {
            let fileContents = try String(contentsOf: fileLocation, encoding: .utf8)
            let lines = fileContents.split(separator: "\n", omittingEmptySubsequences: false)
            for (lineOffset, line) in lines.enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.hasPrefix("//") else { continue }
                guard wrappingOperators.contains(where: { trimmedLine.contains($0) }) else { continue }
                // The note may sit on the line itself or on the line above.
                let precedingLine = lineOffset > 0 ? lines[lineOffset - 1].trimmingCharacters(in: .whitespaces) : ""
                guard !trimmedLine.contains(auditMarker), !precedingLine.contains(auditMarker) else { continue }
                unaudited.append("\(fileLocation.lastPathComponent):\(lineOffset + 1): \(trimmedLine)")
            }
        }

        #expect(unaudited.isEmpty, """
            wrapping arithmetic without an audit note — add `// \(auditMarker) <why wrapping is correct here>` \
            on the line above, or use the reporting-overflow form if it is not:
            \(unaudited.sorted().joined(separator: "\n"))
            """)
    }

    // MARK: - PR #7 review, finding 1: remangler traps on a caller-supplied tree

    /// `getChildOfType` asserted the shape and then read `children[0]`
    /// unconditionally. Asserts vanish in release, so a childless `.type`
    /// reached the subscript and trapped: `Index 0 out of range for empty
    /// Node.Children`, an unrecoverable process abort (exit 133 on an optimized
    /// build) raised from `canMangle`, whose entire contract is to answer this
    /// question without failing. `try?` cannot catch a trap, so no caller could
    /// defend against it.
    ///
    /// Both shapes below are buildable from public API and reach the helper
    /// through different callers — `.protocolConformance` via
    /// `mangleProtocolConformance`, `.dependentMemberType` via
    /// `mangleConstrainedType`.
    @Test func remanglingAChildlessTypeWrapperFailsInsteadOfTrapping() throws {
        let childlessType = Node.createTransient(kind: .type)

        let conformance = Node.createTransient(kind: .protocolConformance, children: [childlessType])
        #expect(!canMangle(conformance))
        #expect(throws: ManglingError.self) { try mangleAsString(conformance) }

        let dependentMember = Node.createTransient(kind: .type, children: [
            Node.createTransient(kind: .dependentMemberType, children: [
                childlessType,
                Node.createTransient(kind: .identifier, text: "Element"),
            ]),
        ])
        #expect(!canMangle(dependentMember))
    }

    // MARK: - PR #7 review, finding 4: an overflowing digit run parsed as legal

    /// The digit accumulator used `&*`/`&+`, so a run that overflows `UInt64`
    /// was silently accepted as its value modulo 2^64. `2^64 + 1` wrapped to 1
    /// and the malformed symbol below produced output byte-identical to the
    /// legitimate `$sBi1_` — nothing downstream could tell them apart.
    ///
    /// Upstream does not wrap: `demangleNatural` detects the overflow
    /// (`if (newNum < num) return -1000`) and every caller fails on the
    /// sentinel; `swift-demangle` refuses this input.
    @Test func anOverflowingDigitRunIsRejectedRatherThanWrapped() throws {
        // 2^64 + 1, one past what `UInt64` holds.
        #expect(throws: DemanglingError.self) {
            try demangleAsNode("$sBi18446744073709551617_")
        }
        // 2^64 exactly, which wrapped to 0.
        #expect(throws: DemanglingError.self) {
            try demangleAsNode("$sBi18446744073709551616_")
        }
        // The value the first input used to impersonate still demangles. That
        // impersonation is the whole mechanism: `demangleBuiltinTypeSize`
        // already bounds the size at 4096, and wrapping is what carried an
        // out-of-range run back down into the legal range.
        let legitimate = try demangleAsNode("$sBi1_")
        #expect(legitimate.print(using: .default).contains("Builtin.Int1"))
        // Large-but-representable runs must stay accepted — the rejection is of
        // runs that do not fit `UInt64`, not of large values.
        #expect(throws: Never.self) {
            try demangleAsNode("$sBi4096_")
        }
    }

    // MARK: - PR #7 review, finding 2: the fragment cache disabled by a counter

    /// Counts real rendering work. `write` is recorded in walk-global state
    /// rather than in the target, because targets are value types that the
    /// printer swaps and splices: counting inside `append` would re-count a
    /// replayed cache fragment and hide exactly the effect under test.
    private final class PrintWorkCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedWrites = 0

        func recordWrite() {
            lock.lock()
            recordedWrites += 1
            lock.unlock()
        }

        func reset() {
            lock.lock()
            recordedWrites = 0
            lock.unlock()
        }

        var writeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return recordedWrites
        }
    }

    private static let printWorkCounter = PrintWorkCounter()

    /// Mirrors `String`'s writing behaviour but keeps only the character count,
    /// so a deliberately path-exponential tree cannot blow the test's memory
    /// while the pre-fix walk is running.
    private struct WriteCountingTarget: NodePrinterTarget {
        // Accumulated per write rather than measured on a joined buffer, so
        // every non-empty write changes it — the delta-probe contract.
        var writtenUnitCount: Int = 0

        init() {}

        mutating func write(_ content: String) {
            writtenUnitCount += content.utf8.count
            DefectRegressionTests.printWorkCounter.recordWrite()
        }

        mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
            write(content)
        }

        mutating func append(_ other: WriteCountingTarget) {
            writtenUnitCount += other.writtenUnitCount
        }

        mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {}
        mutating func popTypeReferenceScope() {}
    }

    /// `levels` nested two-element `.typeList`s over one shared instance:
    /// 2^levels paths, `levels + 1` unique nodes. A childless
    /// `.genericSpecialization` sits at the bottom, so every ancestor's
    /// rendering routes through `printSpecializationPrefix`.
    private static func doublingListOverASpecializationNode(levels: Int) -> Node {
        var currentNode = Node.createTransient(kind: .genericSpecialization)
        for _ in 0 ..< levels {
            currentNode = Node.createTransient(kind: .typeList, children: [currentNode, currentNode])
        }
        return currentNode
    }

    /// `printSpecializationPrefix` bumped its visit counter on entry, but the
    /// counter exists to mark fragments whose rendering *consulted the one-shot
    /// latch* — and the latch is only read on the branch taken when the options
    /// omit `.displayGenericSpecializations`. `.default` contains that option,
    /// so under it the counter moved on a path that never touches the latch,
    /// and `printName`'s cache-write guard (which compares the walk-global
    /// counter before and after) then refused to memoize the specialization
    /// node *and every ancestor up to the root*.
    ///
    /// With the cache intact the walk renders `levels + 1` unique nodes; with it
    /// defeated it renders one node per path. Asserted as rendering work rather
    /// than wall-clock so the test is deterministic.
    @Test func aSpecializationNodeDoesNotDisableTheFragmentCache() throws {
        let levels = 16
        let root = Self.doublingListOverASpecializationNode(levels: levels)

        Self.printWorkCounter.reset()
        _ = NodePrinter<WriteCountingTarget>.print(root, using: .default)
        let writesWithCacheIntact = Self.printWorkCounter.writeCount

        #expect(writesWithCacheIntact < 1000, """
            the print walk did \(writesWithCacheIntact) writes over \(levels + 1) unique nodes \
            (2^\(levels) paths) — the fragment cache is not memoizing the specialization node's ancestors
            """)
    }

    // The correctness half of the same counter — that a fragment which *did*
    // consult the latch stays out of the cache, so the one-shot "specialized "
    // prefix is not replayed at a position that must not have it — is pinned by
    // `sharedSpecializationSubtreePrintsThePrefixOnce` above. It has to be
    // asserted on the printed text rather than on rendering work: on the
    // latch-consulting branch only the first visit writes anything, so a write
    // count says nothing about how many times the walk got there.

    // MARK: - PR #7 review, finding 3: the print depth budget lost a level

    /// A chain of `depth` nested `.type` wrappers over one leaf.
    private static func nestedTypeChain(depth: Int) -> Node {
        var currentNode = Node.createTransient(kind: .identifier, text: "Leaf")
        for _ in 0 ..< depth {
            currentNode = Node.createTransient(kind: .type, children: [currentNode])
        }
        return currentNode
    }

    /// The guard was rewritten from `if printDepth > maxPrintDepth` to
    /// `guard printDepth < maxPrintDepth`. `printDepth` is still the enclosing
    /// frame count at that point (the increment is below it), so upstream's
    /// `if (depth > MaxDepth)` over a depth-0 root truncates on the 770th
    /// frame while `<` truncated on the 769th — one level off a budget that was
    /// deliberately restored from 512 to 768 because real symbols were being
    /// truncated.
    ///
    /// Release-only by necessity: an unoptimized build overflows an 8MB stack
    /// somewhere around 745 `printName` frames, so exercising a 768-frame
    /// boundary in a debug test crashes the process instead of failing it
    /// (`Documentations/KnownIssues.md` #4). Run with `swift test -c release`.
    @Test func theDeepestFullyPrintedChainMatchesTheDocumentedBudget() throws {
        #if DEBUG
        // Intentionally not exercised: see the note above. Kept as a live test
        // rather than a comment so `swift test -c release` picks it up.
        #else
        let budget = DemanglingPrinter<String, Node>.maxPrintDepth
        let truncationMarker = "<<too complex>>"

        let deepestAccepted = Self.nestedTypeChain(depth: budget)
        #expect(
            !deepestAccepted.print(using: .default).contains(truncationMarker),
            "a \(budget)-link chain is inside the documented budget and must print in full"
        )

        let firstRejected = Self.nestedTypeChain(depth: budget + 1)
        #expect(
            firstRejected.print(using: .default).contains(truncationMarker),
            "a \(budget + 1)-link chain is past the budget and must truncate"
        )
        #endif
    }

    // MARK: - PR #7 review, minor finding: hasChildren must not touch children

    /// `Node` overrides the `DemanglingNode` default (`!children.isEmpty`)
    /// because its `children` getter rebuilds a `Children` value and retains
    /// every child. This pins the behaviour the payload-tag switch must keep.
    @Test func hasChildrenAgreesWithTheChildCount() throws {
        let leaf = Node.createTransient(kind: .identifier, text: "leaf")
        #expect(!leaf.hasChildren)
        #expect(!Node.createTransient(kind: .type).hasChildren)
        #expect(!Node.createTransient(kind: .index, index: 7).hasChildren)
        #expect(Node.createTransient(kind: .type, children: [leaf]).hasChildren)
        #expect(Node.createTransient(kind: .typeList, children: [leaf, leaf]).hasChildren)
        #expect(Node.createTransient(kind: .typeList, children: [leaf, leaf, leaf]).hasChildren)
    }

    // MARK: - PR #7 review, fourth round

    /// `mangleDependentGenericInverseConformanceRequirement` read child 1's
    /// index with `!`. The two-child guard above it does not imply that child
    /// carries an index, so a caller-assembled tree reached the force-unwrap
    /// and aborted the process — through `canMangle`, whose entire contract is
    /// to answer *without* failing, and which `try?` cannot defend because a
    /// trap is not an error.
    ///
    /// Same shape as `remanglingAChildlessTypeWrapperFailsInsteadOfTrapping`;
    /// that fix swept for `assert`-then-read and missed the `!` spelling.
    @Test func inverseConformanceWithoutAnIndexThrowsInsteadOfTrapping() async throws {
        await #expect(processExitsWith: .success) {
            let node = Node.createTransient(kind: .dependentGenericInverseConformanceRequirement, children: [
                Node.create(kind: .module, text: "Mod"),
                Node.create(kind: .identifier, text: "Foo"),
            ])
            #expect(canMangle(node) == false)
            #expect(throws: ManglingError.self) { try mangleAsString(node) }
        }
    }

    /// Upstream's `case -1` ends with `return ... // substitution`; this port
    /// dropped the `return`, so the substitution branch fell through to the
    /// shared `mangleIndex` below the switch and emitted child 1's index
    /// twice. Pre-fix these mangle to `3ModRI__` and `3ModRI2_2_`.
    @Test func inverseConformanceSubstitutionBranchEmitsItsIndexOnce() throws {
        let zero = Node.createTransient(kind: .dependentGenericInverseConformanceRequirement, children: [
            Node.create(kind: .module, text: "Mod"),
            Node.create(kind: .index, index: 0),
        ])
        #expect(try mangleAsString(zero) == "3ModRI_")

        let three = Node.createTransient(kind: .dependentGenericInverseConformanceRequirement, children: [
            Node.create(kind: .module, text: "Mod"),
            Node.create(kind: .index, index: 3),
        ])
        #expect(try mangleAsString(three) == "3ModRI2_")

        // The non-substitution branches keep emitting the index exactly once.
        let paramType = Node.create(kind: .type, child: Node.create(kind: .dependentGenericParamType, children: [
            Node.create(kind: .index, index: 0),
            Node.create(kind: .index, index: 0),
        ]))
        let nonNegative = Node.createTransient(kind: .dependentGenericInverseConformanceRequirement, children: [
            paramType,
            Node.create(kind: .index, index: 3),
        ])
        #expect(try mangleAsString(nonNegative) == "Ri2_z")
    }

    /// `mangleDependentConformanceIndex` computed `node.index! + 2` on a
    /// payload that is caller-reachable up to `UInt64.max`, so a near-max
    /// index aborted the process from both `mangleAsString` and `canMangle`.
    ///
    /// The boundary-value matrices cannot see this: they drive each kind bare
    /// or wrapped in `.type`/`.functionType`/`.tuple`, and this kind is only
    /// ever reached as a child of `.dependentProtocolConformanceRoot`.
    @Test func conformanceIndexNearUInt64MaxThrowsInsteadOfTrapping() async throws {
        await #expect(processExitsWith: .success) {
            for boundaryIndex in [UInt64.max, UInt64.max - 1, UInt64.max - 2] {
                let root = Node.createTransient(kind: .dependentProtocolConformanceRoot, children: [
                    Node.create(kind: .type, child: Node.create(kind: .tuple)),
                    Node.create(kind: .protocol, children: [
                        Node.create(kind: .module, text: "M"),
                        Node.create(kind: .identifier, text: "P"),
                    ]),
                    Node.create(kind: .index, index: boundaryIndex),
                ])
                _ = try? mangleAsString(root)
                _ = canMangle(root)
            }
        }
    }

    /// `indexAsCharacter` narrowed a `UInt64` payload with a trapping
    /// `UInt32(_:)` on a public, non-throwing accessor. `demangleIndex`
    /// returns values up to `UInt64.max`, so a mangled string reaches it.
    ///
    /// `ffd6f87` fixed this exact expression in four other files and missed
    /// this one; it is also not one of the four consumers the boundary
    /// matrices drive.
    @Test func indexAsCharacterAboveUInt32MaxIsNilInsteadOfTrapping() async throws {
        await #expect(processExitsWith: .success) {
            #expect(Node.create(kind: .index, index: UInt64(UInt32.max) + 1).indexAsCharacter == nil)
            #expect(Node.create(kind: .index, index: .max).indexAsCharacter == nil)
            // Surrogates and out-of-plane values are not scalars either.
            #expect(Node.create(kind: .index, index: 0xD800).indexAsCharacter == nil)
            #expect(Node.create(kind: .index, index: 0x11_0000).indexAsCharacter == nil)
            // A representable payload still round-trips.
            #expect(Node.create(kind: .index, index: UInt64(UnicodeScalar("r").value)).indexAsCharacter == "r")
        }
    }

    /// The remangler wrote identifier length prefixes as grapheme-cluster
    /// counts while proposal 0008 moved the demangler's reader to bytes, so
    /// `mangleAsString(_:usePunycode: false)` emitted a string this library
    /// could no longer demangle.
    ///
    /// Both normalization forms are pinned: NFC regressed in this branch, NFD
    /// was already broken on `next` (grapheme count vs the pre-0008 scalar
    /// reader), and byte counting is what closes both.
    @Test func nonPunycodeManglingRoundTripsForNonASCIIIdentifiers() throws {
        func functionTree(named name: String) -> Node {
            Node.create(kind: .global, child: Node.create(kind: .function, children: [
                Node.create(kind: .module, text: "main"),
                Node.create(kind: .identifier, text: name),
                Node.create(kind: .type, child: Node.create(kind: .functionType, children: [
                    Node.create(kind: .argumentTuple, child: Node.create(kind: .type, child: Node.create(kind: .tuple))),
                    Node.create(kind: .returnType, child: Node.create(kind: .type, child: Node.create(kind: .tuple))),
                ])),
            ]))
        }

        // "café" precomposed (NFC) and decomposed (NFD), plus a multi-byte
        // identifier with no ASCII at all.
        for identifier in ["caf\u{e9}", "cafe\u{301}", "\u{4e2d}\u{6587}"] {
            let tree = functionTree(named: identifier)
            for usePunycode in [true, false] {
                let mangled = try mangleAsString(tree, usePunycode: usePunycode)
                let restored = try demangleAsNode(mangled)
                #expect(
                    restored.print(using: .default) == tree.print(using: .default),
                    "round trip broke for \(identifier.debugDescription) usePunycode=\(usePunycode): \(mangled.debugDescription)"
                )
            }
        }
    }

    /// A minimal `DemanglingNode` whose `hasChildren` deliberately disagrees
    /// with `!children.isEmpty`, so a generic call site reveals *which* of the
    /// two it dispatched to. Nothing else about it needs to be meaningful.
    private struct HasChildrenDispatchProbe: DemanglingNode {
        struct ChildrenView: DemanglingNodeChildren {
            var storage: [HasChildrenDispatchProbe]
            var startIndex: Int { 0 }
            var endIndex: Int { storage.count }
            subscript(position: Int) -> HasChildrenDispatchProbe { storage[position] }
            func at(_ index: Int) -> HasChildrenDispatchProbe? {
                storage.indices.contains(index) ? storage[index] : nil
            }
            func slice(_ from: Int, _ to: Int) -> ArraySlice<HasChildrenDispatchProbe> {
                storage[from ..< to]
            }
        }

        var childStorage: [HasChildrenDispatchProbe] = []

        var kind: Node.Kind { .identifier }
        var text: String? { nil }
        var index: UInt64? { nil }
        var hasIndex: Bool { false }
        var children: ChildrenView { ChildrenView(storage: childStorage) }
        var printCacheIdentity: Int { 0 }
        var materializedNode: Node { Node.createTransient(kind: .identifier) }
        func isIdentifier(desired: String) -> Bool { false }
        var isSwiftModule: Bool { false }

        /// Inverted on purpose — see the test below.
        var hasChildren: Bool { childStorage.isEmpty }
    }

    /// `hasChildren` was an extension member, not a protocol requirement, so
    /// `Node`'s payload-tag override never dispatched from a generic context —
    /// and every call site in `Sources/` is inside
    /// `TypeDecoderEngine<Builder, SomeNode>`, where the receiver is
    /// statically `SomeNode`. The override was dead code while reading as
    /// landed, because both spellings return the same answer and no
    /// value-comparison test can tell them apart.
    ///
    /// This probe inverts the answer so the dispatch itself is observable:
    /// pre-fix the generic call binds `!children.isEmpty` and sees the
    /// opposite of what the witness returns.
    ///
    /// Third time for this shape in this protocol — `db3c604` had to promote
    /// `runPrintWalk` for exactly the same reason three days before `badb778`
    /// reintroduced it on `hasChildren`. **An extension member is never a
    /// valid place for a per-conformer performance override.**
    @Test func hasChildrenDispatchesThroughTheWitnessTable() {
        func genericHasChildren<SomeNode: DemanglingNode>(_ node: SomeNode) -> Bool {
            node.hasChildren
        }

        let leaf = HasChildrenDispatchProbe()
        let parent = HasChildrenDispatchProbe(childStorage: [leaf])

        #expect(genericHasChildren(leaf) == true, "generic call must select the witness, not !children.isEmpty")
        #expect(genericHasChildren(parent) == false, "generic call must select the witness, not !children.isEmpty")

        // `Node`'s own override must keep agreeing with its child count.
        func genericMatchesConcrete(_ node: Node) -> Bool {
            genericHasChildren(node) == node.hasChildren
        }
        #expect(genericMatchesConcrete(Node.createTransient(kind: .identifier, text: "leaf")))
        #expect(genericMatchesConcrete(Node.createTransient(kind: .type, children: [
            Node.createTransient(kind: .identifier, text: "leaf"),
        ])))
    }

    /// `mangleDifferentiableFunctionType` and `mangleImplDifferentiabilityKind`
    /// narrowed with `UInt32(exactly:)` but had no `else`, so an index that
    /// does not name a Unicode scalar produced a legal-looking prefix with the
    /// payload byte missing — `"Yj"` instead of `"Yjf"` — and `canMangle`
    /// reported `true`. A consumer using that as a lookup key silently
    /// collides with, or fails to match, the real symbol.
    ///
    /// The comment above the sibling site says an out-of-range index "has to
    /// reach that channel, not abort"; the `if let` never had the `else` that
    /// would make that true. `mangleAutoDiffFunctionKind`, narrowed in the
    /// same commit, does throw.
    ///
    /// Note the surrogate and out-of-plane cases already went silent on
    /// `next`: `UnicodeScalar(_: UInt32)` is failable, so `ffd6f87` widened an
    /// existing channel rather than opening one.
    @Test func differentiabilityMarkersRejectUnrepresentableIndices() throws {
        let unrepresentable: [UInt64] = [0xD800, 0xDFFF, 0x11_0000, UInt64(UInt32.max) + 1, .max]
        for kind in [Node.Kind.differentiableFunctionType, .implDifferentiabilityKind] {
            for index in unrepresentable {
                let node = Node.create(kind: kind, index: index)
                #expect(throws: ManglingError.self, "\(kind) index 0x\(String(index, radix: 16)) must be rejected") {
                    try mangleAsString(node)
                }
                #expect(canMangle(node) == false, "\(kind) index 0x\(String(index, radix: 16)) must not report manglable")
            }
        }

        // A representable payload still mangles, marker byte included.
        let reverse = Node.create(kind: .differentiableFunctionType, index: UInt64(UnicodeScalar("f").value))
        #expect(try mangleAsString(reverse) == "Yjf")
    }

    /// The printer decides whether to write a qualified-name separator by
    /// reading the target's size before and after a nested print — a *delta*
    /// probe, never an absolute or arithmetic use. The contract it needs is
    /// "a non-empty write changes this value", and `String.count` breaks it:
    /// appending a combining mark to a buffer already ending in `.` merges
    /// into the preceding grapheme cluster and leaves the count unchanged, so
    /// the separator is skipped.
    ///
    /// Note the review filed this as a downstream hazard for rich targets.
    /// It is the reverse: `SemanticString` (atom counts) satisfies the
    /// contract, and `String` — this library's own default target and its
    /// reference conformance — is the one that violates it. Real Swift
    /// symbols cannot reach it (identifiers cannot start with a combining
    /// mark, and non-ASCII ones arrive punycoded), but hand-built trees and
    /// malformed symbols can.
    @Test func combiningMarkIdentifiersKeepTheirQualifiedNameSeparator() {
        let constructor = Node.create(kind: .global, child: Node.create(kind: .constructor, children: [
            Node.create(kind: .module, text: "Mod"),
            Node.create(kind: .identifier, text: "\u{301}"),
            Node.create(kind: .type, child: Node.create(kind: .functionType, children: [
                Node.create(kind: .argumentTuple, child: Node.create(kind: .type, child: Node.create(kind: .tuple))),
                Node.create(kind: .returnType, child: Node.create(kind: .type, child: Node.create(kind: .structure, children: [
                    Node.create(kind: .module, text: "Swift"),
                    Node.create(kind: .identifier, text: "Int"),
                ]))),
            ])),
        ]))

        #expect(constructor.print(using: .default) == "Mod.\u{301}.init() -> Swift.Int")
    }

    /// A target whose size is a token count rather than a text length — the
    /// shape of the downstream `SemanticString` conformance. It must print
    /// byte-identically to `String`, which is the property the delta-probe
    /// contract exists to guarantee and which no `String`-only test can check.
    private struct TokenCountingTarget: NodePrinterTarget {
        var text: String = ""
        private var tokenCount: Int = 0

        init() {}

        var writtenUnitCount: Int { tokenCount }

        mutating func write(_ content: String) {
            guard !content.isEmpty else { return }
            text += content
            tokenCount += 1
        }

        mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
            write(content)
        }

        mutating func append(_ other: TokenCountingTarget) {
            text += other.text
            tokenCount += other.tokenCount
        }

        mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {}
        mutating func popTypeReferenceScope() {}
    }

    /// No node factory may accept contents and children together.
    ///
    /// `Payload` merges the two into one discriminated union — as upstream's
    /// `Node` does — and `mergedPayload` resolves the conflict by giving
    /// children priority, silently. A factory taking both therefore drops its
    /// `text`/`index` on the floor whenever children are present, and through
    /// the subtree intern key it collapses two differently-texted requests
    /// onto a single shared instance.
    ///
    /// `eff0716` deleted the `text:`/`index:` spellings by hand and left the
    /// primary `contents:` + `children:` overload — plus `inlineChildren:`,
    /// `childrenBuilder:` and both SPI `createTransient` forms — in place,
    /// while its own doc comment stated the combination could not be spelled.
    /// Hence a scan rather than another hand sweep.
    ///
    /// `Node.init` is exempt: it is the internal entry point that
    /// `mergedPayload` exists for, and it is not public API.
    @Test func nodeFactoriesCannotSpellContentsWithChildren() throws {
        let librarySourcesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let fileEnumerator = try #require(FileManager.default.enumerator(at: librarySourcesDirectory, includingPropertiesForKeys: nil))
        let childParameterLabels = ["children:", "inlineChildren:", "childrenBuilder:"]

        var violations: [String] = []
        for case let fileLocation as URL in fileEnumerator where fileLocation.pathExtension == "swift" {
            let fileContents = try String(contentsOf: fileLocation, encoding: .utf8)
            for (lineOffset, line) in fileContents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.hasPrefix("//"), !trimmedLine.hasPrefix("///") else { continue }
                // Declarations of node factories only — `Node.init` is exempt.
                guard trimmedLine.contains("func create"), trimmedLine.contains("contents:") else { continue }
                for childLabel in childParameterLabels where trimmedLine.contains(childLabel) {
                    violations.append("\(fileLocation.lastPathComponent):\(lineOffset + 1): \(trimmedLine)")
                }
            }
        }

        #expect(violations.isEmpty, """
        node factories accepting contents together with children found — split them into a \
        contents-only and a children-only overload so the invalid combination cannot be spelled:
        \(violations.sorted().joined(separator: "\n"))
        """)
    }

    /// `printGenericSignature` scans for pack/value markers over
    /// `dropFirst(numGenericParams).prefix(firstRequirement)`, i.e.
    /// `[n, n + firstRequirement)`. `firstRequirement` is an **absolute**
    /// index — it starts at `numGenericParams` and counts up — so the window
    /// upstream scans is `[numGenericParams, firstRequirement)`
    /// (`for (unsigned i = numGenericParams; i < firstRequirement; ++i)`).
    /// The window here is therefore too wide, and markers sitting among the
    /// *requirements* leak into the parameter list.
    ///
    /// Printing has no error channel, so this renders wrong text rather than
    /// failing. Reachable from any caller-assembled tree and from a malformed
    /// symbol.
    @Test func genericSignatureMarkerScanStopsAtTheFirstRequirement() {
        func parameterType(depth: UInt64, index: UInt64) -> Node {
            Node.create(kind: .type, child: Node.create(kind: .dependentGenericParamType, children: [
                Node.create(kind: .index, index: index),
                Node.create(kind: .index, index: depth),
            ]))
        }

        /// Two parameters at depth 0, one leading pack marker, one same-type
        /// requirement, and optionally a second pack marker *after* the
        /// requirement — which is outside the window upstream examines and
        /// must not affect the parameter list.
        func signature(withMarkerAfterTheRequirement: Bool) -> Node {
            var children: [Node] = [
                Node.create(kind: .dependentGenericParamCount, index: 2),
                Node.create(kind: .dependentGenericParamCount, index: 2),
                Node.create(kind: .dependentGenericParamPackMarker, child: parameterType(depth: 0, index: 0)),
                Node.create(kind: .dependentGenericSameTypeRequirement, children: [
                    parameterType(depth: 1, index: 1),
                    parameterType(depth: 1, index: 1),
                ]),
            ]
            if withMarkerAfterTheRequirement {
                children.append(Node.create(kind: .dependentGenericParamPackMarker, child: parameterType(depth: 0, index: 1)))
            }
            return Node.create(kind: .dependentGenericSignature, children: children)
        }

        let withTrailingMarker = signature(withMarkerAfterTheRequirement: true).print(using: .default)
        let withoutTrailingMarker = signature(withMarkerAfterTheRequirement: false).print(using: .default)

        // Only the first parameter is a pack; the marker past the requirement
        // is outside the scan window and must not turn `B` into `each B`.
        #expect(withoutTrailingMarker.hasPrefix("<each A, B>"))
        #expect(
            withTrailingMarker.hasPrefix("<each A, B>"),
            "a marker after the first requirement leaked into the parameter list: \(withTrailingMarker)"
        )
    }

    /// The same window bug repeated for value markers, where the consequence
    /// is a spurious `let ` plus a printed value type.
    ///
    /// Note the shape is forced: the over-wide window is
    /// `[firstRequirement, numGenericParams + firstRequirement)`, and the child
    /// at `firstRequirement` is by definition *not* a marker (that is what
    /// ended the leading scan). So a single generic-parameter depth can never
    /// leak — the test needs at least two, which is why both signatures here
    /// carry two `dependentGenericParamCount` children.
    @Test func genericSignatureValueMarkerScanStopsAtTheFirstRequirement() {
        func parameterType(depth: UInt64, index: UInt64) -> Node {
            Node.create(kind: .type, child: Node.create(kind: .dependentGenericParamType, children: [
                Node.create(kind: .index, index: index),
                Node.create(kind: .index, index: depth),
            ]))
        }

        func valueMarker(depth: UInt64, index: UInt64) -> Node {
            Node.create(kind: .dependentGenericParamValueMarker, child: Node.create(kind: .type, children: [
                Node.create(kind: .dependentGenericParamType, children: [
                    Node.create(kind: .index, index: index),
                    Node.create(kind: .index, index: depth),
                ]),
                Node.create(kind: .type, child: Node.create(kind: .structure, children: [
                    Node.create(kind: .module, text: "Swift"),
                    Node.create(kind: .identifier, text: "Int"),
                ])),
            ]))
        }

        func signature(withMarkerAfterTheRequirement: Bool) -> Node {
            var children: [Node] = [
                Node.create(kind: .dependentGenericParamCount, index: 2),
                Node.create(kind: .dependentGenericParamCount, index: 2),
                valueMarker(depth: 0, index: 0),
                Node.create(kind: .dependentGenericSameTypeRequirement, children: [
                    parameterType(depth: 1, index: 1),
                    parameterType(depth: 1, index: 1),
                ]),
            ]
            if withMarkerAfterTheRequirement {
                children.append(valueMarker(depth: 0, index: 1))
            }
            return Node.create(kind: .dependentGenericSignature, children: children)
        }

        let withTrailingMarker = signature(withMarkerAfterTheRequirement: true).print(using: .default)
        let withoutTrailingMarker = signature(withMarkerAfterTheRequirement: false).print(using: .default)

        // Only the first parameter is a value; the marker past the requirement
        // is outside the scan window and must not add a second `let`.
        #expect(withoutTrailingMarker.hasPrefix("<let A: Swift.Int, B>"))
        #expect(
            withTrailingMarker.hasPrefix("<let A: Swift.Int, B>"),
            "a value marker after the first requirement leaked into the parameter list: \(withTrailingMarker)"
        )
    }

    @Test func targetsWithDifferentUnitCountsPrintIdenticalText() throws {
        let symbols = [
            "$s4main1fyyF",
            "$s7SwiftUI4ViewPAAE4task8priority_QrScP_yyYaYbScMYccntF",
            "$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF",
            "$sSaySiGSayxGSTsWl",
        ]
        for symbol in symbols {
            let node = try demangleAsNode(symbol)
            let asString = node.print(using: .default)
            let asTokens = NodePrinter<TokenCountingTarget>.print(node, using: .default).text
            #expect(asString == asTokens, "target-dependent divergence for \(symbol)")
        }
    }
}
