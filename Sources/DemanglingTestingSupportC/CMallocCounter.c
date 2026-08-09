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
 * for the rest of the process (ReviewFindingsPR7 F13). */
static malloc_logger_t *demangling_saved_malloc_logger;

void demangling_malloc_counter_start(void) {
    atomic_store_explicit(&demangling_allocation_event_count, 0,
                          memory_order_relaxed);
    atomic_store_explicit(&demangling_large_allocation_event_count, 0,
                          memory_order_relaxed);
    /* Atomic builtins on the plain global: other threads read malloc_logger
     * on every allocation, so a plain store is a data race (TSan-visible)
     * even when the value transition is benign. */
    demangling_saved_malloc_logger = __atomic_load_n(&malloc_logger, __ATOMIC_ACQUIRE);
    __atomic_store_n(&malloc_logger, demangling_counting_malloc_logger, __ATOMIC_RELEASE);
}

uint64_t demangling_malloc_counter_stop(void) {
    __atomic_store_n(&malloc_logger, demangling_saved_malloc_logger, __ATOMIC_RELEASE);
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
