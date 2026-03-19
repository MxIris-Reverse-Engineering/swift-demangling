public protocol NodePrinterTarget: Sendable {
    init()
    var count: Int { get }
    mutating func write(_ content: String)
    mutating func write(_ content: String, context: NodePrintContext?)
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
