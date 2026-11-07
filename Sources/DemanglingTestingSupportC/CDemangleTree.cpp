// Self-contained wrapper around the toolchain's libswiftDemangle.dylib.
// Uses dlopen/dlsym at runtime — no Swift or LLVM headers required.
//
// Which library gets loaded is decided on the Swift side
// (`ToolchainDemangler.loadedLibraryPath`), where the choice is unit-tested;
// this file only binds the symbols of the library it is handed.

#include "CDemangleTree.h"
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>

// ---------------------------------------------------------------------------
// ABI-compatible declarations (matches the compiled layout in the dylib)
// ---------------------------------------------------------------------------

// llvm::StringRef is { const char*, size_t } — 16 bytes, passed in 2 regs.
struct StringRef {
    const char *data;
    size_t length;
};

// Opaque node pointer.
struct Node;

// swift::Demangle::Context is 8 bytes (a single NodeFactory pointer).
struct alignas(8) Context {
    uint64_t _storage;
};

// ---------------------------------------------------------------------------
// Function pointer types
// ---------------------------------------------------------------------------

using ContextConstructorFunction = void (*)(Context *);
using ContextDestructorFunction = void (*)(Context *);
using DemangleSymbolFunction = Node *(*)(Context *, StringRef);
using NodeTreeStringFunction = std::string (*)(Node *);
// The library's C API (include/swift/SwiftDemangle/SwiftDemangle.h): prints
// into the buffer and returns the full length of the text, or 0 when the
// toolchain does not demangle the name.
using DemangledNameFunction = size_t (*)(const char *, char *, size_t);

// ---------------------------------------------------------------------------
// Bound symbols — written once by swift_demangle_loadLibrary, before any other
// entry point runs (the Swift side guarantees that ordering).
// ---------------------------------------------------------------------------

static void *sLibrary = nullptr;
static ContextConstructorFunction sContextConstructor = nullptr;
static ContextDestructorFunction sContextDestructor = nullptr;
static DemangleSymbolFunction sDemangleSymbol = nullptr;
static NodeTreeStringFunction sNodeTreeString = nullptr;
static DemangledNameFunction sDemangledName = nullptr;
static DemangledNameFunction sSimplifiedDemangledName = nullptr;

bool swift_demangle_loadLibrary(const char *libraryPath) {
    if (sLibrary)
        return true;

    void *library = dlopen(libraryPath, RTLD_LAZY);
    if (!library)
        return false;

    // C++ mangled symbol names (stable across Swift 5.x / 6.x releases).
    auto contextConstructor = (ContextConstructorFunction) dlsym(library, "_ZN5swift8Demangle7ContextC1Ev");
    auto contextDestructor = (ContextDestructorFunction) dlsym(library, "_ZN5swift8Demangle7ContextD1Ev");
    auto demangleSymbol = (DemangleSymbolFunction) dlsym(library,
        "_ZN5swift8Demangle7Context20demangleSymbolAsNodeEN4llvm9StringRefE");
    auto nodeTreeString = (NodeTreeStringFunction) dlsym(library,
        "_ZN5swift8Demangle19getNodeTreeAsStringEPNS0_4NodeE");
    auto demangledName = (DemangledNameFunction) dlsym(library, "swift_demangle_getDemangledName");
    auto simplifiedDemangledName = (DemangledNameFunction) dlsym(library, "swift_demangle_getSimplifiedDemangledName");

    // A library missing any of them is not loaded at all: an oracle that can
    // compare trees but silently skips text would be the blind spot again.
    if (!contextConstructor || !contextDestructor || !demangleSymbol || !nodeTreeString ||
        !demangledName || !simplifiedDemangledName) {
        dlclose(library);
        return false;
    }

    sContextConstructor = contextConstructor;
    sContextDestructor = contextDestructor;
    sDemangleSymbol = demangleSymbol;
    sNodeTreeString = nodeTreeString;
    sDemangledName = demangledName;
    sSimplifiedDemangledName = simplifiedDemangledName;
    sLibrary = library;
    return true;
}

// ---------------------------------------------------------------------------
// Public C API
// ---------------------------------------------------------------------------

char *swift_demangle_getNodeTreeAsString(const char *mangledName) {
    if (!mangledName || !sLibrary)
        return nullptr;

    Context context;
    sContextConstructor(&context);

    StringRef reference = { mangledName, strlen(mangledName) };
    Node *node = sDemangleSymbol(&context, reference);

    char *result = nullptr;
    if (node) {
        std::string tree = sNodeTreeString(node);
        result = static_cast<char *>(malloc(tree.size() + 1));
        memcpy(result, tree.c_str(), tree.size() + 1);
    }

    sContextDestructor(&context);
    return result;
}

static char *copyDemangledName(DemangledNameFunction demangledName, const char *mangledName) {
    if (!mangledName || !sLibrary)
        return nullptr;

    // Most names fit the stack buffer; a longer one is printed a second time
    // into a buffer of the exact length the first call reported.
    char stackBuffer[4096];
    size_t length = demangledName(mangledName, stackBuffer, sizeof stackBuffer);
    if (length == 0)
        return nullptr;

    char *result = static_cast<char *>(malloc(length + 1));
    if (length < sizeof stackBuffer) {
        memcpy(result, stackBuffer, length + 1);
    } else {
        demangledName(mangledName, result, length + 1);
    }
    return result;
}

char *swift_demangle_copyDemangledName(const char *mangledName) {
    return copyDemangledName(sDemangledName, mangledName);
}

char *swift_demangle_copySimplifiedDemangledName(const char *mangledName) {
    return copyDemangledName(sSimplifiedDemangledName, mangledName);
}
