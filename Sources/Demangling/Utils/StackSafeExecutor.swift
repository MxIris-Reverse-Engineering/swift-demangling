import Foundation

/// SPI note: exposed as `@_spi(Internals)` so deep consumers driving
/// `DemanglingPrinter` directly can reuse the same stack-safety wrapper the
/// library uses for its own print/remangle entry points.
/// Executes blocks with automatic stack-size safety.
///
/// On Darwin, non-main threads (including Swift Concurrency cooperative workers)
/// default to 512KB stacks, which can cause stack overflows during deep recursion
/// inside the demangler/remangler. This type detects insufficient remaining stack
/// space and transparently re-dispatches the block to a dedicated 8MB-stack
/// `Thread`. On non-Darwin platforms, the block runs directly.
@_spi(Internals)
public enum StackSafeExecutor {
    #if canImport(Darwin)
    /// Minimum stack space (in bytes) required for safe recursive operations.
    private static let minimumRequiredStackSize = 2 * 1024 * 1024 // 2MB

    /// Stack size allocated for the dedicated large-stack thread.
    fileprivate static let largeStackThreadSize = 8 * 1024 * 1024 // 8MB

    /// Stack space reserved below a budgeted recursion for the non-recursive
    /// work that still has to run once the recursion unwinds.
    private static let stackSafetyMargin = 64 * 1024 // 64KB
    #endif

    /// Executes the given block, switching to a large-stack thread if the
    /// current thread's remaining stack space is insufficient.
    public static func execute(_ block: @escaping @Sendable () -> String) -> String {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack {
            return block()
        }
        return executeOnLargeStackThread(block)
        #else
        return block()
        #endif
    }

    /// Throwing, generic variant of ``execute(_:)``.
    ///
    /// Re-dispatches to a dedicated 8MB-stack `Thread` when the current thread
    /// is about to run out of room, and propagates typed errors across the
    /// thread boundary.
    public static func execute<Success: Sendable, Failure: Error>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack {
            return try block()
        }
        return try executeOnLargeStackThreadThrowing(block)
        #else
        return try block()
        #endif
    }

    /// Async variant that suspends the current task on a dedicated 8MB-stack
    /// `Thread` when the current thread's remaining stack space is insufficient,
    /// so Swift Concurrency's cooperative pool worker stays free to serve other
    /// tasks during the wait.
    ///
    /// When the current thread (e.g. the main thread or an already-large stack)
    /// has enough room, the block runs inline without spawning a thread or
    /// suspending. Use this from async contexts when you want to avoid blocking
    /// a cooperative worker on an OS-level semaphore.
    public static func executeAsync<Success: Sendable, Failure: Error & Sendable>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) async throws(Failure) -> Success {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack {
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

    /// Runs a recursion that can bail out when it approaches the end of the
    /// current thread's stack, falling back to a large-stack worker only for
    /// the inputs that actually need one.
    ///
    /// ``execute(_:)`` has to assume the worst about every input, so on a
    /// 512KB-stack thread it hands *every* call to a worker thread. Most real
    /// inputs are nowhere near deep enough to need that: `printName` recursion
    /// for a typical symbol is a few dozen frames. `budgetedAttempt` receives
    /// the address the stack must not grow past and returns `nil` if it hit
    /// that limit; only then does `unbudgetedFallback` run on a worker.
    ///
    /// - Parameters:
    ///   - budgetedAttempt: runs inline on the current thread. Must return
    ///     `nil` — having produced no side effects the caller depends on —
    ///     when the recursion reaches `stackFloorAddress`.
    ///   - unbudgetedFallback: re-runs the same work with no depth limit, on a
    ///     thread known to have room for it.
    public static func executeWithinStackBudget<Success: Sendable>(
        budgetedAttempt: (_ stackFloorAddress: UInt) -> Success?,
        unbudgetedFallback: @escaping @Sendable () -> Success
    ) -> Success {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack {
            return unbudgetedFallback()
        }
        if let result = budgetedAttempt(stackFloorAddressForCurrentThread) {
            return result
        }
        return executeOnLargeStackThreadReturning(unbudgetedFallback)
        #else
        return unbudgetedFallback()
        #endif
    }

    #if canImport(Darwin)
    private static var stackFloorAddressForCurrentThread: UInt {
        let stackAddress = pthread_get_stackaddr_np(pthread_self())
        let stackSize = pthread_get_stacksize_np(pthread_self())
        let stackBase = UInt(bitPattern: stackAddress - stackSize)
        return stackBase + UInt(stackSafetyMargin)
    }

    private static func executeOnLargeStackThreadReturning<Success: Sendable>(
        _ block: @escaping @Sendable () -> Success
    ) -> Success {
        nonisolated(unsafe) var result: Success!
        let semaphore = DispatchSemaphore(value: 0)
        LargeStackThreadPool.shared.submit {
            result = block()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private static var currentThreadHasSufficientStack: Bool {
        let stackAddress = pthread_get_stackaddr_np(pthread_self())
        let stackSize = pthread_get_stacksize_np(pthread_self())
        let stackBase = stackAddress - stackSize
        var localVariable = 0
        let currentAddress = withUnsafeMutablePointer(to: &localVariable) { Int(bitPattern: $0) }
        let remainingStackSpace = currentAddress - Int(bitPattern: stackBase)
        return remainingStackSpace >= minimumRequiredStackSize
    }

    private static func executeOnLargeStackThread(_ block: @escaping @Sendable () -> String) -> String {
        nonisolated(unsafe) var result: String = ""
        let semaphore = DispatchSemaphore(value: 0)
        LargeStackThreadPool.shared.submit {
            result = block()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private static func executeOnLargeStackThreadThrowing<Success: Sendable, Failure: Error>(
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
/// A pool of long-lived large-stack worker threads, reused across calls.
///
/// Every call used to create — and then join — a brand new `Thread`. Because
/// ``StackSafeExecutor/currentThreadHasSufficientStack`` demands 2MB of
/// *remaining* stack while a Swift Concurrency cooperative worker and a
/// libdispatch worker both get a 512KB stack in total, the large-stack branch
/// is taken unconditionally off the main thread: measured on this package,
/// 2000 demangles cost 64ms on the main thread (run inline) against 163ms on a
/// `DispatchQueue.global()` thread, i.e. roughly 50µs of thread setup on top of
/// a ~32µs demangle. Bulk work — demangling every symbol of a framework, or
/// printing every declaration of an interface — paid that per item.
///
/// Threads are created on demand, reused while work keeps arriving, and retired
/// after an idle period so a burst does not leave workers resident forever.
///
/// A worker never submits back into the pool: it runs on an 8MB stack, so
/// ``StackSafeExecutor/execute(_:)`` takes its inline branch there, and nested
/// demangle/remangle calls cannot deadlock against a saturated pool.
private final class LargeStackThreadPool: @unchecked Sendable {
    static let shared = LargeStackThreadPool()

    /// How long an idle worker waits for new work before retiring.
    private static let idleTimeout: TimeInterval = 30

    private let condition = NSCondition()
    private var pendingWorkItems: [@Sendable () -> Void] = []
    private var idleWorkerCount = 0

    func submit(_ workItem: @escaping @Sendable () -> Void) {
        condition.lock()
        pendingWorkItems.append(workItem)
        // Only spin up a worker when the queue outgrows the idle workers that
        // are already parked on the condition; overshooting under a race just
        // creates one extra worker, which then retires on its idle timeout.
        let needsAdditionalWorker = pendingWorkItems.count > idleWorkerCount
        condition.signal()
        condition.unlock()

        if needsAdditionalWorker {
            let thread = Thread { [self] in runWorkerLoop() }
            thread.stackSize = StackSafeExecutor.largeStackThreadSize
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func runWorkerLoop() {
        while true {
            condition.lock()
            idleWorkerCount += 1
            while pendingWorkItems.isEmpty {
                if !condition.wait(until: Date(timeIntervalSinceNow: Self.idleTimeout)) {
                    idleWorkerCount -= 1
                    condition.unlock()
                    return
                }
            }
            idleWorkerCount -= 1
            let workItem = pendingWorkItems.removeFirst()
            condition.unlock()

            workItem()
        }
    }
}
#endif
