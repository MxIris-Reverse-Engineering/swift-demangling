#ifndef CDEMANGLETREE_H
#define CDEMANGLETREE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Binds the toolchain demangler at `libraryPath`. Returns false when the
/// library cannot be opened or lacks a symbol the oracle needs. The first
/// successful load wins; it must happen before any other function here runs.
bool swift_demangle_loadLibrary(
    const char * _Nonnull libraryPath
);

/// Demangle a mangled name and return the node tree as a string.
/// Returns NULL if demangling fails or no library is loaded.
/// Caller must free() the result.
char * _Nullable swift_demangle_getNodeTreeAsString(
    const char * _Nonnull mangledName
);

/// The toolchain's printed text for a mangled name under `DemangleOptions()`
/// with type sugar — what `swift-demangle` prints by default. Returns NULL if
/// the toolchain does not demangle it or no library is loaded.
/// Caller must free() the result.
char * _Nullable swift_demangle_copyDemangledName(
    const char * _Nonnull mangledName
);

/// The same under `DemangleOptions::SimplifiedUIDemangleOptions()` — what
/// `swift-demangle -simplified` prints.
char * _Nullable swift_demangle_copySimplifiedDemangledName(
    const char * _Nonnull mangledName
);

#ifdef __cplusplus
}
#endif

#endif /* CDEMANGLETREE_H */
