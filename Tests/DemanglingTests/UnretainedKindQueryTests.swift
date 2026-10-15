import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// `first(of:)` and `contains(_:)` on a `NodeReference` walk the store through
/// one pinned view without retaining the store per visited node (evolution
/// proposal `unretained-kind-queries`). A downstream host querying one shared
/// store from fourteen threads at once spent most of its time fighting over
/// that store's reference count, ten times the CPU of a serial run.
///
/// The answers must be the class tree's: same first match in preorder, same
/// "found anything", on frozen and on shared stores, on real symbols and on a
/// DAG whose path count no walk could survive.
@Suite
struct UnretainedKindQueryTests {
    private static let sampleSymbols = [
        "$s7SwiftUI4ViewPAAE4task8priority_QrScP_yyYaYbScMYccntF",
        "$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF",
        "$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF",
        "$ss2eeoiySbx_xtSQRzlF",
        "$s4main3fooyyF.resume.0",
        "$sSo17OS_dispatch_queueC4sync7executeyyyXE_tFTOTA",
        "$sSaySiGD",
    ]

    private static func completesWithinTimeout(_ timeout: TimeInterval = 30, _ body: @escaping @Sendable () -> Void) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            body()
            finished.signal()
        }
        return finished.wait(timeout: .now() + timeout) == .success
    }

    /// Every kind, asked of every root: the store's answer materialized must
    /// be the class tree's answer, and `contains` must agree with it.
    private static func mismatches(in references: [NodeReference]) -> [String] {
        var mismatches: [String] = []
        for reference in references {
            let tree = reference.materialize()
            for kind in Node.Kind.allCases {
                let storeMatch = reference.first(of: kind)?.materialize()
                let treeMatch = tree.first(of: kind)
                if storeMatch != treeMatch {
                    mismatches.append("\(kind) in \(tree.print(using: .default)): store \(storeMatch.map { $0.print(using: .default) } ?? "nil"), tree \(treeMatch.map { $0.print(using: .default) } ?? "nil")")
                }
                if reference.contains(kind) != tree.contains(kind) {
                    mismatches.append("contains(\(kind)) in \(tree.print(using: .default)) disagrees")
                }
            }
            let variadicStoreMatch = reference.first(of: .identifier, .module)?.materialize()
            let variadicTreeMatch = tree.first(of: .identifier, .module)
            if variadicStoreMatch != variadicTreeMatch {
                mismatches.append("first(of: .identifier, .module) in \(tree.print(using: .default)) disagrees")
            }
        }
        return mismatches
    }

    @Test func frozenStoreQueriesAgreeWithTheClassTree() throws {
        var builder = NodeStoreBuilder()
        let rootIndices = try Self.sampleSymbols.map { try builder.demangle($0) }
        let store = builder.freeze()
        let mismatches = Self.mismatches(in: rootIndices.map { store.reference(at: $0) })
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).joined(separator: "\n"))")
    }

    /// A shared store resolves its view through a locked slot rather than a
    /// constant; the walk pins whatever view it resolved at entry.
    @Test func sharedStoreQueriesAgreeWithTheClassTree() throws {
        let sharedStore = SharedNodeStore()
        let references = try Self.sampleSymbols.map { try sharedStore.demangle($0) }
        let mismatches = Self.mismatches(in: references)
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5).joined(separator: "\n"))")
    }

    /// Node N has two children that are both node N−1: sixty levels are 2^60
    /// paths but about 4 × 60 unique nodes. A fruitless query visits every
    /// unique node once and finishes; a path-priced one would never return.
    @Test func queriesOnADoublingDagStayNodePriced() throws {
        var builder = NodeStoreBuilder()
        let moduleIndex = builder.intern(kind: .module, text: "Swift")
        let nameIndex = builder.intern(kind: .identifier, text: "Dictionary")
        var currentIndex = builder.intern(kind: .structure, children: [moduleIndex, builder.intern(kind: .identifier, text: "Int")])
        for _ in 0 ..< 60 {
            let typeIndex = builder.intern(kind: .type, children: [currentIndex])
            let typeListIndex = builder.intern(kind: .typeList, children: [typeIndex, typeIndex])
            currentIndex = builder.intern(kind: .boundGenericStructure, children: [
                builder.intern(kind: .type, children: [builder.intern(kind: .structure, children: [moduleIndex, nameIndex])]),
                typeListIndex,
            ])
        }
        let rootReference = builder.freeze().reference(at: currentIndex)

        final class Answers: @unchecked Sendable {
            var fruitlessQueryFoundNothing = false
            var containsModule = false
            var firstIdentifierText: String?
        }
        let answers = Answers()
        let finished = Self.completesWithinTimeout {
            answers.fruitlessQueryFoundNothing = rootReference.first(of: .protocolConformance) == nil
            answers.containsModule = rootReference.contains(.module)
            answers.firstIdentifierText = rootReference.first(of: .identifier)?.text
        }
        try #require(finished, "a kind query on a doubling DAG must cost the node count, not the path count")
        #expect(answers.fruitlessQueryFoundNothing)
        #expect(answers.containsModule)
        #expect(answers.firstIdentifierText == "Dictionary")
    }

    /// A conformer whose deduped walk deliberately answers itself whatever is
    /// asked, so a generic call reveals which implementation it bound. The
    /// walk is a requirement precisely so that `NodeReference`'s pinned one is
    /// selected from generic code too — the shape `runPrintWalk` and
    /// `hasChildren` each had to be promoted for.
    private struct KindQueryDispatchProbe: DemanglingNode, Sequence {
        struct ChildrenView: DemanglingNodeChildren {
            var storage: [KindQueryDispatchProbe]
            var startIndex: Int { 0 }
            var endIndex: Int { storage.count }
            subscript(position: Int) -> KindQueryDispatchProbe { storage[position] }
            func at(_ index: Int) -> KindQueryDispatchProbe? {
                storage.indices.contains(index) ? storage[index] : nil
            }
            func slice(_ from: Int, _ to: Int) -> ArraySlice<KindQueryDispatchProbe> {
                storage[from ..< to]
            }
        }

        var marker: Int = 0

        var kind: Node.Kind { .identifier }
        var text: String? { nil }
        var index: UInt64? { nil }
        var hasIndex: Bool { false }
        var children: ChildrenView { ChildrenView(storage: []) }
        var printCacheIdentity: Int { marker }
        var materializedNode: Node { Node.createTransient(kind: .identifier) }
        func isIdentifier(desired: String) -> Bool { false }
        var isSwiftModule: Bool { false }
        var hasChildren: Bool { false }

        func makeIterator() -> IndexingIterator<[KindQueryDispatchProbe]> {
            [self].makeIterator()
        }

        /// Answers a probe marked 42 for every query — the default walk would
        /// answer `nil` for any kind but `.identifier`.
        func firstNodeInDedupedPreorder(matching kindMatches: (Node.Kind) -> Bool) -> KindQueryDispatchProbe? {
            KindQueryDispatchProbe(marker: 42)
        }
    }

    @Test func kindQueriesDispatchThroughTheWitnessTable() {
        func genericFirst<SomeNode: DemanglingNode & Sequence>(_ node: SomeNode, of kind: Node.Kind) -> SomeNode? where SomeNode.Element == SomeNode {
            node.first(of: kind)
        }
        func genericContains<SomeNode: DemanglingNode & Sequence>(_ node: SomeNode, _ kind: Node.Kind) -> Bool where SomeNode.Element == SomeNode {
            node.contains(kind)
        }

        let probe = KindQueryDispatchProbe()
        #expect(genericFirst(probe, of: .module)?.marker == 42, "generic first(of:) must select the witness")
        #expect(genericContains(probe, .module), "generic contains must select the witness")
    }
}
