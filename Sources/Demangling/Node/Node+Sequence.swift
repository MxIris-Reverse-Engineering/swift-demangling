// The traversal machinery (preorder/inorder/postorder/levelorder) and the
// kind-lookup helpers (first(of:), all(of:), contains(_:), filter(of:)) live
// in DemanglingNode+Sequence.swift as single generic implementations shared
// with NodeReference — do not re-add Node-specific copies here.
extension Node: Sequence {
    public typealias Element = Node

    public func makeIterator() -> some IteratorProtocol<Node> {
        preorder().makeIterator()
    }
}
