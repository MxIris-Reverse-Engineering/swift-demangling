extension NodeStore {
    /// The reader-side view descriptor (proposal 0010, step 3): the three
    /// flat buffers as plain `(base, count)` views, plus every pure read
    /// accessor over them.
    ///
    /// This is the unit a walk pins **once at its entry** and reads through
    /// for its whole duration. For a frozen store the descriptor is constant
    /// for the store's lifetime, so resolving it is a plain property load.
    /// The shared store (step 4) republishes a grown descriptor on growth;
    /// there the stale-view guarantees apply: retired buffers stay alive, and
    /// the bottom-up invariant (step 2) means a view that covers a root index
    /// covers the root's whole subtree.
    ///
    /// Validity is anchored by whoever resolved the view: the store must stay
    /// strongly referenced for at least as long as the view (or any pointer
    /// to it) is read.
    @usableFromInline
    struct BufferView {
        @usableFromInline
        let nodes: UnsafeBufferPointer<CompactNode>

        @usableFromInline
        let edges: UnsafeBufferPointer<UInt32>

        @usableFromInline
        let textBytes: UnsafeBufferPointer<UInt8>

        /// Whether every byte in `textBytes` is ASCII (builder-maintained);
        /// gates revalidation-free materialization in ``text(offset:length:)``
        /// (ReviewFindingsPR7 F11).
        @usableFromInline
        let textTableIsKnownASCII: Bool

        /// Snapshot of ``DemanglingRuntimePath/forcesLegacyPath`` taken when
        /// the owning store was created, so the store side of the dual-path
        /// seam is honored without a per-materialization lock read. The
        /// supported way to drive the legacy leg is the process-wide env var
        /// set at launch, which every store created in that process inherits
        /// (ReviewFindingsPR7 F11).
        @usableFromInline
        let usesLegacyTextMaterialization: Bool

        @usableFromInline
        init(
            nodes: UnsafeBufferPointer<CompactNode>,
            edges: UnsafeBufferPointer<UInt32>,
            textBytes: UnsafeBufferPointer<UInt8>,
            textTableIsKnownASCII: Bool,
            usesLegacyTextMaterialization: Bool
        ) {
            self.nodes = nodes
            self.edges = edges
            self.textBytes = textBytes
            self.textTableIsKnownASCII = textTableIsKnownASCII
            self.usesLegacyTextMaterialization = usesLegacyTextMaterialization
        }

        // MARK: - Node access

        @usableFromInline
        func compactNode(at rawIndex: UInt32) -> CompactNode {
            // Bounds-checked in release too, matching the `ContiguousArray`
            // subscript semantics the store has always had: an out-of-range
            // index traps instead of reading past the allocation.
            precondition(Int(rawIndex) < nodes.count, "Node index out of range for this store")
            return nodes[Int(rawIndex)]
        }

        /// Raw index of the `position`-th child of `compact`.
        @usableFromInline
        func rawChildIndex(of compact: CompactNode, at position: Int) -> UInt32 {
            switch compact.payloadKind {
            case .oneChild:
                precondition(position == 0, "Child index out of range")
                return compact.payloadWord0
            case .twoChildren:
                switch position {
                case 0: return compact.payloadWord0
                case 1: return compact.payloadWord1
                default: preconditionFailure("Child index out of range")
                }
            case .manyChildren:
                precondition(position >= 0 && position < Int(compact.payloadWord1), "Child index out of range")
                let edgeIndex = Int(compact.payloadWord0) + position
                precondition(edgeIndex < edges.count, "Edge index out of range for this store")
                return edges[edgeIndex]
            case .none, .index, .text:
                preconditionFailure("Child index out of range for a node without children")
            }
        }

        /// The index payload of `compact`, if it carries one.
        @usableFromInline
        func indexPayload(of compact: CompactNode) -> UInt64? {
            guard case .index = compact.payloadKind else { return nil }
            return UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32)
        }

        /// The contents of `compact` in exactly the form ``Node/contents``
        /// reports them — the single re-encoding point shared by
        /// `NodeReference.nodeContents` and the structural-digest walk, kept
        /// single so it cannot drift from `Node.hash(into:)`'s encoding.
        ///
        /// Deliberately reports `.none` for `.dependentGenericParamType`
        /// (whose name ``textOfNode(at:)`` synthesizes): `Node` stores depth
        /// and index as children there, so its `contents` is `.none` and so
        /// must this.
        @usableFromInline
        func contents(of compact: CompactNode) -> Node.Contents {
            switch compact.payloadKind {
            case .text:
                return .text(text(offset: compact.payloadWord0, length: compact.payloadWord1))
            case .index:
                return .index(UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32))
            case .none, .oneChild, .twoChildren, .manyChildren:
                return .none
            }
        }

        // MARK: - Text access

        @usableFromInline
        func text(offset: UInt32, length: UInt32) -> String {
            let start = Int(offset)
            let end = start + Int(length)
            precondition(end <= textBytes.count, "Text range out of range for this store")
            let textBuffer = UnsafeBufferPointer(start: textBytes.baseAddress! + start, count: Int(length))
            // Unchecked materialization needs a validity argument that holds
            // even for a wrong-but-in-bounds index (a foreign store's index
            // is documented UB, but it must not escalate into forging an
            // invalid `String`): when the whole table is ASCII, *any*
            // in-bounds subrange is valid UTF-8 on its own — the same gate
            // the demangler's `TextMaterializationStrategy` uses. Non-ASCII
            // tables (punycode-decoded identifiers) take the validating
            // decode, as does a store created under the legacy-path seam so
            // the dual-path double-run actually exercises this branch
            // (ReviewFindingsPR7 F11; proposal 0008, B1).
            if !usesLegacyTextMaterialization, textTableIsKnownASCII {
                if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
                    return String(copying: UTF8Span(unchecked: textBuffer.span))
                }
            }
            return String(decoding: textBuffer, as: UTF8.self)
        }

        /// Text of the node at `rawIndex` in exactly the form `Node.text`
        /// reports it: stored text for `.text` payloads, plus the synthesized
        /// generic parameter name for `.dependentGenericParamType` (which
        /// stores depth and index as children; the printer relies on the
        /// synthesis).
        @usableFromInline
        func textOfNode(at rawIndex: UInt32) -> String? {
            let compact = compactNode(at: rawIndex)
            if case .text = compact.payloadKind {
                return text(offset: compact.payloadWord0, length: compact.payloadWord1)
            }
            if compact.kind == .dependentGenericParamType {
                guard compact.childCount >= 2,
                      let depth = indexPayload(of: compactNode(at: rawChildIndex(of: compact, at: 0))),
                      let parameterIndex = indexPayload(of: compactNode(at: rawChildIndex(of: compact, at: 1)))
                else { return nil }
                return genericParameterName(depth: depth, index: parameterIndex)
            }
            return nil
        }

        /// Borrows the stored text bytes of the node at `rawIndex` (proposal
        /// 0008, B1). Returns nil — without calling `body` — when the node
        /// stores no text; `.dependentGenericParamType`'s synthesized name is
        /// not stored text (use ``textOfNode(at:)`` for the composed form).
        @usableFromInline
        func withTextUTF8<Result>(at rawIndex: UInt32, _ body: (Span<UInt8>) throws -> Result) rethrows -> Result? {
            let compact = compactNode(at: rawIndex)
            guard case .text = compact.payloadKind else { return nil }
            let start = Int(compact.payloadWord0)
            let length = Int(compact.payloadWord1)
            precondition(start + length <= textBytes.count, "Text range out of range for this store")
            let textBuffer = UnsafeBufferPointer(start: textBytes.baseAddress! + start, count: length)
            return try body(textBuffer.span)
        }

        /// Allocation-free text comparison against an ASCII needle, with the
        /// `String`-comparison fallback for non-ASCII needles (Unicode
        /// canonical equivalence) and for nodes whose text is synthesized
        /// rather than stored.
        @usableFromInline
        func nodeTextMatches(at rawIndex: UInt32, expected: String) -> Bool {
            let expectedUTF8 = expected.utf8
            guard expectedUTF8.allSatisfy({ $0 < 0x80 }) else {
                return textOfNode(at: rawIndex) == expected
            }
            let storedByteComparison = withTextUTF8(at: rawIndex) { spanBytes -> Bool in
                guard spanBytes.count == expectedUTF8.count else { return false }
                var byteOffset = 0
                for expectedByte in expectedUTF8 {
                    guard spanBytes[byteOffset] == expectedByte else { return false }
                    byteOffset += 1
                }
                return true
            }
            return storedByteComparison ?? (textOfNode(at: rawIndex) == expected)
        }

        // MARK: - Materialization

        /// Child indices of the given node, in order.
        private func childIndices(of compact: CompactNode) -> [UInt32] {
            switch compact.payloadKind {
            case .none, .index, .text:
                return []
            case .oneChild:
                return [compact.payloadWord0]
            case .twoChildren:
                return [compact.payloadWord0, compact.payloadWord1]
            case .manyChildren:
                let edgesStart = Int(compact.payloadWord0)
                let childCount = Int(compact.payloadWord1)
                precondition(edgesStart + childCount <= edges.count, "Edge range out of range for this store")
                return (edgesStart ..< (edgesStart + childCount)).map { edges[$0] }
            }
        }

        /// Builds the `Node` for one store index from already-materialized
        /// children.
        private func makeNode(from compact: CompactNode, children: [Node]) -> Node {
            switch compact.payloadKind {
            case .none:
                return Node(kind: compact.kind)
            case .index:
                return Node(kind: compact.kind, index: UInt64(compact.payloadWord0) | (UInt64(compact.payloadWord1) << 32))
            case .text:
                return Node(kind: compact.kind, text: text(offset: compact.payloadWord0, length: compact.payloadWord1))
            case .oneChild, .twoChildren, .manyChildren:
                return Node(kind: compact.kind, children: children)
            }
        }

        /// One suspended level of ``materializeNode(at:)``'s walk.
        private struct MaterializeFrame {
            let rawIndex: UInt32
            let compact: CompactNode
            let childIndices: [UInt32]
            var nextChildPosition: Int
            var materializedChildren: [Node]
        }

        /// Rebuilds a standalone `Node` tree for one store index.
        ///
        /// The returned tree is freshly constructed and does not interact
        /// with the global `NodeCache`. The store is hash-consed, so a
        /// subtree referenced from multiple parents is a single index; the
        /// memo rebuilds each index once and reuses the instance, preserving
        /// the store's DAG shape. Expanding instead would multiply node count
        /// for symbols with heavy substitution sharing and defeat the
        /// printer's per-instance memoization.
        ///
        /// Walked with an explicit stack. This is reached from the remangling
        /// bridge and from rich printer targets, both of which hand the
        /// result straight to another whole-tree walk, so a recursive version
        /// would stack two full-depth traversals of the deepest trees the
        /// store holds.
        @usableFromInline
        func materializeNode(at rawIndex: UInt32) -> Node {
            var materializedByIndex: [UInt32: Node] = [:]
            var frames: [MaterializeFrame] = []
            var completedChild: Node?

            func pushFrame(for index: UInt32) {
                let compact = compactNode(at: index)
                let indices = childIndices(of: compact)
                var frame = MaterializeFrame(
                    rawIndex: index,
                    compact: compact,
                    childIndices: indices,
                    nextChildPosition: 0,
                    materializedChildren: []
                )
                frame.materializedChildren.reserveCapacity(indices.count)
                frames.append(frame)
            }

            pushFrame(for: rawIndex)

            while var frame = frames.popLast() {
                if let child = completedChild {
                    frame.materializedChildren.append(child)
                    completedChild = nil
                }

                if frame.nextChildPosition < frame.childIndices.count {
                    let childIndex = frame.childIndices[frame.nextChildPosition]
                    frame.nextChildPosition += 1
                    frames.append(frame)

                    // The store is hash-consed, so a subtree referenced from
                    // several parents is one index; the memo rebuilds it once
                    // and reuses the instance, preserving the store's DAG
                    // shape.
                    if let shared = materializedByIndex[childIndex] {
                        completedChild = shared
                    } else {
                        pushFrame(for: childIndex)
                    }
                    continue
                }

                let node = makeNode(from: frame.compact, children: frame.materializedChildren)
                materializedByIndex[frame.rawIndex] = node
                if frames.isEmpty {
                    return node
                }
                completedChild = node
            }

            // Unreachable: the loop returns as soon as the root frame completes.
            return Node(kind: compactNode(at: rawIndex).kind)
        }
    }
}
