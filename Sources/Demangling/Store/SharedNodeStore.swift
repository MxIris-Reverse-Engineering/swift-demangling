import SwiftStdlibToolbox

/// The mutable half of a shared store's read path (proposal 0010, step 4):
/// one locked slot holding the current view descriptor, plus the keepalive
/// chain that makes stale descriptors permanently safe.
///
/// Readers copy the descriptor out under the lock — a 48-byte struct copy,
/// once per walk for the engines and once per access for scattered reads.
/// The writer republishes after every intern and appends each grown-out
/// buffer generation to the retirement chain, so any descriptor a reader ever
/// obtained keeps addressing live memory for the store's whole lifetime.
///
/// Lock ordering: the shared store's writer lock is always taken first, this
/// slot's lock second; readers take only this slot's lock. The pair can
/// therefore never deadlock.
@usableFromInline
final class SharedViewState: Sendable {
    /// `@unchecked` because the descriptor's buffer pointers and the erased
    /// `[AnyObject]` anchors defeat inference: every access to a `State`
    /// value goes through the enclosing `Mutex`, the pointed-to buffers are
    /// `StoreBuffer` instances (themselves `@unchecked Sendable`), and
    /// published elements are write-once — the same contract
    /// `UnretainedNodeReference` documents.
    @usableFromInline
    struct State: @unchecked Sendable {
        /// The descriptor readers resolve; covers exactly the elements whose
        /// interning completed before the last publish.
        var view: NodeStore.BufferView
        /// The current buffer generations backing `view` — three stored
        /// fields, not an array: publish runs once per intern under the
        /// writer lock, and an `[AnyObject]` literal there allocated on
        /// every single intern (PR #7 review, supplementary finding 5).
        var currentNodesBuffer: AnyObject
        var currentEdgesBuffer: AnyObject
        var currentTextBuffer: AnyObject
        /// Every grown-out generation a published view may still address —
        /// empty generations included, because a descriptor (or a
        /// zero-length span formed from it) records a generation's base
        /// address without dereferencing it. Append-only; released as a
        /// whole when the store dies. Bounded by the doubling growth policy
        /// — which `reserveCapacity` growth also takes — at less than one
        /// current-buffer's worth of live bytes; reserving up front leaves
        /// only the initial empty generations in the chain.
        var retiredBuffers: [AnyObject]
    }

    @usableFromInline
    let state: Mutex<State>

    init(initialView: NodeStore.BufferView, nodesBuffer: AnyObject, edgesBuffer: AnyObject, textBuffer: AnyObject) {
        state = Mutex(State(
            view: initialView,
            currentNodesBuffer: nodesBuffer,
            currentEdgesBuffer: edgesBuffer,
            currentTextBuffer: textBuffer,
            retiredBuffers: []
        ))
    }

    @usableFromInline
    func currentView() -> NodeStore.BufferView {
        state.withLockUnchecked { $0.view }
    }

    func publish(view: NodeStore.BufferView, nodesBuffer: AnyObject, edgesBuffer: AnyObject, textBuffer: AnyObject) {
        state.withLockUnchecked { lockedState in
            lockedState.view = view
            // Identity stores on the common no-growth publish; a reassignment
            // only happens on the rare generation swap.
            if lockedState.currentNodesBuffer !== nodesBuffer { lockedState.currentNodesBuffer = nodesBuffer }
            if lockedState.currentEdgesBuffer !== edgesBuffer { lockedState.currentEdgesBuffer = edgesBuffer }
            if lockedState.currentTextBuffer !== textBuffer { lockedState.currentTextBuffer = textBuffer }
        }
    }

    func retire(_ retiredBuffer: AnyObject) {
        state.withLockUnchecked { lockedState in
            lockedState.retiredBuffers.append(retiredBuffer)
        }
    }

    /// Test-only visibility: how many grown-out generations the keepalive
    /// chain currently pins.
    var retiredBufferCountForTesting: Int {
        state.withLockUnchecked { $0.retiredBuffers.count }
    }
}

/// A long-lived, thread-safe interning arena: ``intern(_:)`` and
/// ``demangle(_:isType:symbolicReferenceResolver:)`` hand out permanently
/// valid `NodeReference`s immediately — no freeze barrier (evolution
/// proposal 0010).
///
/// This is the store for **incremental** workloads, where the input set is
/// discovered over time: type names surfacing while a user browses,
/// conformance and extension trees produced during indexing, late-arriving
/// symbols demangled on demand. The frozen `NodeStoreBuilder` → `freeze()`
/// flow remains the right tool for batch sweeps whose input set is known up
/// front — it drops the interning tables at freeze and its reads carry no
/// slot indirection at all.
///
/// Semantics:
///
/// - **One instance per scope** (per image, per process). All references
///   minted by one shared store carry one `NodeStore` identity, so
///   `NodeReference`'s intrinsic `==`/`hash` — store identity plus index —
///   is structural equality across everything interned here, and
///   `Set`/`Dictionary` deduplicate across the whole scope.
/// - **Persistent hash-consing**: the interning tables live as long as the
///   store, so structurally equal trees interned at any two moments resolve
///   to the same index and the same reference.
/// - **References never expire**: a reference keeps the backing `NodeStore`
///   alive, which keeps every buffer generation it may address alive —
///   including after the `SharedNodeStore` itself is released (interning
///   stops; reading never breaks).
/// - **Memory is reclaimed by releasing the whole store**, matching the
///   scope-cache eviction model downstream consumers already use. There is
///   no per-entry eviction, by design (same shape as `NodeCache`).
///
/// Concurrency: interning serializes on one writer lock; the transient parse
/// inside `demangle` runs outside it. Reads are wait-free against the writer
/// except for the descriptor resolution itself (a locked 48-byte copy —
/// once per walk for printing/equality engines, once per access for
/// scattered `kind`/`children` reads). Growth never invalidates readers:
/// grown-out buffers are retired into a keepalive chain, and the bottom-up
/// interning invariant guarantees any descriptor covering a root index
/// covers the root's whole subtree.
public final class SharedNodeStore: Sendable {
    /// All interning serializes here. Unlike the frozen flow, this builder
    /// is never consumed, so its interning tables — the source of persistent
    /// dedup — survive for the store's whole lifetime.
    private let writerState: Mutex<NodeStoreBuilder>

    /// The single `NodeStore` identity every reference minted here carries.
    @usableFromInline
    let backingStore: NodeStore

    private let sharedViewState: SharedViewState

    public init() {
        var builder = NodeStoreBuilder()
        let snapshot = builder.bufferSnapshot
        let viewState = SharedViewState(
            initialView: NodeStore.BufferView(
                nodes: UnsafeBufferPointer(start: snapshot.nodesStorage.baseAddress, count: 0),
                edges: UnsafeBufferPointer(start: snapshot.edgesStorage.baseAddress, count: 0),
                textBytes: UnsafeBufferPointer(start: snapshot.textStorage.baseAddress, count: 0),
                textTableIsKnownASCII: true,
                usesLegacyTextMaterialization: DemanglingRuntimePath.forcesLegacyPath
            ),
            nodesBuffer: snapshot.nodesStorage,
            edgesBuffer: snapshot.edgesStorage,
            textBuffer: snapshot.textStorage
        )
        builder.installRetirementSink { retiredBuffer in
            viewState.retire(retiredBuffer)
        }
        self.backingStore = NodeStore(
            sharedViewState: viewState,
            nodesStorage: snapshot.nodesStorage,
            edgesStorage: snapshot.edgesStorage,
            textStorage: snapshot.textStorage,
            storeTag: builder.issuedStoreTag
        )
        self.sharedViewState = viewState
        self.writerState = Mutex(builder)
    }

    /// Pre-sizes buffers and interning tables (proposal 0009 coefficients).
    ///
    /// The coefficients are calibrated per *symbol* on the bulk corpus; for
    /// name-tree workloads they overshoot, which is the safe direction. A
    /// reservation before the first intern also keeps the retirement chain
    /// empty — growth never happens, so nothing retires.
    public func reserveCapacity(expectedSymbolCount: Int) {
        writerState.withLockUnchecked { builder in
            builder.reserveCapacity(expectedSymbolCount: expectedSymbolCount)
            publishCurrentState(of: &builder)
        }
    }

    /// Interns a `Node` tree; structurally equal trees return the same
    /// reference, at any two points in the store's lifetime.
    public func intern(_ tree: Node) -> NodeReference {
        writerState.withLockUnchecked { builder in
            let rootIndex = builder.intern(tree)
            publishCurrentState(of: &builder)
            return backingStore.reference(at: rootIndex)
        }
    }

    /// Cache-free demangle straight into the arena — the transient parse
    /// runs outside the writer lock, only the intern serializes. Mirrors
    /// `NodeStoreBuilder.demangle`: nothing touches the global `NodeCache`.
    ///
    /// - Parameter symbolicReferenceResolver: resolves symbolic references
    ///   (`\u{01}`–`\u{0C}` markers) encountered in `mangled`; without a
    ///   resolver such symbols throw.
    public func demangle(
        _ mangled: String,
        isType: Bool = false,
        symbolicReferenceResolver: DemangleSymbolicReferenceResolver? = nil
    ) throws(DemanglingError) -> NodeReference {
        let transientTree = try demangleAsNodeTransient(mangled, isType: isType, symbolicReferenceResolver: symbolicReferenceResolver)
        return intern(transientTree)
    }

    /// Buffer/table utilization for coefficient re-calibration (proposal
    /// 0009); not a hot-path API.
    public var capacityUtilization: NodeStoreBuilder.CapacityUtilization {
        writerState.withLockUnchecked { $0.capacityUtilization }
    }

    /// Statistics of the currently published state; see the `NodeStore`
    /// counterparts.
    public var nodeCount: Int { backingStore.nodeCount }

    /// Total payload bytes currently published; see
    /// `NodeStore.storageByteCount`.
    public var storageByteCount: Int { backingStore.storageByteCount }

    /// Test-only visibility for the retirement bound.
    var retiredBufferCountForTesting: Int {
        sharedViewState.retiredBufferCountForTesting
    }

    /// Publishes the builder's current buffers and counts as the readers'
    /// descriptor. Runs while holding the writer lock; publishing before the
    /// minted reference escapes is what makes `reference(at:)`'s bounds check
    /// — and any reader that obtains the reference afterwards — see a
    /// descriptor covering it.
    private func publishCurrentState(of builder: inout NodeStoreBuilder) {
        let snapshot = builder.bufferSnapshot
        sharedViewState.publish(
            view: NodeStore.BufferView(
                nodes: UnsafeBufferPointer(start: snapshot.nodesStorage.baseAddress, count: snapshot.nodeCount),
                edges: UnsafeBufferPointer(start: snapshot.edgesStorage.baseAddress, count: snapshot.edgeCount),
                textBytes: UnsafeBufferPointer(start: snapshot.textStorage.baseAddress, count: snapshot.textByteCount),
                textTableIsKnownASCII: builder.textTableIsKnownASCII,
                usesLegacyTextMaterialization: backingStore.usesLegacyTextMaterialization
            ),
            nodesBuffer: snapshot.nodesStorage,
            edgesBuffer: snapshot.edgesStorage,
            textBuffer: snapshot.textStorage
        )
    }
}
