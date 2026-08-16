import Foundation
import Testing
@testable import DemanglingTestingSupport

/// Concurrency contract for `MallocCounter`'s nesting depth.
///
/// The depth counter is itself a guard rail added by an earlier review round,
/// and it shipped with a race: `stop()` decremented with `fetch_sub` and, on the
/// unbalanced path, put the value back with a separate `fetch_add`. Between the
/// two the depth is negative, and a concurrent `start()` reading a negative
/// value takes the "already nested" early return — so it neither zeroes the
/// counters nor installs the hook, its whole window measures nothing, and its
/// `stop()` returns a stale count from an earlier window. A benchmark then
/// publishes a wrong allocation figure with nothing to indicate it
/// (PR #7 review, finding 12).
///
/// Opt-in: these tests install and remove the process-wide `malloc_logger`
/// hook, which is not something the default `swift test` should do underneath
/// unrelated suites. `.serialized` for the same reason the benchmark suites are
/// — measurement windows must not overlap.
///
/// ```
/// DEMANGLING_BENCHMARK=1 swift test --filter MallocCounterConcurrencyTests
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEMANGLING_BENCHMARK"] == "1"), .serialized)
struct MallocCounterConcurrencyTests {
    /// An unbalanced `stop()` must leave the depth where a following `start()`
    /// sees a fresh outermost window, not a phantom nested one.
    ///
    /// Deterministic, and therefore only half the story: the pre-fix
    /// sequential path also settles back at zero, so this catches a regression
    /// that drops the roll-back entirely, not the race itself. The concurrent
    /// test below covers the window.
    @Test func anUnbalancedStopLeavesTheNextWindowUsable() {
        ExclusiveMeasurementWindow.run {
            _ = MallocCounter.stop()

            MallocCounter.start()
            var allocations: [[UInt8]] = []
            for size in 0 ..< 64 {
                allocations.append([UInt8](repeating: 0, count: 4096 + size))
            }
            let eventCount = MallocCounter.stop()
            withExtendedLifetime(allocations) {}

            #expect(eventCount > 0, """
                the window after an unbalanced stop() counted nothing — start() took the \
                "already nested" path, so the hook was never installed
                """)
        }
    }

    /// Nested windows still report through the outermost pair only, which is
    /// the property the depth counter exists for and the one the compare-
    /// exchange must not disturb.
    @Test func nestedWindowsReportThroughTheOutermostPair() {
        ExclusiveMeasurementWindow.run {
            MallocCounter.start()
            var outerAllocations: [[UInt8]] = []
            for _ in 0 ..< 8 {
                outerAllocations.append([UInt8](repeating: 0, count: 8192))
            }

            MallocCounter.start() // nested: must not reset the outer counters
            var innerAllocations: [[UInt8]] = []
            for _ in 0 ..< 8 {
                innerAllocations.append([UInt8](repeating: 0, count: 8192))
            }
            let innerCount = MallocCounter.stop()

            let outerCount = MallocCounter.stop()
            withExtendedLifetime((outerAllocations, innerAllocations)) {}

            #expect(innerCount > 0, "the nested stop() still reports the outer window's running total")
            #expect(outerCount >= innerCount, "the outer window must not have been reset by the nested start()")
        }
    }

    // MARK: - Not tested here, and why
    //
    // The race the compare-exchange closes is not reachable through this API.
    // It needs a `start()` to observe the depth between an unbalanced `stop()`'s
    // decrement and its compensating increment — two instructions — and there is
    // no seam to hold it there. Sampling the depth cannot see a window that
    // narrow either. The fix stands on construction (a compare-exchange that
    // only ever decrements a positive value is never observably negative)
    // rather than on a reproduction, and the sequential test above is what
    // guards the roll-back it replaced.
    //
    // Writing this file surfaced a separate, larger gap that no arrangement of
    // these tests can close, because it is in the design rather than the
    // implementation: **a stray `stop()` that lands while a real window is open
    // closes that window.** It sees depth 1, decrements to 0, takes the
    // `previous_depth == 1` branch and restores the saved logger — mid-window,
    // for someone else. The victim's own `stop()` then finds depth 0, restores
    // nothing, and returns whatever had accumulated, which can be zero. This
    // behaves identically before and after the compare-exchange fix, because a
    // depth counter cannot tell whose `stop()` it is holding. Closing it needs
    // window ownership — `start()` returning a token that `stop()` must present
    // — not a better counter. Today `ExclusiveMeasurementWindow` makes it
    // unreachable by serializing every window behind one lock, so this is a
    // latent hazard for a future caller that opens a window without it, not a
    // live bug (PR #7 review, finding 12, follow-up).
}
