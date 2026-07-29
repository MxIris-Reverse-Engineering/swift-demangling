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

    /// Printing re-enters demangling for nested mangled names. On a capped pool
    /// a worker that submitted back into it would wait for a slot that only it
    /// could free. Work started on a worker has to run inline instead.
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

    /// `withLargeStack` is a request, not a hint. The "does this thread already
    /// have enough stack" short-circuit made it a no-op on the main thread's
    /// 8MB, so wrapping a batch there bought nothing at all — the one case
    /// where a caller most obviously reaches for it.
    @Test func withLargeStackReachesAWorkerEvenFromALargeCallerStack() {
        final class ObservationBox: @unchecked Sendable {
            var ranOnPoolWorker = false
            var callerThread: mach_port_t = 0
            var bodyThread: mach_port_t = 0
        }
        let box = ObservationBox()

        Self.runOnThread(stackSize: 8 * 1024 * 1024) {
            box.callerThread = pthread_mach_thread_np(pthread_self())
            StackSafeExecutor.withLargeStack {
                box.ranOnPoolWorker = LargeStackThreadPool.isRunningOnPoolWorker
                box.bodyThread = pthread_mach_thread_np(pthread_self())
            }
        }

        #expect(box.ranOnPoolWorker, "withLargeStack must run its body on a pool worker")
        #expect(box.bodyThread != box.callerThread)
    }
}
