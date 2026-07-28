import Foundation

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
/// SPI note: exposed as `@_spi(Internals)` so deep consumers driving
/// ``DemanglingPrinter`` directly get the same treatment as the library's own
/// entry points.
@_spi(Internals)
public enum StackSafeExecutor {
    #if canImport(Darwin)
    /// Remaining stack below which work is moved to a pooled worker.
    ///
    /// Deliberately far above what a shallow symbol needs: the point is not to
    /// predict whether *this* input will fit — ``StackBudget`` handles the case
    /// where it does not — but to keep the common path off the 512KB threads
    /// where depth would be capped at a few dozen levels.
    private static let minimumRequiredStackSize = 2 * 1024 * 1024 // 2MB

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
        #if canImport(Darwin)
        if currentThreadHasSufficientStack || LargeStackThreadPool.isRunningOnPoolWorker {
            return try body()
        }
        return try runOnPoolWorker(body)
        #else
        return try body()
        #endif
    }

    /// Executes the given block, switching to a large-stack worker if the
    /// current thread's remaining stack space is insufficient.
    public static func execute(_ block: @escaping @Sendable () -> String) -> String {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack || LargeStackThreadPool.isRunningOnPoolWorker {
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
        if currentThreadHasSufficientStack || LargeStackThreadPool.isRunningOnPoolWorker {
            return try block()
        }
        return try runOnPoolWorker(block)
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
        if currentThreadHasSufficientStack || LargeStackThreadPool.isRunningOnPoolWorker {
            return try block()
        }
        let outcome: Result<Success, Failure> = await withCheckedContinuation { continuation in
            LargeStackThreadPool.shared.submit {
                do throws(Failure) {
                    continuation.resume(returning: .success(try block()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try outcome.get()
        #else
        return try block()
        #endif
    }

    #if canImport(Darwin)
    private static var currentThreadHasSufficientStack: Bool {
        let stackAddress = pthread_get_stackaddr_np(pthread_self())
        let stackSize = pthread_get_stacksize_np(pthread_self())
        let stackBase = stackAddress - stackSize
        var localVariable = 0
        let currentAddress = withUnsafeMutablePointer(to: &localVariable) { Int(bitPattern: $0) }
        let remainingStackSpace = currentAddress - Int(bitPattern: stackBase)
        return remainingStackSpace >= minimumRequiredStackSize
    }

    private static func runOnPoolWorker<Success: Sendable>(_ block: @escaping @Sendable () -> Success) -> Success {
        nonisolated(unsafe) var result: Success!
        let semaphore = DispatchSemaphore(value: 0)
        LargeStackThreadPool.shared.submit {
            result = block()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private static func runOnPoolWorker<Success: Sendable, Failure: Error>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        nonisolated(unsafe) var outcome: Result<Success, Failure>!
        let semaphore = DispatchSemaphore(value: 0)
        LargeStackThreadPool.shared.submit {
            do throws(Failure) {
                outcome = .success(try block())
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome.get()
    }
    #endif
}

#if canImport(Darwin)
/// A bounded pool of long-lived large-stack workers.
///
/// Creating and joining a `Thread` per call costs roughly 41µs measured on this
/// package — five to eighteen times the work itself for a typical symbol, and
/// seconds of pure overhead when indexing a framework. Workers are therefore
/// created on demand and kept.
///
/// Three properties are load-bearing and easy to lose:
///
/// - **Workers never retire.** An idle-timeout retirement has a window between
///   the timeout firing and the worker reacquiring the lock in which a
///   submission counts it as available, creates no replacement, and signals
///   nobody — the work item is then never run and the caller blocks forever.
///   Keeping workers alive removes the window rather than trying to close it.
///   Idle workers cost a kernel thread structure each; their 64MB stacks are
///   untouched address space.
/// - **The pool is capped**, so a burst of concurrent submissions cannot spawn
///   an unbounded number of threads. `executeAsync` in particular returns
///   immediately and applies no back-pressure of its own.
/// - **A worker never waits on the pool.** Printing re-enters demangling for
///   nested mangled names, so work submitted from a worker would block on a
///   capped pool. ``isRunningOnPoolWorker`` makes those calls run inline
///   instead — they are already on a large stack, which is the whole point.
final class LargeStackThreadPool: @unchecked Sendable {
    static let shared = LargeStackThreadPool()

    /// Thread-local marker key.
    ///
    /// `Thread.current.threadDictionary` would be the obvious place for this,
    /// but reading it materializes an `NSThread` wrapper and lazily allocates —
    /// and permanently retains — an `NSMutableDictionary` on every thread that
    /// ever demangles. This check sits on all four entry points, so it has to
    /// be a bare `pthread_getspecific`.
    private static let workerMarkerKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    /// Whether the calling thread is one of this pool's workers.
    static var isRunningOnPoolWorker: Bool {
        pthread_getspecific(workerMarkerKey) != nil
    }

    static func markCurrentThreadAsPoolWorker() {
        // Any non-null value marks the thread; the key has no destructor, so
        // nothing is ever dereferenced.
        pthread_setspecific(workerMarkerKey, UnsafeMutableRawPointer(bitPattern: 1))
    }

    private let maximumWorkerCount = max(2, ProcessInfo.processInfo.activeProcessorCount)

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

    var maximumWorkerCountForTesting: Int { maximumWorkerCount }

    func submit(_ workItem: @escaping @Sendable () -> Void) {
        condition.lock()
        pendingWorkItems.append(workItem)
        let queuedCount = pendingWorkItems.count - nextWorkItemIndex
        let needsAdditionalWorker = queuedCount > idleWorkerCount && workerCount < maximumWorkerCount
        if needsAdditionalWorker {
            workerCount += 1
        }
        condition.signal()
        condition.unlock()

        guard needsAdditionalWorker else { return }

        let thread = Thread { [self] in runWorkerLoop() }
        thread.stackSize = StackSafeExecutor.largeStackThreadSize
        thread.qualityOfService = .userInitiated
        thread.name = "swift-demangling.large-stack-worker"
        thread.start()
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
            nextWorkItemIndex += 1
            if nextWorkItemIndex == pendingWorkItems.count {
                pendingWorkItems.removeAll(keepingCapacity: true)
                nextWorkItemIndex = 0
            }
            condition.unlock()

            // The predecessor created a `Thread` per call, and a thread drains
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
