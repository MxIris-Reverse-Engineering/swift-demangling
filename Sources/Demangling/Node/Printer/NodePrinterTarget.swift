public protocol NodePrinterTarget: Sendable {
    init()
    var count: Int { get }
    mutating func write(_ content: String)
    mutating func write(_ content: String, context: NodePrintContext?)
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
    /// scope identity (rich targets) should pay that cost. Targets that
    /// ignore scopes (`String`, the default implementation) never evaluate
    /// the autoclosure, keeping the plain-text store path allocation-free.
    ///
    /// - Important: the parameter is `@autoclosure () -> Node?`, **not**
    ///   `Node?`. An implementation written against the earlier `Node?`
    ///   signature does not satisfy this requirement, so the no-op default
    ///   below silently takes its place: the printed text stays byte-identical
    ///   and every scope event disappears. Nothing warns about this — Swift has
    ///   no diagnostic for a near-miss witness when a default exists — and a
    ///   text-comparison snapshot test cannot see it either. If a rich target
    ///   stops receiving scopes, check this signature first.
    mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?)
    mutating func popTypeReferenceScope()
}

extension NodePrinterTarget {
    public mutating func write(_ content: String, context: NodePrintContext?) {
        write(content)
    }

    public mutating func pushTypeReferenceScope(_ node: @autoclosure () -> Node?) {}

    public mutating func popTypeReferenceScope() {}

    public mutating func writeSpace(_ count: Int = 1) {
        write(" ")
    }

    public mutating func writeBreakLine() {
        write("\n")
    }
}

extension String: NodePrinterTarget {}
