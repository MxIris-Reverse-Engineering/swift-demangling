/* Interposes swift_retain / swift_release to count ARC events targeting one
 * watched object (proposal 0008, B2 acceptance: the store print walk must not
 * retain or release the store per visited child).
 *
 * Build:  clang -dynamiclib Scripts/RetainCounter/retain-counter.c \
 *           -o /tmp/claude/libretaincounter.dylib
 * Use:    DYLD_INSERT_LIBRARIES=/tmp/claude/libretaincounter.dylib \
 *           .../RetainCountVerification
 *
 * Interposing only rebinds calls that go through dyld stubs — exactly the
 * retains emitted in the Demangling module's own code, which is what the
 * measurement is about. The dylib must be loaded at launch (insertion or
 * direct linking); interpose sections in dlopen'ed images are ignored.
 */

#include <stdint.h>
#include <stdatomic.h>

extern void *swift_retain(void *object);
extern void swift_release(void *object);

static _Atomic(void *) watched_object;
static _Atomic uint64_t watched_retain_count;
static _Atomic uint64_t watched_release_count;

void retain_counter_watch(void *object) {
    atomic_store_explicit(&watched_object, object, memory_order_relaxed);
    atomic_store_explicit(&watched_retain_count, 0, memory_order_relaxed);
    atomic_store_explicit(&watched_release_count, 0, memory_order_relaxed);
}

uint64_t retain_counter_retains(void) {
    return atomic_load_explicit(&watched_retain_count, memory_order_relaxed);
}

uint64_t retain_counter_releases(void) {
    return atomic_load_explicit(&watched_release_count, memory_order_relaxed);
}

static void *counting_swift_retain(void *object) {
    if (object && object == atomic_load_explicit(&watched_object, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&watched_retain_count, 1, memory_order_relaxed);
    }
    return swift_retain(object);
}

static void counting_swift_release(void *object) {
    if (object && object == atomic_load_explicit(&watched_object, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&watched_release_count, 1, memory_order_relaxed);
    }
    swift_release(object);
}

typedef struct {
    const void *replacement;
    const void *replacee;
} interpose_pair;

__attribute__((used, section("__DATA,__interpose")))
static const interpose_pair interposers[] = {
    { (const void *)counting_swift_retain, (const void *)swift_retain },
    { (const void *)counting_swift_release, (const void *)swift_release },
};
