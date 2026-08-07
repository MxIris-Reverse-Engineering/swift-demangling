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

#ifdef __cplusplus
}
#endif

#endif /* CMALLOCCOUNTER_H */
