/// The context delivered to ``NodePrinterTarget/write(_:context:)``.
///
/// The `Sendable` conformance is spelled out rather than left to inference,
/// and it is load-bearing: implicit inference does not cross the module
/// boundary for a `public` type, so downstream a `NodePrinterTarget` — which
/// refines `Sendable` — could not store the context it is handed, which is the
/// entire point of the hook. In-module tests never see it, because there the
/// inference applies. `NodePrintState` carries its own conformance for exactly
/// this reason; this type holds one and had been left behind.
public struct NodePrintContext: Sendable {
    public let node: Node?
    public let parentKind: Node.Kind?
    public let state: NodePrintState

    public static func context(for node: Node? = nil, parentKind: Node.Kind? = nil, state: NodePrintState) -> NodePrintContext {
        NodePrintContext(node: node, parentKind: parentKind, state: state)
    }
}
