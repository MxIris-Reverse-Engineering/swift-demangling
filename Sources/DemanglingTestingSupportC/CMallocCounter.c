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

static _Atomic uint64_t demangling_allocation_event_count;

static void demangling_counting_malloc_logger(uint32_t type, uintptr_t arg1,
                                              uintptr_t arg2, uintptr_t arg3,
                                              uintptr_t result,
                                              uint32_t num_hot_frames_to_skip) {
    (void)arg1;
    (void)arg2;
    (void)arg3;
    (void)result;
    (void)num_hot_frames_to_skip;
    if (type & DEMANGLING_STACK_LOGGING_TYPE_ALLOC) {
        atomic_fetch_add_explicit(&demangling_allocation_event_count, 1,
                                  memory_order_relaxed);
    }
}

void demangling_malloc_counter_start(void) {
    atomic_store_explicit(&demangling_allocation_event_count, 0,
                          memory_order_relaxed);
    malloc_logger = demangling_counting_malloc_logger;
}

uint64_t demangling_malloc_counter_stop(void) {
    malloc_logger = 0;
    return atomic_load_explicit(&demangling_allocation_event_count,
                                memory_order_relaxed);
}
