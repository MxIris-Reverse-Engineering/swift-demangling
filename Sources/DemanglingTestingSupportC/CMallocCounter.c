#include "CMallocCounter.h"

#include <stdatomic.h>

/* libmalloc's stack-logging hook: when set, every allocation event in the
 * process calls through this pointer. Declared locally because the header
 * that ships it (libmalloc's stack_logging.h) is not in the public SDK; the
 * symbol itself is exported by libSystem and stable — the MallocStackLogging
 * tooling depends on it. */
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2,
                              uintptr_t arg3, uintptr_t result,
                              uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;

/* stack_logging_type_alloc from libmalloc's stack_logging.h: set for malloc,
 * calloc, valloc, and the allocation half of realloc. Deallocation events
 * carry bit 4 instead and are deliberately not counted — the metric is gross
 * allocations, not net live blocks. */
#define DEMANGLING_STACK_LOGGING_TYPE_ALLOC 2u
#define DEMANGLING_STACK_LOGGING_TYPE_DEALLOC 4u

static _Atomic uint64_t demangling_allocation_event_count;
static _Atomic uint64_t demangling_large_allocation_event_count;
static _Atomic uint64_t demangling_large_allocation_threshold = UINT64_MAX;

/* Counts and returns; it deliberately does NOT chain to
 * demangling_saved_malloc_logger.
 *
 * The consequence is real and worth stating: for the duration of a window, any
 * tool that was already logging (MallocStackLogging, Instruments Allocations,
 * `leaks`) sees no allocation events but still sees the matching frees
 * afterwards, so its live-block set under-counts by exactly the allocations the
 * window leaves alive — hundreds of thousands of nodes for a bulk NodeStore
 * build. F13 restored the saved *pointer* at stop(); the events lost *during*
 * the window are this trade.
 *
 * Chaining was considered and rejected: the saved logger is arbitrary
 * third-party code running inside the allocator, so calling it here reintroduces
 * the re-entrancy the counting hook is careful to avoid and puts unbounded work
 * inside the very window whose timing the benchmarks measure. A measurement run
 * is not the run to profile under another allocation tool
 * (PR #7 review, finding 12, second defect). */
static void demangling_counting_malloc_logger(uint32_t type, uintptr_t arg1,
                                              uintptr_t arg2, uintptr_t arg3,
                                              uintptr_t result,
                                              uint32_t num_hot_frames_to_skip) {
    (void)arg1;
    (void)result;
    (void)num_hot_frames_to_skip;
    if (type & DEMANGLING_STACK_LOGGING_TYPE_ALLOC) {
        atomic_fetch_add_explicit(&demangling_allocation_event_count, 1,
                                  memory_order_relaxed);
        /* Requested size sits in arg2 for plain allocations; realloc events
         * carry both the alloc and dealloc bits and move the size to arg3
         * (arg2 is the old pointer there). */
        uint64_t requested_size =
            (type & DEMANGLING_STACK_LOGGING_TYPE_DEALLOC) ? arg3 : arg2;
        if (requested_size >= atomic_load_explicit(
                                  &demangling_large_allocation_threshold,
                                  memory_order_relaxed)) {
            atomic_fetch_add_explicit(&demangling_large_allocation_event_count,
                                      1, memory_order_relaxed);
        }
    }
}

/* The hook installed before start(), restored by stop(). Without the
 * save/restore, stop() wrote 0 unconditionally and permanently disabled
 * whatever was logging before — MallocStackLogging, Instruments, `leaks` —
 * for the rest of the process (ReviewFindingsPR7 F13).
 *
 * _Atomic because the save and the restore can run on different threads: the
 * window is serialized by ExclusiveMeasurementWindow, but that lock orders
 * them without publishing this slot between them. */
static _Atomic(malloc_logger_t *) demangling_saved_malloc_logger;

/* Depth of nested start() calls, so only the outermost pair touches the hook.
 *
 * The save/restore alone is not enough: ExclusiveMeasurementWindow serializes
 * with an NSRecursiveLock, which by design lets one thread re-enter. A nested
 * start() would then save the *counting* hook as the thing to restore, and
 * both stop() calls would put the counting hook back — the caller's original
 * logger lost for the rest of the process, which is precisely the failure F13
 * set out to fix. No current call site nests (each benchmark @Test opens one
 * window), so this is a guard rail rather than a live bug fix; MallocCounter
 * is public to the test-support module, so a new suite could introduce one. */
static _Atomic(int) demangling_malloc_counter_depth;

void demangling_malloc_counter_start(void) {
    if (atomic_fetch_add_explicit(&demangling_malloc_counter_depth, 1,
                                  memory_order_acq_rel) != 0) {
        /* Nested: the outermost window owns the hook and the counters. */
        return;
    }
    atomic_store_explicit(&demangling_allocation_event_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&demangling_large_allocation_event_count, 0,
                          memory_order_relaxed);
    /* Atomic builtins on the plain global: other threads read malloc_logger
     * on every allocation, so a plain store is a data race (TSan-visible)
     * even when the value transition is benign. */
    malloc_logger_t *previous_logger = __atomic_load_n(&malloc_logger, __ATOMIC_ACQUIRE);
    atomic_store_explicit(&demangling_saved_malloc_logger, previous_logger,
                          memory_order_release);
    __atomic_store_n(&malloc_logger, demangling_counting_malloc_logger, __ATOMIC_RELEASE);
}

uint64_t demangling_malloc_counter_stop(void) {
    /* Decrement only from a positive depth, in one compare-exchange.
     *
     * The previous shape was fetch_sub followed by a compensating fetch_add for
     * the unbalanced case, which left the depth transiently negative. A
     * concurrent start() reading that negative value takes the "nested" early
     * return: it neither zeroes the counters nor installs the hook, so its whole
     * window measures nothing and its stop() reports a stale count from an
     * earlier window — a benchmark silently publishing a wrong allocation
     * figure, the failure the depth counter was added to prevent
     * (PR #7 review, finding 12). */
    int previous_depth = atomic_load_explicit(&demangling_malloc_counter_depth,
                                              memory_order_acquire);
    while (previous_depth > 0 &&
           !atomic_compare_exchange_weak_explicit(&demangling_malloc_counter_depth,
                                                  &previous_depth, previous_depth - 1,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
        /* previous_depth was reloaded by the failed exchange; retry. */
    }
    if (previous_depth == 1) {
        malloc_logger_t *saved_logger =
            atomic_load_explicit(&demangling_saved_malloc_logger, memory_order_acquire);
        __atomic_store_n(&malloc_logger, saved_logger, __ATOMIC_RELEASE);
    }
    return atomic_load_explicit(&demangling_allocation_event_count,
                                memory_order_relaxed);
}

void demangling_malloc_counter_set_large_allocation_threshold(
    uint64_t threshold_bytes) {
    atomic_store_explicit(&demangling_large_allocation_threshold,
                          threshold_bytes, memory_order_relaxed);
}

uint64_t demangling_malloc_counter_large_allocation_event_count(void) {
    return atomic_load_explicit(&demangling_large_allocation_event_count,
                                memory_order_relaxed);
}
