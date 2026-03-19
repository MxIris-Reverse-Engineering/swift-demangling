public struct NodePrintContext {
    public let node: Node?
    public let parentKind: Node.Kind?
    public let state: NodePrintState

    public static func context(for node: Node? = nil, parentKind: Node.Kind? = nil, state: NodePrintState) -> NodePrintContext {
        NodePrintContext(node: node, parentKind: parentKind, state: state)
    }
}
