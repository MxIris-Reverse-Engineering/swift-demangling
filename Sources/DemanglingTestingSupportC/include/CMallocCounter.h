#ifndef CMALLOCCOUNTER_H
#define CMALLOCCOUNTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Resets the allocation-event counter to zero and installs the process-wide
/// malloc logger hook. Counting is process-wide: allocation events from every
/// thread are included, so callers should quiesce unrelated work while a
/// measurement window is open.
void demangling_malloc_counter_start(void);

/// Uninstalls the malloc logger hook and returns the number of allocation
/// events observed since the matching start call.
uint64_t demangling_malloc_counter_stop(void);

/// Sets the size threshold (in bytes) above which allocation events are
/// additionally counted as "large". Persists across start/stop pairs; the
/// default of UINT64_MAX counts nothing. Large-allocation counting exists to
/// surface buffer-regrowth copies (multi-megabyte allocations) inside a
/// window whose total event count they would otherwise vanish in.
void demangling_malloc_counter_set_large_allocation_threshold(uint64_t threshold_bytes);

/// Number of allocation events at or above the large-allocation threshold
/// observed since the matching start call. Read after stop.
uint64_t demangling_malloc_counter_large_allocation_event_count(void);

#ifdef __cplusplus
}
#endif

#endif /* CMALLOCCOUNTER_H */
