/// Flat 12-byte node representation used by `SymbolStore`.
///
/// Nodes live in one contiguous buffer and refer to each other by `UInt32`
/// indices instead of pointers, eliminating per-node heap allocations, object
/// headers, and reference counting. The layout mirrors the mutual-exclusivity
/// invariant of `Node.Payload`: a node carries either contents (text/index)
/// or children, never both.
@usableFromInline
struct CompactNode: Hashable, Sendable {
    /// Bits 0-8: kind ordinal (see `Node.Kind.storeOrdinal`).
    /// Bits 9-11: payload kind. Bits 12-15: reserved.
    @usableFromInline
    var kindAndPayloadKind: UInt16

    /// First 32-bit payload word; meaning depends on `payloadKind`.
    @usableFromInline
    var payloadWord0: UInt32

    /// Second 32-bit payload word; meaning depends on `payloadKind`.
    @usableFromInline
    var payloadWord1: UInt32
}

extension CompactNode {
    @usableFromInline
    enum PayloadKind: UInt16, Sendable {
        /// No contents and no children.
        case none = 0
        /// `payloadWord0` = low 32 bits, `payloadWord1` = high 32 bits of a `UInt64` index.
        case index = 1
        /// `payloadWord0` = offset into the store's text bytes, `payloadWord1` = byte length.
        case text = 2
        /// `payloadWord0` = child node index.
        case oneChild = 3
        /// `payloadWord0` / `payloadWord1` = child node indices.
        case twoChildren = 4
        /// `payloadWord0` = offset into the store's edges buffer, `payloadWord1` = child count.
        case manyChildren = 5
    }

    @usableFromInline
    static let payloadKindShift: UInt16 = 9

    @usableFromInline
    static let kindOrdinalMask: UInt16 = (1 << payloadKindShift) - 1

    @usableFromInline
    init(kind: Node.Kind, payloadKind: PayloadKind, payloadWord0: UInt32, payloadWord1: UInt32) {
        self.kindAndPayloadKind = kind.storeOrdinal | (payloadKind.rawValue << Self.payloadKindShift)
        self.payloadWord0 = payloadWord0
        self.payloadWord1 = payloadWord1
    }

    @usableFromInline
    var kind: Node.Kind {
        Node.Kind.kindsByStoreOrdinal[Int(kindAndPayloadKind & Self.kindOrdinalMask)]
    }

    @usableFromInline
    var payloadKind: PayloadKind {
        PayloadKind(rawValue: kindAndPayloadKind >> Self.payloadKindShift)!
    }

    @usableFromInline
    var childCount: Int {
        switch payloadKind {
        case .none, .index, .text: return 0
        case .oneChild: return 1
        case .twoChildren: return 2
        case .manyChildren: return Int(payloadWord1)
        }
    }
}

extension Node.Kind {
    /// Kinds in ordinal order. The ordinal is the position in `allCases` and is
    /// only stable within a single process run — it is NOT a serialization
    /// format. A persisted store format (proposal 0001 Phase 4) must define its
    /// own stable kind mapping.
    @usableFromInline
    static let kindsByStoreOrdinal: [Node.Kind] = {
        let orderedKinds = Array(allCases)
        precondition(
            orderedKinds.count <= Int(CompactNode.kindOrdinalMask) + 1,
            "Node.Kind no longer fits the 9-bit ordinal space of CompactNode"
        )
        return orderedKinds
    }()

    @usableFromInline
    static let storeOrdinalsByKind: [Node.Kind: UInt16] = {
        var ordinals = [Node.Kind: UInt16](minimumCapacity: kindsByStoreOrdinal.count)
        for (ordinal, kind) in kindsByStoreOrdinal.enumerated() {
            ordinals[kind] = UInt16(ordinal)
        }
        return ordinals
    }()

    @usableFromInline
    var storeOrdinal: UInt16 {
        Self.storeOrdinalsByKind[self]!
    }
}
