#if canImport(Darwin)
import Darwin
#endif

/// A stack-headroom guard for the recursive demangling engines.
///
/// The engines used to bound recursion by counting frames — 768 for the
/// printer, 1024 for the remangler and the type decoder — mirroring
/// `NodePrinter::MaxDepth` / `Remangler::MaxDepth` / `TypeDecoder::MaxDepth` in
/// the C++ implementation. A frame count is only a proxy for what actually runs
/// out, which is stack *bytes*, and the two are not proportional:
///
/// - A debug build's frames are an order of magnitude larger than a release
///   build's. Measured on this package, printing a nested-`Optional` symbol
///   overflowed an 8MB stack at roughly 375 nesting levels in debug, while the
///   768-frame limit does not trigger until roughly 384 levels — so a debug
///   build crashes *before* the guard that exists to prevent it.
/// - The printer is generic over `DemanglingNode`, so it specializes once for
///   `Node` (a class reference) and once for `NodeReference` (a 16-byte value).
///   The two specializations do not have the same frame size, and one constant
///   cannot be correct for both.
/// - Calibrated for release on a large stack, the limit rejects deeply nested
///   but perfectly legitimate generic types: a `some View` body whose underlying
///   type nests more than ~384 levels prints as `<<too complex>>` even though
///   there is megabytes of stack left.
///
/// `StackBudget` measures the real resource instead. It compares the stack
/// pointer against a floor derived from the running thread's stack bounds, so a
/// single guard adapts to the build configuration, the specialization and the
/// thread it happens to run on.
///
/// ### Cost
///
/// The probe runs on every level. Sampling it — every N levels, sized against
/// an assumed per-level footprint — was tried first and is not safe: the
/// assumption has to hold for the largest frame any engine produces in any
/// build configuration, and when it does not, the walk crosses the whole
/// reserve between two probes and the process dies anyway. Guessing frame sizes
/// is the mistake the frame-count limits made; this type exists to stop making
/// it.
///
/// The read itself lives in an `@inline(never)` helper, so taking the address
/// of a local does not force a stack-protector prologue into the caller — the
/// hot recursive functions are unaffected and pay one call.
struct StackBudget: Sendable {
    /// Stack kept in reserve below the floor for the non-recursive work that
    /// still has to run while the recursion unwinds, and for the frames of any
    /// leaf helper that does not itself probe.
    private static let preferredReservedBytes: UInt = 1 << 20 // 1MB

    /// Backstop against a node graph that is cyclic rather than merely shared.
    /// A cycle keeps the recursion at a bounded depth while growing the output
    /// without end, so the stack floor alone would never stop it. Set far above
    /// any depth a real symbol can reach.
    ///
    /// Note this bounds the *recursive* engines only. The iterative helpers
    /// (`hashForNode`, `deepEquals`, `Node.==` / `hash(into:)`,
    /// `internTreeUnsafe`, `internTree`, `materializeNode`,
    /// `structurallyEquals`, `structuralHash`) grow a work list instead of a
    /// stack and consult no limit; a genuinely cyclic graph would exhaust
    /// memory there. Nothing in this library produces one — the demangler emits
    /// DAGs, never cycles — but a hand-built `Node` graph could.
    static let absoluteDepthLimit = 1_000_000

    /// Address the stack must not grow past, or `0` when this budget has no
    /// stack measurement available and falls back to counting frames.
    private let floorAddress: UInt

    /// Frame count used in place of a stack measurement when `floorAddress` is
    /// `0`. Each engine passes the limit it used before this type existed, so a
    /// platform without stack introspection keeps exactly its old behaviour
    /// rather than losing its guard.
    private let fallbackDepthLimit: Int

    private init(floorAddress: UInt, fallbackDepthLimit: Int) {
        self.floorAddress = floorAddress
        self.fallbackDepthLimit = fallbackDepthLimit
    }

    /// A budget with no stack measurement, bounded only by `fallbackDepthLimit`.
    ///
    /// Used on platforms without stack introspection and when the running
    /// thread's bounds cannot be read.
    static func countingFrames(upTo fallbackDepthLimit: Int) -> StackBudget {
        StackBudget(floorAddress: 0, fallbackDepthLimit: fallbackDepthLimit)
    }

    /// A budget derived from the calling thread's stack bounds.
    ///
    /// Call this at the top of a recursive operation, on the thread that will
    /// run it — the bounds are per-thread, so a budget captured on one thread is
    /// meaningless on another.
    ///
    /// - Parameter fallbackDepthLimit: frame count to fall back to where the
    ///   thread's stack bounds cannot be read. Pass the limit the caller used
    ///   before this type existed.
    static func forCurrentThread(fallbackDepthLimit: Int) -> StackBudget {
        #if canImport(Darwin)
        let stackTopAddress = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        let stackSize = UInt(pthread_get_stacksize_np(pthread_self()))
        guard stackSize > 0, stackTopAddress > stackSize else {
            return .countingFrames(upTo: fallbackDepthLimit)
        }
        let stackBaseAddress = stackTopAddress - stackSize

        // A flat 1MB reserve would swallow a small stack whole, so it scales
        // with the stack; the 32KB floor keeps enough room for the unwinding
        // work even on a stack so small that an eighth of it is less than that.
        let reservedBytes = min(preferredReservedBytes, max(stackSize / 8, 32 * 1024))
        return StackBudget(floorAddress: stackBaseAddress + reservedBytes, fallbackDepthLimit: fallbackDepthLimit)
        #else
        return .countingFrames(upTo: fallbackDepthLimit)
        #endif
    }

    /// Whether the recursion may descend one more level.
    ///
    /// `depth` is the caller's own recursion depth: it selects when a real
    /// probe happens and provides the cycle backstop.
    ///
    /// Deliberately *not* sticky. A path that runs out of stack bails, and by
    /// the time the recursion has unwound back to a shallower sibling the stack
    /// is free again, so that sibling completes normally — the same
    /// one-path-degrades shape the frame-count guard had. Statelessness also
    /// keeps this callable from the type decoder's non-mutating walk.
    @inline(__always)
    func hasHeadroom(atDepth depth: Int) -> Bool {
        guard floorAddress != 0 else {
            // No stack measurement on this platform: behave exactly as the
            // frame-count guard this type replaced.
            return depth <= fallbackDepthLimit
        }
        if depth > Self.absoluteDepthLimit {
            return false
        }
        return Self.currentStackPointerAddress() > floorAddress
    }

    /// Reads the stack pointer.
    ///
    /// Deliberately not inlined: taking the address of a local forces a
    /// stack-protector prologue into whatever function contains it, and the
    /// recursive engines cannot afford that on their hottest function.
    @inline(never)
    private static func currentStackPointerAddress() -> UInt {
        var stackProbe: UInt = 0
        return withUnsafeMutablePointer(to: &stackProbe) { UInt(bitPattern: $0) }
    }
}
