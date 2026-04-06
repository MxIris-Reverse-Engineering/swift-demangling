#if canImport(Darwin)
import Foundation

enum StackSafeExecutor {
    /// Minimum stack space (in bytes) required for safe recursive operations.
    private static let minimumRequiredStackSize = 2 * 1024 * 1024 // 2MB

    /// Stack size allocated for the dedicated large-stack thread.
    private static let largeStackThreadSize = 8 * 1024 * 1024 // 8MB

    /// Executes the given block, automatically switching to a large-stack thread
    /// if the current thread's remaining stack space is insufficient.
    ///
    /// On Darwin, non-main threads default to 512KB stacks, which can cause
    /// stack overflows during deep recursion. This method transparently handles
    /// that by detecting remaining stack space and re-dispatching when needed.
    static func execute(_ block: @escaping @Sendable () -> String) -> String {
        if currentThreadHasSufficientStack {
            return block()
        }
        return executeOnLargeStackThread(block)
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
}
#endif
