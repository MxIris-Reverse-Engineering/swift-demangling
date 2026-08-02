public protocol NodePrinterTarget: Sendable {
    init()
    var count: Int { get }
    mutating func write(_ content: String)
    /// Writes `content` together with the semantic context of the node it
    /// came from, so rich targets can attach per-component annotations.
    ///
    /// The context is delivered lazily: building a `NodePrintContext` on the
    /// store path materializes a `Node` subtree, and only targets that
    /// actually use the context (rich targets) should pay that cost. A target
    /// that ignores it never evaluates the autoclosure, keeping the plain-text
    /// store path materialization-free — see `String`'s forwarding conformance
    /// for the shape a plain-text target wants.
    ///
    /// - Important: the parameter is `@autoclosure () -> NodePrintContext?`,
    ///   **not** `NodePrintContext?`, and this requirement deliberately has
    ///   **no default implementation**. A forwarding default used to live in
    ///   the protocol extension, which made the difference invisible: an
    ///   implementation written against the earlier eager signature is not a
    ///   witness, so the default silently took its place, the printed text
    ///   stayed byte-identical and every context annotation disappeared, with
    ///   no diagnostic — Swift has no warning for a near-miss witness when a
    ///   default exists. Without the default, that same near-miss is a
    ///   conformance error at the definition site. The cost is that every
    ///   target must spell this method out, including plain-text ones; that is
    ///   the intended trade.
    mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?)
    /// Append the entire contents of another target. Required so
    /// `NodePrinter` can splice memoized fragments into the output without
    /// losing semantic context (a plain `write(_:String)` would drop any
    /// per-component annotations carried by richer targets).
    mutating func append(_ other: Self)
    /// Marks that all subsequent writes belong to the type reference
    /// `node` (innermost scope wins) until the matching pop. Passing `nil`
    /// acts as a barrier: writes inside belong to NO type reference unless
    /// a nested push overrides it. Printers push the enclosing nominal
    /// node around a full qualified-name print (module, dots, identifier)
    /// so rich targets can group those writes into one logical span.
    ///
    /// The node is delivered lazily: store-backed printing must materialize
    /// a `Node` to service this hook, and only targets that actually use
    /// scope identity (rich targets) should pay that cost. A target that
    /// ignores scopes never evaluates the autoclosure, keeping the plain-text
    /// store path allocation-free.
    ///
    /// - Important: the parameter is `@autoclosure () -> Node?`, **not**
    ///   `Node?`, and like ``write(_:context:)`` this requirement has **no
    ///   default implementation** — for the same reason. A no-op default used
    ///   to absorb an implementation written against the earlier `Node?`
    ///   signature, so scope events vanished with byte-identical text and no
    ///   diagnostic, which a text-comparison snapshot test cannot see either.
    ///   A near-miss is now a conformance error instead.
    mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?)
    mutating func popTypeReferenceScope()
}

extension NodePrinterTarget {
    /// Kept as a default: it takes no argument, so there is no near-miss
    /// signature for it to absorb — the hazard that removed the defaults for
    /// ``write(_:context:)`` and ``pushTypeReferenceScope(_:)`` cannot arise
    /// here.
    public mutating func popTypeReferenceScope() {}

    public mutating func writeSpace(_ count: Int = 1) {
        write(" ")
    }

    public mutating func writeBreakLine() {
        write("\n")
    }
}

/// The reference plain-text target. Both hooks forward without evaluating
/// their autoclosure, so printing a store-backed tree into a `String`
/// materializes no `Node`; copy this shape for any other target that does not
/// care about semantic context.
extension String: NodePrinterTarget {
    public mutating func write(_ content: String, context: @autoclosure () -> NodePrintContext?) {
        write(content)
    }

    public mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {}
}
