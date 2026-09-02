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

    static func runOnThread(
        stackSize: Int,
        qualityOfService: QualityOfService? = nil,
        _ body: @escaping @Sendable () -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            semaphore.signal()
        }
        thread.stackSize = stackSize
        if let qualityOfService {
            thread.qualityOfService = qualityOfService
        }
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
    /// have taken it above its steady-state limit — from more than one QOS
    /// class, each of which is its own bounded sub-pool, which is why the
    /// ceiling is the per-class limit times the class count. What must hold
    /// under any interleaving is that a bound exists at all.
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

    /// Work must run at the QOS class of the thread that submitted it.
    ///
    /// Neither wait in the hop can inherit priority — the submitter blocks on
    /// a semaphore, which donates nothing, and the worker parks on a condition
    /// variable, which cannot know its future signaller — so the pool keeps
    /// the ranking right by construction: workers are partitioned by class,
    /// created at the submitter's class and never re-ranked, and a submission
    /// only reaches workers of its own class (the dedicated fallback thread is
    /// created at the caller's class too). Before this, workers ran at a fixed
    /// user-initiated class: a user-interactive caller waited on a
    /// lower-priority thread, and the idle park outranked utility submitters —
    /// the priority inversion the Thread Performance Checker reported at the
    /// condition wait.
    @Test func workRunsAtTheSubmittersQualityOfServiceClass() {
        final class ObservationBox: @unchecked Sendable {
            var utilityRunClass = QOS_CLASS_UNSPECIFIED
            var userInteractiveRunClass = QOS_CLASS_UNSPECIFIED
        }
        let box = ObservationBox()

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize, qualityOfService: .utility) {
            _ = StackSafeExecutor.execute { () -> String in
                box.utilityRunClass = qos_class_self()
                return ""
            }
        }
        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize, qualityOfService: .userInteractive) {
            _ = StackSafeExecutor.execute { () -> String in
                box.userInteractiveRunClass = qos_class_self()
                return ""
            }
        }

        #expect(box.utilityRunClass == QOS_CLASS_UTILITY)
        #expect(box.userInteractiveRunClass == QOS_CLASS_USER_INTERACTIVE)
    }

    /// A parked worker keeps its class; it never drops to background.
    ///
    /// The class-agnostic design that preceded the partition parked every
    /// idle worker at `QOS_CLASS_BACKGROUND` so the park could never outrank
    /// a future signaller, and re-ranked on dequeue. Correct, and three to
    /// four times slower on every demangle-heavy path: each hop then woke a
    /// *background* thread (efficiency-core scheduling, throttling) and paid
    /// two QOS syscalls, hundreds of thousands of times per indexed
    /// framework. With one pool per class the park needs no demotion — a
    /// worker's signallers are all of its own class — so the class must hold
    /// steady through the whole idle period. Pre-fix, the first sample after
    /// the item completes already reads background.
    ///
    /// A private pool keeps other suites' submissions from re-occupying the
    /// worker mid-sample. The class is read through `pthread_get_qos_class_np`
    /// on the worker's own thread handle, which stays valid because workers
    /// never retire.
    @Test func idleWorkerKeepsItsClassInsteadOfParkingAtBackground() {
        final class WorkerBox: @unchecked Sendable {
            var workerThread: pthread_t?
        }
        let pool = LargeStackThreadPool()
        let box = WorkerBox()
        let itemFinished = DispatchSemaphore(value: 0)

        Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize, qualityOfService: .userInitiated) {
            let accepted = pool.trySubmit(allowingOverflow: true) {
                box.workerThread = pthread_self()
                itemFinished.signal()
            }
            #expect(accepted)
            #expect(itemFinished.wait(timeout: .now() + 10) == .success)
        }

        guard let workerThread = box.workerThread else {
            Issue.record("the item never ran on a pool worker")
            return
        }
        var observedClasses: [qos_class_t] = []
        for _ in 0 ..< 40 {
            var observedClass = QOS_CLASS_UNSPECIFIED
            _ = pthread_get_qos_class_np(workerThread, &observedClass, nil)
            observedClasses.append(observedClass)
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(!observedClasses.contains(QOS_CLASS_BACKGROUND), "an idle worker must not park at background; observed \(observedClasses.map(\.rawValue))")
        #expect(observedClasses.last == QOS_CLASS_USER_INITIATED, "an idle worker keeps its submitters' class")
    }

    /// Submissions of different classes are served by different workers, one
    /// per class — the partition itself. Pre-fix, one class-agnostic pool
    /// handed both items to the same worker and re-ranked it between them.
    @Test func submissionsOfDifferentClassesRunOnWorkersOfTheirOwnClass() {
        final class ObservationBox: @unchecked Sendable {
            var utilityWorker: mach_port_t = 0
            var utilityRunClass = QOS_CLASS_UNSPECIFIED
            var userInteractiveWorker: mach_port_t = 0
            var userInteractiveRunClass = QOS_CLASS_UNSPECIFIED
        }
        let pool = LargeStackThreadPool()
        let box = ObservationBox()

        func submit(at qualityOfService: QualityOfService, record: @escaping @Sendable (mach_port_t, qos_class_t) -> Void) {
            Self.runOnThread(stackSize: Self.cooperativeWorkerStackSize, qualityOfService: qualityOfService) {
                let itemFinished = DispatchSemaphore(value: 0)
                let accepted = pool.trySubmit(allowingOverflow: true) {
                    record(pthread_mach_thread_np(pthread_self()), qos_class_self())
                    itemFinished.signal()
                }
                #expect(accepted)
                #expect(itemFinished.wait(timeout: .now() + 10) == .success)
            }
        }

        submit(at: .utility) { thread, runClass in
            box.utilityWorker = thread
            box.utilityRunClass = runClass
        }
        submit(at: .userInteractive) { thread, runClass in
            box.userInteractiveWorker = thread
            box.userInteractiveRunClass = runClass
        }

        #expect(box.utilityWorker != 0)
        #expect(box.userInteractiveWorker != 0)
        #expect(box.utilityWorker != box.userInteractiveWorker, "each class must be served by its own worker")
        #expect(box.utilityRunClass == QOS_CLASS_UTILITY)
        #expect(box.userInteractiveRunClass == QOS_CLASS_USER_INTERACTIVE)
        #expect(pool.currentWorkerCount == 2)
        #expect(pool.currentWorkerCount(for: QOS_CLASS_UTILITY) == 1)
        #expect(pool.currentWorkerCount(for: QOS_CLASS_USER_INTERACTIVE) == 1)
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
        let pool = LargeStackThreadPool(
            simulatesSpawnFailureForTesting: true,
            // Holds every submitter in the reserved-but-not-yet-failed state
            // at once, so the roll-backs genuinely race instead of
            // serializing.
            simulatedSpawnFailureDelayForTesting: 0.25
        )

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
