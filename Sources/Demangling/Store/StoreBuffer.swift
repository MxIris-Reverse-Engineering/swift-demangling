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
/// A value type on purpose, but **never copy one**: two copies would share
/// one `StoreBuffer` while tracking divergent counts. Its only holder is
/// `NodeStoreBuilder`, which is `~Copyable`, so the type system already rules
/// the aliasing copy out end to end.
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
    /// probes over stored edges and text bytes).
    @usableFromInline
    func withBuffer<Result>(_ body: (UnsafeBufferPointer<Element>) -> Result) -> Result {
        body(UnsafeBufferPointer(start: storage.baseAddress, count: count))
    }

    @usableFromInline
    mutating func append(_ element: Element) {
        ensureCapacity(count + 1)
        (storage.baseAddress + count).initialize(to: element)
        count += 1
    }

    @usableFromInline
    mutating func append(contentsOf elements: UnsafeBufferPointer<Element>) {
        guard let elementsBase = elements.baseAddress, !elements.isEmpty else { return }
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
    @usableFromInline
    mutating func reserveCapacity(_ minimumCapacity: Int) {
        guard minimumCapacity > capacity else { return }
        grow(to: minimumCapacity)
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
            // Only a generation that ever held elements can be addressed by a
            // published view that dereferences: a view over an empty
            // generation has count 0 everywhere and every bounds check on it
            // fails before any pointer is chased. So empty generations free
            // immediately even under a sink.
            retirementSink?(storage)
        }
        storage = grownStorage
    }
}
