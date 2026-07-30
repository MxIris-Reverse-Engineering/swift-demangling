import Foundation

/// Flat, sharing-preserving `Codable` implementation.
///
/// The compiler-synthesized conformance recursed through `Payload` — one
/// encoder frame per tree level, so a deep tree overflowed the stack (the
/// same failure every other whole-tree walk in this library was rewritten to
/// avoid), and it expanded shared subtrees at every occurrence, so a DAG from
/// interning or substitution back-references exploded along its path count
/// (a real 65KB symbol's 48 unique nodes encoded as 131,070 entries).
///
/// This implementation encodes the node graph as a flat table instead:
///
/// ```json
/// { "nodes": [ {"kind": ..., "contents": ..., "children": [0, 1]}, ... ],
///   "root": 2 }
/// ```
///
/// Nodes appear in postorder, children referenced by table index. That makes
/// both passes iterative (deep-tree safe), keeps every unique node encoded
/// exactly once (sharing-preserving, output linear in graph size), and makes
/// cycles unrepresentable: decoding validates that every child index points
/// to an *earlier* entry, so a decoded graph is acyclic by construction.
///
/// This format replaces the synthesized one — data encoded by earlier
/// releases does not decode with this version.
extension Node: Codable {
    private enum FlatCodingKeys: String, CodingKey {
        case nodes
        case root
    }

    /// One row of the flat node table.
    private struct FlatEncodedNode: Codable {
        let kind: Kind
        let contents: Contents
        let childIndices: [Int]

        enum CodingKeys: String, CodingKey {
            case kind
            case contents
            case childIndices = "children"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var tableIndexBySourceIdentity: [ObjectIdentifier: Int] = [:]
        var flatNodes: [FlatEncodedNode] = []

        // Iterative postorder walk, memoized by instance identity: children
        // are appended to the table before their parent, and a shared
        // instance is appended only once.
        var frames: [(node: Node, nextChildIndex: Int)] = [(self, 0)]
        while let currentFrame = frames.last {
            let frameIndex = frames.count - 1
            if currentFrame.nextChildIndex < currentFrame.node.children.count {
                frames[frameIndex].nextChildIndex += 1
                let child = currentFrame.node.children[currentFrame.nextChildIndex]
                if tableIndexBySourceIdentity[ObjectIdentifier(child)] == nil {
                    frames.append((node: child, nextChildIndex: 0))
                }
                continue
            }
            frames.removeLast()
            let identifier = ObjectIdentifier(currentFrame.node)
            if tableIndexBySourceIdentity[identifier] == nil {
                tableIndexBySourceIdentity[identifier] = flatNodes.count
                flatNodes.append(FlatEncodedNode(
                    kind: currentFrame.node.kind,
                    contents: currentFrame.node.contents,
                    // Postorder guarantees every child already has an index.
                    childIndices: currentFrame.node.children.map { tableIndexBySourceIdentity[ObjectIdentifier($0)]! }
                ))
            }
        }

        var container = encoder.container(keyedBy: FlatCodingKeys.self)
        try container.encode(flatNodes, forKey: .nodes)
        try container.encode(flatNodes.count - 1, forKey: .root)
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlatCodingKeys.self)
        let flatNodes = try container.decode([FlatEncodedNode].self, forKey: .nodes)
        let rootIndex = try container.decode(Int.self, forKey: .root)
        guard flatNodes.indices.contains(rootIndex) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Root index \(rootIndex) is outside the node table (count \(flatNodes.count))."
            ))
        }

        var decodedNodes: [Node] = []
        decodedNodes.reserveCapacity(flatNodes.count)
        for (tableIndex, flatNode) in flatNodes.enumerated() {
            var decodedChildren: [Node] = []
            decodedChildren.reserveCapacity(flatNode.childIndices.count)
            for childIndex in flatNode.childIndices {
                // Only earlier entries are valid: rejecting self and forward
                // references is what makes a decoded graph acyclic by
                // construction.
                guard childIndex >= 0, childIndex < tableIndex else {
                    throw DecodingError.dataCorrupted(DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Node \(tableIndex) references child \(childIndex), which is not an earlier table entry."
                    ))
                }
                decodedChildren.append(decodedNodes[childIndex])
            }
            // Plain (non-interning) construction: decoded data is arbitrary
            // external input and must not pin entries in the global NodeCache.
            decodedNodes.append(Node(kind: flatNode.kind, contents: flatNode.contents, children: decodedChildren))
        }

        let decodedRoot = decodedNodes[rootIndex]
        self.init(kind: decodedRoot.kind, contents: decodedRoot.contents, inlineChildren: decodedRoot.children)
    }
}
