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
}

extension NodePrinterTarget {
    public mutating func write(_ content: String, context: NodePrintContext?) {
        write(content)
    }

    public mutating func writeSpace(_ count: Int = 1) {
        write(" ")
    }

    public mutating func writeBreakLine() {
        write("\n")
    }
}

extension String: NodePrinterTarget {}
