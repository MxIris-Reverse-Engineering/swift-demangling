import Foundation
import Testing
@_spi(Internals) @testable import Demangling

/// Guards the worker pool behind ``StackSafeExecutor``.
///
/// The pool replaced a create-and-join-a-`Thread`-per-call design that cost
/// roughly 41µs per demangle off the main thread. The properties tested here
/// are the ones a pool makes easy to get wrong: work must never be dropped, the
/// thread count must stay bounded, and a worker must never wait on the pool it
/// is running on.
@Suite("LargeStackThreadPool", .serialized)
struct LargeStackThreadPoolTests {
    static let cooperativeWorkerStackSize = 512 * 1024

    static func runOnThread(stackSize: Int, _ body: @escaping @Sendable () -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            semaphore.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        semaphore.wait()
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Every submission must run exactly once. A pool that lets a worker retire
    /// while work is queued — the shape an idle timeout produces — silently
    /// abandons items and blocks their callers forever.
    @Test func everySubmissionRunsExactlyOnce() {
        let completionCounter = Counter()
        let submissionCount = 2000

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            for _ in 0 ..< submissionCount {
                _ = StackSafeExecutor.execute { () -> String in
                    completionCounter.increment()
                    return ""
                }
            }
        }

        #expect(completionCounter.current == submissionCount)
    }

    /// The same under concurrency, where submissions and worker start-up race.
    @Test func concurrentSubmissionsAllComplete() async {
        let completionCounter = Counter()
        let taskCount = 200

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< taskCount {
                group.addTask {
                    _ = await StackSafeExecutor.executeAsync {
                        completionCounter.increment()
                    }
                }
            }
        }

        #expect(completionCounter.current == taskCount)
    }

    /// A burst must not spawn a worker per item. The predecessor created one
    /// 64MB-stack `Thread` per concurrent call with no ceiling at all.
    ///
    /// The ceiling asserted here is the burst limit rather than the
    /// steady-state one: the pool is a process-wide singleton whose workers
    /// never retire, and other suites submitting concurrently may legitimately
    /// have taken it above its steady-state limit. What must hold under any
    /// interleaving is that a bound exists at all.
    @Test func workerCountStaysBoundedUnderBurst() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 500 {
                group.addTask {
                    await StackSafeExecutor.executeAsync {
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                }
            }
        }

        let workerCount = LargeStackThreadPool.shared.currentWorkerCount
        let burstLimit = LargeStackThreadPool.shared.burstWorkerLimitForTesting
        #expect(workerCount <= burstLimit, "pool grew to \(workerCount) workers, ceiling is \(burstLimit)")
        #expect(workerCount > 0, "a 500-item burst should have created at least one worker")
    }

    /// Printing re-enters demangling for nested mangled names. A worker has
    /// megabytes to spare at any realistic nesting point, so the remaining-
    /// stack probe keeps the nested call inline — no second hop, and no
    /// waiting on the pool the worker itself is running on.
    @Test func nestedCallsFromAWorkerRunInline() {
        final class ThreadIdentifierBox: @unchecked Sendable {
            var outerThread: mach_port_t = 0
            var innerThread: mach_port_t = 0
        }
        let box = ThreadIdentifierBox()

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            _ = StackSafeExecutor.execute { () -> String in
                box.outerThread = pthread_mach_thread_np(pthread_self())
                return StackSafeExecutor.execute { () -> String in
                    box.innerThread = pthread_mach_thread_np(pthread_self())
                    return ""
                }
            }
        }

        #expect(box.outerThread != 0)
        #expect(box.innerThread == box.outerThread, "a nested call must not hop to another worker")
    }

    /// `withLargeStack` is the batch-boundary entry: one hop for the whole
    /// batch, everything inside running inline.
    @Test func withLargeStackHopsOnceForTheWholeBatch() throws {
        final class ThreadIdentifierBox: @unchecked Sendable {
            var callerThread: mach_port_t = 0
            var observedThreads: Set<mach_port_t> = []
        }
        let box = ThreadIdentifierBox()

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            box.callerThread = pthread_mach_thread_np(pthread_self())
            StackSafeExecutor.withLargeStack {
                for _ in 0 ..< 50 {
                    _ = StackSafeExecutor.execute { () -> String in
                        box.observedThreads.insert(pthread_mach_thread_np(pthread_self()))
                        return ""
                    }
                }
            }
        }

        #expect(box.observedThreads.count == 1, "the batch should run on a single worker")
        #expect(box.observedThreads.first != box.callerThread)
    }

    /// A thread that already has plenty of stack runs inline — no hop, no
    /// semaphore wait. This is what keeps `po node` usable in LLDB (which only
    /// runs the current thread, so a mandatory hop deadlocks expression
    /// evaluation) and the main thread free of priority inversion. An earlier
    /// design compared against the worker's own stack size, which no ordinary
    /// thread clears, and made every main-thread call hop.
    @Test func executionStaysInlineOnALargeCallerStack() {
        final class ObservationBox: @unchecked Sendable {
            var executeThread: mach_port_t = 0
            var withLargeStackThread: mach_port_t = 0
            var callerThread: mach_port_t = 0
        }
        let box = ObservationBox()

        Self.runOnThread(stackSize: 8 * 1024 * 1024) {
            box.callerThread = pthread_mach_thread_np(pthread_self())
            _ = StackSafeExecutor.execute { () -> String in
                box.executeThread = pthread_mach_thread_np(pthread_self())
                return ""
            }
            StackSafeExecutor.withLargeStack {
                box.withLargeStackThread = pthread_mach_thread_np(pthread_self())
            }
        }

        #expect(box.executeThread == box.callerThread, "a caller with stack to spare must not hop")
        #expect(box.withLargeStackThread == box.callerThread, "withLargeStack is satisfied by the caller's own large stack")
    }

    /// The complement: a small-stack caller must hop, and to a thread with the
    /// full worker stack.
    @Test func executionHopsToALargeStackFromASmallCallerStack() {
        final class ObservationBox: @unchecked Sendable {
            var callerThread: mach_port_t = 0
            var bodyThread: mach_port_t = 0
            var bodyStackSize = 0
        }
        let box = ObservationBox()

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize) {
            box.callerThread = pthread_mach_thread_np(pthread_self())
            _ = StackSafeExecutor.execute { () -> String in
                box.bodyThread = pthread_mach_thread_np(pthread_self())
                box.bodyStackSize = pthread_get_stacksize_np(pthread_self())
                return ""
            }
        }

        #expect(box.bodyThread != box.callerThread, "a 512KB caller must hop")
        #expect(box.bodyStackSize >= StackSafeExecutor.largeStackThreadSize)
    }

    /// When the OS refuses to create any worker, no submitter may hang.
    ///
    /// The dangerous interleaving: two submitters both reserve a worker slot
    /// and both fail to spawn. The first to roll back still sees the other's
    /// phantom reservation, concludes a worker survives, queues its item and
    /// blocks on it. Only the second roll-back can observe the true zero — so
    /// it must drain the queue on its own thread before refusing, or the first
    /// submitter waits forever on a pool that cannot act.
    @Test func spawnFailureNeverStrandsASubmission() {
        let pool = LargeStackThreadPool()
        pool.simulatesSpawnFailureForTesting = true
        // Holds every submitter in the reserved-but-not-yet-failed state at
        // once, so the roll-backs genuinely race instead of serializing.
        pool.simulatedSpawnFailureDelayForTesting = 0.25

        let submitterCount = 8
        let completionCounter = Counter()
        let allSubmittersFinished = DispatchSemaphore(value: 0)

        for _ in 0 ..< submitterCount {
            Thread.detachNewThread {
                let itemRan = DispatchSemaphore(value: 0)
                let accepted = pool.trySubmit(allowingOverflow: true) {
                    completionCounter.increment()
                    itemRan.signal()
                }
                if accepted {
                    // Pre-fix, this wait is where the first-to-roll-back
                    // submitter hung forever.
                    let outcome = itemRan.wait(timeout: .now() + 30)
                    #expect(outcome == .success, "an accepted item must run even when no worker exists")
                } else {
                    completionCounter.increment()
                }
                allSubmittersFinished.signal()
            }
        }

        for _ in 0 ..< submitterCount {
            let outcome = allSubmittersFinished.wait(timeout: .now() + 60)
            #expect(outcome == .success, "a submitter hung against a pool with no workers")
        }
        #expect(completionCounter.current == submitterCount, "every item must run exactly once, somewhere")
        #expect(pool.currentWorkerCount == 0, "simulated spawn failure must leave no phantom workers")
    }
}
