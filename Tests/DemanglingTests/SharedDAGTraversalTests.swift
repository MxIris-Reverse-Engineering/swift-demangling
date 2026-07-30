import Foundation
import Testing
@testable import Demangling

/// Regressions for the shared-DAG traversal defects from the node-store
/// review: interning and substitution back-references make demangled trees
/// DAGs, and every whole-tree rebuild that re-expanded a shared subtree at
/// each occurrence multiplied along nesting — a real 65KB round-tripped
/// symbol with 48 unique nodes cost 131,070 node visits in `copy()`, and a
/// 120-character symbol dumped a 366MB `description`. These tests pin the
/// memoized behavior: traversal cost tracks the graph's node count, never its
/// path count.
@Suite
struct SharedDAGTraversalTests {
    /// Nested pairs of the same instance: depth 40 means 2^40 ≈ 10^12 paths,
    /// so any unmemoized whole-graph walk fails by timeout, not by assertion.
    private static func makeSharedPairGraph(depth: Int) -> Node {
        var currentLevel = Node.create(kind: .type, children: [
            Node.create(kind: .structure, children: [
                Node.create(kind: .module, text: "Swift"),
                Node.create(kind: .identifier, text: "Int"),
            ]),
        ])
        for _ in 0 ..< depth {
            let element = Node.create(kind: .tupleElement, children: [currentLevel])
            currentLevel = Node.create(kind: .type, children: [
                Node.create(kind: .tuple, children: [element, element]),
            ])
        }
        return currentLevel
    }

    private static func uniqueNodeCount(of root: Node) -> Int {
        var visitedIdentifiers: Set<ObjectIdentifier> = []
        var pendingNodes = [root]
        while let node = pendingNodes.popLast() {
            guard visitedIdentifiers.insert(ObjectIdentifier(node)).inserted else { continue }
            pendingNodes.append(contentsOf: node.children)
        }
        return visitedIdentifiers.count
    }

    // MARK: - copy() / NodeBuilder seeding

    @Test func copyPreservesSharingInsteadOfExpandingIt() {
        let sharedGraph = Self.makeSharedPairGraph(depth: 40)
        let originalUniqueCount = Self.uniqueNodeCount(of: sharedGraph)

        let copiedGraph = sharedGraph.copy()

        #expect(copiedGraph !== sharedGraph)
        #expect(copiedGraph == sharedGraph, "the copy is structurally identical")
        #expect(Self.uniqueNodeCount(of: copiedGraph) == originalUniqueCount,
                "shared source subtrees must stay shared in the copy")

        // Sharing is preserved *and* nothing is shared with the original.
        let copiedTuple = copiedGraph.children[0]
        #expect(copiedTuple.children[0] === copiedTuple.children[1])
        #expect(copiedTuple.children[0] !== sharedGraph.children[0].children[0])
    }

    @Test func nodeBuilderSeedingDoesNotExpandASharedGraph() {
        let sharedGraph = Self.makeSharedPairGraph(depth: 40)
        let rebuiltGraph = NodeBuilder(sharedGraph).build()

        #expect(rebuiltGraph !== sharedGraph)
        #expect(rebuiltGraph == sharedGraph)
        // Seeding is a shallow copy: the children are the same frozen
        // instances, so the graph's size cannot change at all.
        #expect(rebuiltGraph.children.first === sharedGraph.children.first)
    }

    @Test func replacingDescendantPreservesSharing() throws {
        let sharedGraph = Self.makeSharedPairGraph(depth: 40)
        let originalUniqueCount = Self.uniqueNodeCount(of: sharedGraph)

        let oldLeaf = try #require(sharedGraph.first(of: .identifier))
        let newLeaf = Node.create(kind: .identifier, text: "Double")
        let rewrittenGraph = sharedGraph.replacingDescendant(oldLeaf, with: newLeaf)

        #expect(Self.uniqueNodeCount(of: rewrittenGraph) == originalUniqueCount)
        #expect(rewrittenGraph.first(of: .identifier)?.text == "Double")
        #expect(sharedGraph.first(of: .identifier)?.text == "Int", "the original is untouched")
    }

    // MARK: - Rewriter

    @Test func rewriterVisitsEachUniqueInstanceOnce() {
        final class CountingRewriter: Node.Rewriter {
            var visitCount = 0
            override func visit(_ node: Node) -> Node {
                visitCount += 1
                return node
            }
        }

        let sharedGraph = Self.makeSharedPairGraph(depth: 40)
        let uniqueCount = Self.uniqueNodeCount(of: sharedGraph)

        let countingRewriter = CountingRewriter()
        let rewrittenGraph = countingRewriter.rewrite(sharedGraph)

        #expect(rewrittenGraph === sharedGraph, "an identity rewrite returns the original instance")
        #expect(countingRewriter.visitCount == uniqueCount,
                "visit ran \(countingRewriter.visitCount) times for \(uniqueCount) unique nodes")
    }

    @Test func rewriterTransformationPreservesSharing() {
        final class LeafRenamingRewriter: Node.Rewriter {
            override func visit(_ node: Node) -> Node {
                guard node.kind == .identifier, node.text == "Int" else { return node }
                return Node.create(kind: .identifier, text: "Double")
            }
        }

        let sharedGraph = Self.makeSharedPairGraph(depth: 40)
        let rewrittenGraph = LeafRenamingRewriter().rewrite(sharedGraph)

        #expect(rewrittenGraph !== sharedGraph)
        #expect(rewrittenGraph.first(of: .identifier)?.text == "Double")
        let rewrittenTuple = rewrittenGraph.children[0]
        #expect(rewrittenTuple.children[0] === rewrittenTuple.children[1],
                "a rewritten shared subtree is rebuilt once and reused")
    }

    // MARK: - description

    @Test func descriptionExpandsSharedInteriorSubtreesOnce() {
        let sharedGraph = Self.makeSharedPairGraph(depth: 40)

        // 2^40 paths: an unmemoized dump would be terabytes. The labeled dump
        // is linear in the graph — comfortably under a few hundred lines.
        let dump = sharedGraph.description
        #expect(dump.utf8.count < 50_000, "dump was \(dump.utf8.count) bytes")
        #expect(dump.contains("(shared #1)"))
        #expect(dump.contains("(see #1)"))
    }

    @Test func descriptionOfAnUnsharedTreeIsUnchanged() throws {
        // No interior sharing → no labels, the familiar plain dump.
        let unsharedTree = try demangleAsNode("$s4main3fooyySiF", internsSubtrees: false)
        let dump = unsharedTree.description
        #expect(!dump.contains("(shared #"))
        #expect(!dump.contains("(see #"))
        #expect(dump.contains("kind=Global"))
    }

    // MARK: - Codable

    @Test func codableRoundTripsARealSymbol() throws {
        let originalTree = try demangleAsNode("$s10Foundation4DataV5countSivg")

        let encodedData = try JSONEncoder().encode(originalTree)
        let decodedTree = try JSONDecoder().decode(Node.self, from: encodedData)

        #expect(decodedTree == originalTree)
        #expect(decodedTree.print(using: .default) == originalTree.print(using: .default))
    }

    @Test func codableOutputIsLinearInGraphSizeAndDecodePreservesSharing() throws {
        let sharedGraph = Self.makeSharedPairGraph(depth: 40)
        let uniqueCount = Self.uniqueNodeCount(of: sharedGraph)

        let encodedData = try JSONEncoder().encode(sharedGraph)
        #expect(encodedData.count < 50_000, "encoded \(uniqueCount) unique nodes as \(encodedData.count) bytes")

        let decodedGraph = try JSONDecoder().decode(Node.self, from: encodedData)
        #expect(decodedGraph == sharedGraph)
        #expect(Self.uniqueNodeCount(of: decodedGraph) == uniqueCount, "decode must rebuild the sharing, not expand it")
    }

    @Test func codableSurvivesADeepChain() throws {
        // The synthesized conformance recursed once per level and overflowed
        // the stack; the flat format is iterative on both passes.
        var deepChain = Node.create(kind: .identifier, text: "leaf")
        for _ in 0 ..< 50_000 {
            deepChain = Node.create(kind: .type, children: [deepChain])
        }

        let encodedData = try JSONEncoder().encode(deepChain)
        let decodedChain = try JSONDecoder().decode(Node.self, from: encodedData)
        #expect(decodedChain == deepChain)
    }

    @Test func codableRejectsForwardAndSelfReferences() throws {
        // A self-referential row: decoding must throw, not build a cycle.
        let selfReferentialJSON = Data("""
        {"nodes": [{"kind": "type", "contents": {"none": {}}, "children": [0]}], "root": 0}
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Node.self, from: selfReferentialJSON)
        }

        let forwardReferenceJSON = Data("""
        {"nodes": [{"kind": "type", "contents": {"none": {}}, "children": [1]},
                   {"kind": "tuple", "contents": {"none": {}}, "children": []}], "root": 1}
        """.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Node.self, from: forwardReferenceJSON)
        }
    }
}
