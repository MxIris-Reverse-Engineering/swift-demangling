import DemanglingTestingSupportC

/// Counts gross allocation events (malloc/calloc/valloc plus the allocation
/// half of realloc) through libmalloc's `malloc_logger` hook.
///
/// Counting is process-wide across all threads, so a measurement window is
/// only attributable when the workload under measurement is the sole activity
/// in the process. Windows must not overlap.
public enum MallocCounter {
    /// Resets the counter and installs the hook.
    public static func start() {
        demangling_malloc_counter_start()
    }

    /// Uninstalls the hook and returns the number of allocation events
    /// observed since the matching ``start()``.
    public static func stop() -> UInt64 {
        demangling_malloc_counter_stop()
    }
}
