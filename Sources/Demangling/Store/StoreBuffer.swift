/// Self-managed heap storage for one flat store buffer (proposal 0010,
/// step 1): a bare allocation owned by a class, so that
///
/// - `NodeStoreBuilder.freeze()` hands the builder's buffers to the frozen
///   `NodeStore` as an ownership transfer — a reference move, no element
///   copy — and
/// - a shared store (proposal 0010, step 4) can keep a grown-out generation
///   alive after the writer moves to a bigger allocation, because published
///   reader views may still address the old base until their walk ends.
///
/// `ContiguousArray` could fill neither role: a shared store's readers hold
/// raw views into the buffer, so the writer's append path must never free or
/// CoW-copy storage behind them — growth has to be an explicit
/// allocate-copy-retire step whose timing the owner controls.
///
/// The class owns capacity only; the count of initialized elements lives with
/// whoever writes (the builder's `GrowableStoreBuffer` facade, or the frozen
/// store's immutable count). Elements are `BitwiseCopyable`, so
/// deinitialization is a no-op and `deinit` only frees the allocation.
@usableFromInline
final class StoreBuffer<Element: BitwiseCopyable>: @unchecked Sendable {
    @usableFromInline
    let baseAddress: UnsafeMutablePointer<Element>

    @usableFromInline
    let capacity: Int

    /// Elements actually allocated, which is `max(capacity, 1)`: an empty
    /// buffer still owns one element's page so `baseAddress` stays valid.
    ///
    /// Bounds checks that reason about the *allocation* must use this rather
    /// than `capacity`, which reports 0 for the initial generation and would
    /// make an overlap check against `baseAddress ..< baseAddress + capacity`
    /// an empty range — vacuously satisfied by every pointer, including one
    /// aliasing the live slot.
    @usableFromInline
    var allocatedCapacity: Int { Swift.max(capacity, 1) }

    @usableFromInline
    init(capacity: Int) {
        self.capacity = capacity
        // Always at least one element's allocation, so `baseAddress` is a
        // valid non-null pointer even for an empty buffer and zero-count
        // `UnsafeBufferPointer(start:count:)` views are well-formed.
        self.baseAddress = .allocate(capacity: Swift.max(capacity, 1))
    }

    deinit {
        baseAddress.deallocate()
    }
}

/// Append-only growable facade the builder writes through (proposal 0010,
/// step 1).
///
/// Reads are bounds-checked against the initialized count in every
/// configuration, matching the `ContiguousArray` semantics this replaces: an
/// out-of-range index traps deterministically instead of reading foreign
/// memory, in release too.
///
/// A value type on purpose, but **never copy one**: two copies would share one
/// `StoreBuffer` while tracking divergent counts, so each would append over
/// the other's elements — including elements already published to readers.
/// The hazard is silent data corruption, not a dangling pointer: `storage` is
/// a strong reference held by every copy, so a copy that can still write is
/// one that kept the page alive (this comment used to say the second copy to
/// grow would free a page the first still addresses; it cannot).
///
/// The type system does *not* rule that out, despite what this comment used to
/// claim. `NodeStoreBuilder` being `~Copyable` prevents copying the *builder*;
/// it says nothing about copying a buffer out of it, which any code inside
/// this module can still write (`let snapshot = self.nodes`). What actually
/// holds today is narrower and worth stating honestly: the only holder is
/// `NodeStoreBuilder`, and no code in it copies one. Enforcing the invariant
/// in the type system would mean making this `~Copyable` too — deliberately
/// not done yet, since that change ripples through every stored property and
/// accessor here (ReviewFindingsPR7 F15 addendum).
@usableFromInline
struct GrowableStoreBuffer<Element: BitwiseCopyable>: Sendable {
    @usableFromInline
    private(set) var storage: StoreBuffer<Element>

    @usableFromInline
    private(set) var count: Int = 0

    /// Present only when a shared store owns the enclosing builder (proposal
    /// 0010, step 4): receives each grown-out generation that published
    /// reader views may still address, so the owner can keep it alive.
    /// Without a sink (the frozen build-then-freeze flow) old generations
    /// simply deallocate — no reader can hold a view before `freeze()`.
    /// `@Sendable` so the enclosing builder keeps its `Sendable` conformance.
    @usableFromInline
    var retirementSink: (@Sendable (AnyObject) -> Void)?

    @usableFromInline
    init() {
        storage = StoreBuffer(capacity: 0)
    }

    @usableFromInline
    var capacity: Int { storage.capacity }

    @usableFromInline
    subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "Index out of range")
        return storage.baseAddress[index]
    }

    /// Borrows the initialized prefix for a range read (hashing, equality
    /// probes over stored edges and text bytes). The range subscript on the
    /// handed-out `UnsafeBufferPointer` only bounds-checks in debug — for a
    /// checked range read use `withBuffer(in:_:)`.
    @usableFromInline
    func withBuffer<Result>(_ body: (UnsafeBufferPointer<Element>) -> Result) -> Result {
        body(UnsafeBufferPointer(start: storage.baseAddress, count: count))
    }

    /// Borrows a bounds-checked slice of the initialized prefix: the range
    /// must sit inside the initialized count, trapping in release too — the
    /// range counterpart of `subscript(index:)`, restoring the
    /// `ContiguousArray` range-subscript semantics this storage replaced. A
    /// raw `UnsafeBufferPointer` range subscript checks bounds only in
    /// debug, and an unchecked over-read here would compare against
    /// uninitialized capacity and could alias two different trees to one
    /// index — silent data corruption, not a crash (ReviewFindingsPR7 F6).
    @usableFromInline
    func withBuffer<Result>(in range: Range<Int>, _ body: (UnsafeBufferPointer<Element>) -> Result) -> Result {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "Range out of range")
        return body(UnsafeBufferPointer(start: storage.baseAddress + range.lowerBound, count: range.count))
    }

    @usableFromInline
    mutating func append(_ element: Element) {
        ensureCapacity(count + 1)
        (storage.baseAddress + count).initialize(to: element)
        count += 1
    }

    /// - Precondition: `elements` must not alias this buffer's own storage.
    ///   `ensureCapacity` may grow, which frees the old page, so a source
    ///   pointing into that page would dangle by the time it is read. Every
    ///   caller today passes independent storage (a `String`'s UTF-8, a
    ///   separate `[UInt32]`); the precondition below pins that rather than
    ///   leaving it to be rediscovered (ReviewFindingsPR7 F15 addendum).
    @usableFromInline
    mutating func append(contentsOf elements: UnsafeBufferPointer<Element>) {
        guard let elementsBase = elements.baseAddress, !elements.isEmpty else { return }
        let existingBase = storage.baseAddress
        precondition(
            elementsBase + elements.count <= existingBase || elementsBase >= existingBase + storage.allocatedCapacity,
            "append(contentsOf:) source overlaps the destination buffer; growth would free it mid-copy"
        )
        ensureCapacity(count + elements.count)
        (storage.baseAddress + count).initialize(from: elementsBase, count: elements.count)
        count += elements.count
    }

    @usableFromInline
    mutating func append(contentsOf elements: [Element]) {
        elements.withUnsafeBufferPointer { append(contentsOf: $0) }
    }

    /// Growing only, like `ContiguousArray.reserveCapacity` as the builder
    /// uses it: a target at or below the current capacity is a no-op.
    ///
    /// Growth takes the doubling lower bound: under a shared store every
    /// replaced generation is retired into the keepalive chain for the
    /// store's lifetime, so exact-size growth would let k incremental
    /// reservations retire k full-size generations — O(k²) held memory for
    /// an indexer refining its estimate per image. Doubling caps the chain
    /// at a geometric series (less than one current buffer's worth of bytes)
    /// at the cost of at most 2× over-reservation (ReviewFindingsPR7 F8).
    @usableFromInline
    mutating func reserveCapacity(_ minimumCapacity: Int) {
        guard minimumCapacity > capacity else { return }
        grow(to: Swift.max(minimumCapacity, capacity * 2))
    }

    @usableFromInline
    mutating func ensureCapacity(_ requiredCapacity: Int) {
        if requiredCapacity > capacity {
            grow(to: Swift.max(requiredCapacity, capacity * 2, 16))
        }
    }

    private mutating func grow(to newCapacity: Int) {
        let grownStorage = StoreBuffer<Element>(capacity: newCapacity)
        if count > 0 {
            grownStorage.baseAddress.initialize(from: storage.baseAddress, count: count)
        }
        // Every replaced generation enters the sink, empty ones included: a
        // published descriptor (and a zero-length Span formed from it) can
        // record an empty generation's base address without ever
        // dereferencing it, and the shared store's contract is that any
        // descriptor a reader obtained keeps addressing live memory for the
        // store's whole lifetime — unconditionally. An empty generation's
        // keepalive costs one element's allocation, so the promise is cheap
        // to keep whole (ReviewFindingsPR7 F5, plan A; the earlier
        // free-empty-generations reasoning covered dereferences only and is
        // superseded in the 0010 decision log).
        retirementSink?(storage)
        storage = grownStorage
    }
}
