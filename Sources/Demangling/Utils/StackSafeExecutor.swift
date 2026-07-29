import Foundation

/// Carries a value across the worker boundary where the compiler cannot see
/// that the handoff is strict: the submitting thread blocks until the worker
/// has finished with it, so the value is never reachable from two threads at
/// once.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Runs the recursive demangling engines on a stack large enough for real
/// symbols.
///
/// On Darwin every thread except the main one gets a 512KB stack — Swift
/// Concurrency cooperative workers and libdispatch workers alike — which is
/// enough for a few dozen levels of generic nesting. ``StackBudget`` makes
/// running out of it a clean `<<too complex>>` / `.tooComplex` instead of a
/// crash; this type is what makes running out of it *rare*, by moving the work
/// onto a pooled worker with a large stack.
///
/// This mirrors what the Swift compiler does. `lib/Demangling` contains no
/// stack handling at all; its callers arrange a big stack once at a task
/// boundary — SourceKit dispatches semantic requests onto an 8MB
/// `llvm::thread` (`Concurrency-libdispatch.cpp`), IRGen creates its worker
/// threads with `pthread_attr_setstacksize(8MB)` — and the engines carry depth
/// limits. The difference here is granularity: a library cannot hoist the
/// decision to the caller's task boundary, so ``withLargeStack(_:)`` exists for
/// callers who *can*.
///
/// ### What is guaranteed
///
/// Every entry point runs its work with at least ``largeStackThreadSize`` of
/// stack below it, *whatever thread it was called from*, unless the pool cannot
/// take the work at all (see ``LargeStackThreadPool``), in which case it runs
/// inline and ``StackBudget`` keeps it from crashing.
///
/// The earlier design compared the caller's remaining stack against a 2MB
/// threshold and ran inline above it. That made the result depend on the
/// calling thread: the main thread's 8MB always cleared the bar and kept its own
/// much lower ceiling, while a 512KB cooperative worker was moved to a 64MB
/// worker and printed the same tree in full. `node.print()` returning
/// `<<too complex>>` on the main thread and the complete type from inside a
/// `Task` is not something a caller can reason about, so the comparison is now
/// against a worker's own stack size — nothing short of that runs inline.
///
/// SPI note: exposed as `@_spi(Internals)` so deep consumers driving
/// ``DemanglingPrinter`` directly get the same treatment as the library's own
/// entry points.
@_spi(Internals)
public enum StackSafeExecutor {
    #if canImport(Darwin)
    /// Stack size for the pooled workers.
    ///
    /// A thread stack is a *virtual* reservation: only the pages the thread
    /// actually writes to are backed by physical memory, so raising this costs
    /// address space (abundant on 64-bit) rather than resident memory. Sized to
    /// hold the deepest generic nesting a real symbol reaches even in an
    /// unoptimized build, where one nesting level of the printer costs roughly
    /// 20KB: 8MB ran out at about 400 levels, 64MB carries past 3000.
    static let largeStackThreadSize = 64 * 1024 * 1024 // 64MB
    #endif

    /// Runs `body` on a large-stack worker and returns its result.
    ///
    /// Use this at a batch boundary — indexing every symbol of a binary, say —
    /// so the whole batch pays for one thread hop instead of one per call.
    /// Every nested demangle / print / remangle inside `body` then sees a stack
    /// with room to spare and runs inline.
    public static func withLargeStack<Success: Sendable, Failure: Error>(
        _ body: @escaping @Sendable () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        try execute(body)
    }

    /// Executes the given block on a stack large enough for real symbols,
    /// moving it to a pooled worker unless the current thread already qualifies.
    public static func execute(_ block: @escaping @Sendable () -> String) -> String {
        #if canImport(Darwin)
        if currentThreadAlreadyHasAWorkerSizedStack {
            return block()
        }
        return runOnPoolWorker(block)
        #else
        return block()
        #endif
    }

    /// Throwing, generic variant of ``execute(_:)``, propagating typed errors
    /// across the thread boundary.
    public static func execute<Success: Sendable, Failure: Error>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        #if canImport(Darwin)
        if currentThreadAlreadyHasAWorkerSizedStack {
            return try block()
        }
        return try runOnPoolWorker(block)
        #else
        return try block()
        #endif
    }

    /// ``execute(_:)`` for callers whose values carry no `Sendable`
    /// conformance.
    ///
    /// `TypeBuilder` and the types it builds are deliberately unconstrained, so
    /// the type decoder cannot use the checked entry point. The call is still a
    /// strict handoff — the calling thread blocks for its whole duration and no
    /// other thread can reach the values — which is precisely the shape the
    /// checking cannot express.
    static func executeWithUncheckedSendability<Success, Failure: Error>(
        _ block: @escaping () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        #if canImport(Darwin)
        if currentThreadAlreadyHasAWorkerSizedStack {
            return try block()
        }
        // Boxed as a non-throwing closure returning a `Result`: a typed-throws
        // *function type* stored in a generic container needs a macOS 15
        // runtime, and this library deploys to 10.15.
        let blockBox = UncheckedSendableBox(value: { () -> Result<Success, Failure> in
            do throws(Failure) {
                return .success(try block())
            } catch {
                return .failure(error)
            }
        })
        nonisolated(unsafe) var outcome: Result<Success, Failure>!
        let semaphore = DispatchSemaphore(value: 0)
        let accepted = LargeStackThreadPool.shared.trySubmit(allowingOverflow: true) {
            outcome = blockBox.value()
            semaphore.signal()
        }
        guard accepted else {
            return try block()
        }
        semaphore.wait()
        return try outcome.get()
        #else
        return try block()
        #endif
    }

    /// Async variant that suspends the calling task instead of blocking a
    /// cooperative worker on an OS-level semaphore.
    public static func executeAsync<Success: Sendable, Failure: Error & Sendable>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) async throws(Failure) -> Success {
        #if canImport(Darwin)
        if currentThreadAlreadyHasAWorkerSizedStack {
            return try block()
        }
        let outcome: Result<Success, Failure>? = await withCheckedContinuation { continuation in
            // A suspended task occupies no thread, so this submission cannot be
            // part of a wait cycle and does not get the overflow allowance that
            // keeps blocked callers from deadlocking each other.
            let accepted = LargeStackThreadPool.shared.trySubmit(allowingOverflow: false) {
                do throws(Failure) {
                    continuation.resume(returning: .success(try block()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            if !accepted {
                continuation.resume(returning: nil)
            }
        }
        guard let outcome else {
            // The pool could not take it. Running inline keeps the caller
            // making progress; `StackBudget` bounds it to the stack it has.
            return try block()
        }
        return try outcome.get()
        #else
        return try block()
        #endif
    }

    #if canImport(Darwin)
    /// Whether the current thread already has at least as much stack below it
    /// as a pool worker would provide, making a hop pointless.
    ///
    /// A worker is on its own stack by construction, and checking the
    /// thread-local marker first also keeps nested calls off the two `pthread`
    /// queries and the probe.
    private static var currentThreadAlreadyHasAWorkerSizedStack: Bool {
        if LargeStackThreadPool.isRunningOnPoolWorker {
            return true
        }
        let stackTopAddress = pthread_get_stackaddr_np(pthread_self())
        let stackSize = pthread_get_stacksize_np(pthread_self())
        let stackBaseAddress = stackTopAddress - stackSize
        var stackProbe = 0
        let currentAddress = withUnsafeMutablePointer(to: &stackProbe) { Int(bitPattern: $0) }
        let remainingStackSpace = currentAddress - Int(bitPattern: stackBaseAddress)
        return remainingStackSpace >= largeStackThreadSize
    }

    private static func runOnPoolWorker<Success: Sendable>(_ block: @escaping @Sendable () -> Success) -> Success {
        nonisolated(unsafe) var result: Success!
        let semaphore = DispatchSemaphore(value: 0)
        let accepted = LargeStackThreadPool.shared.trySubmit(allowingOverflow: true) {
            result = block()
            semaphore.signal()
        }
        guard accepted else {
            return block()
        }
        semaphore.wait()
        return result
    }

    private static func runOnPoolWorker<Success: Sendable, Failure: Error>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        nonisolated(unsafe) var outcome: Result<Success, Failure>!
        let semaphore = DispatchSemaphore(value: 0)
        let accepted = LargeStackThreadPool.shared.trySubmit(allowingOverflow: true) {
            do throws(Failure) {
                outcome = .success(try block())
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        guard accepted else {
            return try block()
        }
        semaphore.wait()
        return try outcome.get()
    }
    #endif
}

#if canImport(Darwin)
/// A bounded pool of long-lived large-stack workers.
///
/// Creating and joining a thread per call costs roughly 41µs measured on this
/// package — five to eighteen times the work itself for a typical symbol, and
/// seconds of pure overhead when indexing a framework. Workers are therefore
/// created on demand and kept.
///
/// Four properties are load-bearing and easy to lose:
///
/// - **Workers never retire.** An idle-timeout retirement has a window between
///   the timeout firing and the worker reacquiring the lock in which a
///   submission counts it as available, creates no replacement, and signals
///   nobody — the work item is then never run and the caller blocks forever.
///   Keeping workers alive removes the window rather than trying to close it.
///   Idle workers cost a kernel thread structure each; their 64MB stacks are
///   untouched address space.
/// - **A worker is created before its work is queued, and creation is
///   checked.** `Thread.start()` reports nothing when the OS refuses to make a
///   thread, so the previous design incremented the worker count, failed to
///   start anything, and left the item queued with nobody to run it: the caller
///   blocked forever, and because the phantom worker still counted, every later
///   submission saw a full pool and never created a replacement — one failure
///   poisoned a process-wide singleton permanently. `pthread_create` returns an
///   error code, so the slot is released and the submission refused instead.
/// - **Submission can be refused.** A refused item runs on the caller's own
///   thread. That is what makes every failure mode above degrade rather than
///   hang, and ``StackBudget`` is what makes running inline safe.
/// - **A worker never waits on the pool.** Printing re-enters demangling for
///   nested mangled names, so work submitted from a worker would block on a
///   capped pool. ``isRunningOnPoolWorker`` makes those calls run inline
///   instead — they are already on a large stack, which is the whole point.
///
/// ### The overflow allowance
///
/// The thread-local marker only catches a worker submitting *directly*. A
/// worker that fans out to other threads — `concurrentPerform` or a task group
/// inside a ``StackSafeExecutor/withLargeStack(_:)`` batch — produces
/// submissions from threads the pool cannot recognise, and with a hard cap the
/// outer items wait for inner items that are queued behind them.
///
/// Blocking submissions therefore get an allowance above the steady-state
/// limit: a caller that is about to block is evidence of a thread waiting, and
/// growing for it is what breaks the cycle. Asynchronous submissions occupy no
/// thread while suspended, cannot be part of such a cycle, and stay under the
/// steady-state limit so a burst of them cannot inflate the pool.
///
/// Nesting deeper than ``burstWorkerLimit`` simultaneously blocked callers is
/// still possible in principle; those submissions queue as before.
final class LargeStackThreadPool: @unchecked Sendable {
    static let shared = LargeStackThreadPool()

    /// Thread-local marker key, or `nil` if the platform refused to allocate
    /// one.
    ///
    /// `Thread.current.threadDictionary` would be the obvious place for this,
    /// but reading it materializes an `NSThread` wrapper and lazily allocates —
    /// and permanently retains — an `NSMutableDictionary` on every thread that
    /// ever demangles. This check sits on every entry point, so it has to be a
    /// bare `pthread_getspecific`.
    ///
    /// Without the marker the pool cannot tell a worker from any other thread,
    /// and a worker submitting back into a capped pool would deadlock. The pool
    /// disables itself instead: everything runs inline under ``StackBudget``,
    /// which is a depth ceiling, not a crash.
    private static let workerMarkerKey: pthread_key_t? = {
        var key = pthread_key_t()
        guard pthread_key_create(&key, nil) == 0 else { return nil }
        return key
    }()

    /// Whether the calling thread is one of this pool's workers.
    static var isRunningOnPoolWorker: Bool {
        guard let workerMarkerKey else { return false }
        return pthread_getspecific(workerMarkerKey) != nil
    }

    private static func markCurrentThreadAsPoolWorker() {
        guard let workerMarkerKey else { return }
        // Any non-null value marks the thread; the key has no destructor, so
        // nothing is ever dereferenced.
        pthread_setspecific(workerMarkerKey, UnsafeMutableRawPointer(bitPattern: 1))
    }

    /// Ceiling for demand-driven growth in steady state.
    private let steadyStateWorkerLimit = max(2, ProcessInfo.processInfo.activeProcessorCount)

    /// Ceiling including the allowance for blocking submissions.
    ///
    /// A fan-out inside a batch needs room for the outer items *and* the inner
    /// ones they wait on; both are bounded by the caller's own concurrency,
    /// which is in turn bounded by the core count. A few times the steady-state
    /// limit covers the nesting depths that occur in practice. Each worker
    /// reserves address space rather than memory, so the cost of the headroom
    /// is a kernel thread structure per worker.
    private let burstWorkerLimit = max(32, 4 * max(2, ProcessInfo.processInfo.activeProcessorCount))

    private let condition = NSCondition()
    private var pendingWorkItems: [@Sendable () -> Void] = []
    /// Index of the next item to run. Removing from the front of the array
    /// instead would memmove the whole queue while holding the lock.
    private var nextWorkItemIndex = 0
    private var idleWorkerCount = 0
    private var workerCount = 0

    /// Number of workers this pool has created. Exposed for tests, which need
    /// to assert on the pool's own ceiling rather than on a process-wide thread
    /// count that other suites also move.
    var currentWorkerCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return workerCount
    }

    /// The pool's hard ceiling. Tests assert against this rather than the
    /// steady-state limit: the pool is a process-wide singleton whose workers
    /// never retire, so a suite running concurrently may legitimately have
    /// taken it above steady state.
    var burstWorkerLimitForTesting: Int { burstWorkerLimit }

    /// Queues `workItem`, growing the pool if that is what it takes.
    ///
    /// - Parameter allowingOverflow: whether the caller will block until the
    ///   item runs. Blocking callers may grow the pool past its steady-state
    ///   limit; see the type's discussion.
    /// - Returns: `false` if the pool cannot run the item, in which case the
    ///   caller must run it itself. The item is never queued when this returns
    ///   `false`.
    func trySubmit(allowingOverflow: Bool, _ workItem: @escaping @Sendable () -> Void) -> Bool {
        guard Self.workerMarkerKey != nil else { return false }

        condition.lock()
        let queuedCount = pendingWorkItems.count - nextWorkItemIndex
        let workerLimit = allowingOverflow ? burstWorkerLimit : steadyStateWorkerLimit
        let needsAdditionalWorker = queuedCount + 1 > idleWorkerCount && workerCount < workerLimit
        if needsAdditionalWorker {
            workerCount += 1
        }
        condition.unlock()

        if needsAdditionalWorker, !spawnWorker() {
            condition.lock()
            workerCount -= 1
            let survivingWorkerCount = workerCount
            condition.unlock()
            // Nothing exists to drain the queue, so the item must not be
            // queued at all.
            if survivingWorkerCount == 0 {
                return false
            }
        }

        condition.lock()
        pendingWorkItems.append(workItem)
        condition.signal()
        condition.unlock()
        return true
    }

    /// Starts one worker, reporting whether the OS actually made the thread.
    ///
    /// `Thread`/`NSThread` is deliberately not used here: `start()` returns
    /// `Void` and swallows the failure this whole path exists to detect.
    private func spawnWorker() -> Bool {
        var threadAttributes = pthread_attr_t()
        guard pthread_attr_init(&threadAttributes) == 0 else { return false }
        defer { pthread_attr_destroy(&threadAttributes) }
        guard pthread_attr_setstacksize(&threadAttributes, StackSafeExecutor.largeStackThreadSize) == 0,
              pthread_attr_setdetachstate(&threadAttributes, PTHREAD_CREATE_DETACHED) == 0
        else {
            return false
        }
        _ = pthread_attr_set_qos_class_np(&threadAttributes, QOS_CLASS_USER_INITIATED, 0)

        let context = Unmanaged.passRetained(self).toOpaque()
        var threadHandle: pthread_t?
        let creationResult = pthread_create(&threadHandle, &threadAttributes, { rawContext in
            let pool = Unmanaged<LargeStackThreadPool>.fromOpaque(rawContext).takeRetainedValue()
            pthread_setname_np("swift-demangling.large-stack-worker")
            pool.runWorkerLoop()
            return nil
        }, context)
        guard creationResult == 0 else {
            Unmanaged<LargeStackThreadPool>.fromOpaque(context).release()
            return false
        }
        return true
    }

    private func runWorkerLoop() {
        Self.markCurrentThreadAsPoolWorker()

        while true {
            condition.lock()
            idleWorkerCount += 1
            while nextWorkItemIndex == pendingWorkItems.count {
                condition.wait()
            }
            idleWorkerCount -= 1
            let workItem = pendingWorkItems[nextWorkItemIndex]
            // Drop the queue's reference to the closure. `removeAll` below only
            // runs when the queue happens to drain completely, so under a
            // sustained burst every already-executed item would otherwise stay
            // alive — each one retaining whatever its caller captured, which on
            // the print and remangle paths is a whole `Node` tree.
            pendingWorkItems[nextWorkItemIndex] = {}
            nextWorkItemIndex += 1
            if nextWorkItemIndex == pendingWorkItems.count {
                pendingWorkItems.removeAll(keepingCapacity: true)
                nextWorkItemIndex = 0
            }
            condition.unlock()

            // The predecessor created a thread per call, and a thread drains
            // its own pool when it exits — so no explicit pool was needed. Long-
            // lived workers remove that drain point: without this, an
            // autoreleased object's release would move from "end of the call" to
            // "end of the process". The pool created the hazard; this closes it.
            autoreleasepool {
                workItem()
            }
        }
    }
}
#endif
