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

    /// Sets the size threshold at or above which allocation events are
    /// additionally counted as "large". Persists across start/stop pairs;
    /// the default (`UInt64.max`) counts nothing. Exists to surface
    /// buffer-regrowth copies — a few dozen multi-megabyte events that
    /// vanish inside a window's tens of millions of total events.
    public static func setLargeAllocationThreshold(_ thresholdBytes: UInt64) {
        demangling_malloc_counter_set_large_allocation_threshold(thresholdBytes)
    }

    /// Number of allocation events at or above the large-allocation
    /// threshold since the matching ``start()``. Read after ``stop()``.
    public static var largeAllocationEventCount: UInt64 {
        demangling_malloc_counter_large_allocation_event_count()
    }
}
