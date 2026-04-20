import Foundation

/// Executes blocks with automatic stack-size safety.
///
/// On Darwin, non-main threads (including Swift Concurrency cooperative workers)
/// default to 512KB stacks, which can cause stack overflows during deep recursion
/// inside the demangler/remangler. This type detects insufficient remaining stack
/// space and transparently re-dispatches the block to a dedicated 8MB-stack
/// `Thread`. On non-Darwin platforms, the block runs directly.
enum StackSafeExecutor {
    #if canImport(Darwin)
    /// Minimum stack space (in bytes) required for safe recursive operations.
    private static let minimumRequiredStackSize = 2 * 1024 * 1024 // 2MB

    /// Stack size allocated for the dedicated large-stack thread.
    private static let largeStackThreadSize = 8 * 1024 * 1024 // 8MB
    #endif

    /// Executes the given block, switching to a large-stack thread if the
    /// current thread's remaining stack space is insufficient.
    static func execute(_ block: @escaping @Sendable () -> String) -> String {
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
    static func execute<Success: Sendable, Failure: Error>(
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
    static func executeAsync<Success: Sendable, Failure: Error & Sendable>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) async throws(Failure) -> Success {
        #if canImport(Darwin)
        if currentThreadHasSufficientStack {
            return try block()
        }
        let outcome: Result<Success, Failure> = await withCheckedContinuation { continuation in
            let thread = Thread {
                do throws(Failure) {
                    continuation.resume(returning: .success(try block()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            thread.stackSize = largeStackThreadSize
            thread.qualityOfService = .userInitiated
            thread.start()
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

    private static func executeOnLargeStackThread(_ block: @escaping @Sendable () -> String) -> String {
        nonisolated(unsafe) var result: String = ""
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = block()
            semaphore.signal()
        }
        thread.stackSize = largeStackThreadSize
        thread.qualityOfService = .userInitiated
        thread.start()
        semaphore.wait()
        return result
    }

    private static func executeOnLargeStackThreadThrowing<Success: Sendable, Failure: Error>(
        _ block: @escaping @Sendable () throws(Failure) -> Success
    ) throws(Failure) -> Success {
        nonisolated(unsafe) var outcome: Result<Success, Failure>!
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            do throws(Failure) {
                outcome = .success(try block())
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        thread.stackSize = largeStackThreadSize
        thread.qualityOfService = .userInitiated
        thread.start()
        semaphore.wait()
        return try outcome.get()
    }
    #endif
}
