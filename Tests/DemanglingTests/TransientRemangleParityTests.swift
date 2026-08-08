import Foundation
import Testing
@_spi(Internals) @testable import Demangling
@testable import DemanglingTestingSupport

/// Evolution 0011: the transient tree and the canonical tree of one symbol
/// must remangle **byte-identically**.
///
/// `demangleAsNodeTransient` returns a non-canonical tree (no leaf interning,
/// substitution back-references shared within the tree), and downstream
/// production paths derive lookup keys by remangling such trees. That is
/// sound only while the remangler's substitution table matches entries
/// **structurally** — an identity-keyed table would silently emit different
/// back-references for the two tree shapes and the derived keys would stop
/// matching, with no error anywhere. These tests pin the equivalence so a
/// future substitution-table change that breaks it fails loudly here instead
/// of corrupting downstream lookups.
@Suite struct TransientRemangleParityTests {
    /// The targeted set covers the shapes that stress the substitution table
    /// and the text pipeline differently: repeated subtrees (word and node
    /// substitutions), specializations, opaque return types with conformance
    /// chains, punycoded identifiers (non-ASCII stored text), local-name
    /// discriminators, and the Swift 3 `_Tt` grammar.
    static let paritySymbols: [String] = [
        // Word + node substitutions live across one signature.
        "$s4main8MyStructV6doWorkyySayAA9SomeThingVGF",
        "$s7Example11OtherThingsV7processyySDySSAA05InnerD0VGF",
        // Generic specialization with constraint lists.
        "$sSUss17FixedWidthIntegerRzrlEyxqd__cSzRd__lufCSu_SiTg5",
        // Opaque return type with a dependent conformance chain.
        "$s3use1xAA3OfPVy3lib1GVyAA1fQryFQOyQo_GAjE1PAAxAeKHD1_AIHO_HCg_Gvp",
        // Punycoded identifier: non-ASCII text payloads.
        "$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF",
        // Local names / private discriminators.
        "_$s9localtest5outeryyF11LocalStructL_V6methodyyF",
        // Swift 3 / ObjC-embedded grammar.
        "_TtC6AppKit10NSDocument",
    ]

    @Test(arguments: paritySymbols)
    func transientTreeRemanglesIdenticallyToCanonicalTree(symbol: String) throws {
        let transientMangled = try mangleAsString(demangleAsNodeTransient(symbol))
        let canonicalMangled = try mangleAsString(demangleAsNode(symbol))
        #expect(transientMangled == canonicalMangled)
    }

    /// Maximal substitution pressure: a symbol produced by the library's own
    /// remangler from a doubling bound-generic DAG (the 0005 shape), where
    /// nearly every subtree is a substitution back-reference. The transient
    /// demangle of such a symbol shares instances *through the substitution
    /// table only*, which is exactly the shape an identity-keyed table would
    /// mis-handle.
    @Test func doublingDagSymbolRemanglesIdenticallyOnBothPaths() throws {
        let sharedDag = Self.doublingGenericType(levels: 24)
        let symbol = try mangleAsString(Self.functionTaking(sharedDag, sharedDag))

        let transientMangled = try mangleAsString(demangleAsNodeTransient(symbol))
        let canonicalMangled = try mangleAsString(demangleAsNode(symbol))
        #expect(transientMangled == canonicalMangled)
        #expect(transientMangled == symbol, "round-trip through either path must reproduce the source symbol")
    }

    /// Symbolic references resolve through caller-provided nodes on both
    /// paths; the resolver here answers with `createTransient` nodes, the
    /// cache-free counterpart a transient pipeline would use.
    @Test func symbolicReferenceSymbolRemanglesIdenticallyOnBothPaths() throws {
        let resolver: DemangleSymbolicReferenceResolver = { _, _, _ in
            Node.createTransient(kind: .structure, children: [
                Node.createTransient(kind: .module, text: "Swift"),
                Node.createTransient(kind: .identifier, text: "Int"),
            ])
        }
        let mangledTypeWithSymbolicReference = "\u{01}"

        let transientTree = try demangleAsNodeTransient(mangledTypeWithSymbolicReference, isType: true, symbolicReferenceResolver: resolver)
        let canonicalTree = try demangleAsNode(mangledTypeWithSymbolicReference, isType: true, symbolicReferenceResolver: resolver)
        #expect(try mangleAsString(transientTree) == mangleAsString(canonicalTree))
    }

    // MARK: - DAG builders (the 0005 regression shape)

    /// Builds `G<T, T>` nested `levels` deep with both type arguments sharing
    /// one instance — 2^levels paths over ~7×levels unique nodes.
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
}

/// Corpus leg of the parity contract (evolution 0011): transient-path and
/// canonical-path remangling must agree — including on which symbols fail to
/// remangle — across the dyld-cache corpus. Env-gated with the 0008 parity
/// sweep family rather than folded into the default oracle: the leg pays two
/// demangles and two remangles per symbol, and the canonical side grows the
/// global `NodeCache` by the whole corpus, so the cost is not negligible
/// (decision recorded in evolution 0011). Run in release, once per runtime
/// path:
///
/// ```
/// DEMANGLING_PRINT_PARITY=1 swift test -c release --filter TransientRemangleParitySweep
/// DEMANGLING_PRINT_PARITY=1 DEMANGLING_FORCE_LEGACY_PATH=1 swift test -c release --filter TransientRemangleParitySweep
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEMANGLING_PRINT_PARITY"] == "1"), .serialized)
final class TransientRemangleParitySweep: DyldCacheSymbolTests, @unchecked Sendable {
    /// Synchronous so the sync `demangleAsNode` overload — the path under
    /// test — is the one selected inside this async test.
    private static func remangledOnBothPaths(_ mangled: String) -> (transient: String?, canonical: String?) {
        let transientMangled = (try? demangleAsNodeTransient(mangled)).flatMap { try? mangleAsString($0) }
        let canonicalMangled = (try? demangleAsNode(mangled)).flatMap { try? mangleAsString($0) }
        return (transientMangled, canonicalMangled)
    }

    @Test func transientRemangleMatchesCanonicalAcrossCorpus() async throws {
        let extracted = try await symbols(for: .SwiftUI, .SwiftUICore, .Foundation, .Combine)
        let corpus = Array(Set(extracted.map(\.stringValue))).sorted()
        try #require(!corpus.isEmpty, "remangle corpus unavailable on this machine")

        var comparedCount = 0
        var remangledCount = 0
        var mismatchCount = 0
        var mismatchSamples: [String] = []
        for mangled in corpus {
            let (transientMangled, canonicalMangled) = Self.remangledOnBothPaths(mangled)
            comparedCount += 1
            if canonicalMangled != nil { remangledCount += 1 }
            if transientMangled != canonicalMangled {
                mismatchCount += 1
                if mismatchSamples.count < 10 {
                    mismatchSamples.append(mangled)
                }
            }
        }
        print("[0011-remangle-parity] symbols=\(comparedCount) remangled=\(remangledCount) mismatches=\(mismatchCount)")
        if !mismatchSamples.isEmpty {
            print("[0011-remangle-parity] samples: \(mismatchSamples.joined(separator: ", "))")
        }
        #expect(mismatchCount == 0, "transient-path remangling must be byte-identical to the canonical path")
    }
}
