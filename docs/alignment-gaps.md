# Alignment Gaps: Swift Port vs Upstream Swift Compiler

Captured 2026-04-14. Upstream reference: `/Volumes/SwiftProjects/swift-project/swift/lib/Demangling/` and `/Volumes/SwiftProjects/swift-project/swift/include/swift/Demangling/`.

All Swift paths below are relative to `Sources/Demangling/`. C++ references are relative to `swift/lib/Demangling/` or `swift/include/swift/Demangling/`.

## 1. Correctness bugs (wrong output or stream corruption)

### Demangler

| # | Swift location | Issue | Upstream reference |
|---|---|---|---|
| 1 | `Main/Demangle/Demangler.swift:2376` | `NativePinningMutableAddressor` case uses lowercase `"p"`, which is already consumed by the outer `case "p"` branch → the branch is dead code. | `Demangler.cpp:4140` uses `'P'`. |
| 2 | `Main/Demangle/Demangler.swift:2140-2175` | `demangleWitness` `"O"` pops `sig` + `type` at the top of the function, then the inner `"B"` sub-branch pops them **again**, consuming two extra stack entries. | `Demangler.cpp:3724-3855` pops fresh `(Type, sig)` per inner case. |
| 3 | `Main/Demangle/Demangler.swift:1715` | `demangleThunkOrSpecialization` `"H"/"h"` reads `isSerialized` via `scanner.peek() == "q"` but never consumes the `q`; the next operator then re-reads it and corrupts the stream. | `Demangler.cpp:3110` calls `nextIf('q')`. |
| 4 | `Main/Demangle/Demangler.swift:2299,2300,2305` | Sugared `Sq` / `Sa` / `Sp` branches return the `NodeFactory` empty-singleton nodes without popping the element type child, so the element type is silently dropped. | `Demangler.cpp:4025-4045` pops `Kind::Type` as child for each. |
| 5 | `Main/Demangle/Demangler.swift:2689` | `demangleIntegerType` stores the raw `demangleIndex()` for the negative case. C++ stores `-demangleIndex()`. Because Swift uses `Node.Contents.index: UInt64`, the sign is lost. **Test-confirmed:** `$s$n3_SSBV` re-mangles to `_$s$n18446744073709551611_SSBV` (i.e. `UInt64.max - 2`). | `Demangler.cpp:4623` `NegativeInteger, -demangleIndex()`. |
| 6 | `Main/Demangle/Demangler.swift:2178-2184` | `globalVariableOnceDeclList` builds children in raw stack order. C++ walks the popped vars in reverse. Missing `.reverse()` before node creation. | `Demangler.cpp:3859-3869`. |
| 7 | `Main/Demangle/Demangler.swift:162` | `demangleOperator` never skips the `0xFF` alignment-padding byte used by symbolic references. | `Demangler.cpp:1029-1033` `case 0xFF: goto recur;`. |
| 8 | `Main/Demangle/Demangler.swift:182` | `"D"` (TypeMangling) is inlined as `Node.create(kind: .typeMangling, child: require(pop(kind: .type)))`, skipping the upstream `popFunctionParamLabels` attachment step. | `Demangler.cpp:907-915` via `demangleTypeMangling()`. |
| 9 | `Main/Demangle/Demangler.swift:1410-1411` | `demangleMetatype` has extra `"d"` and `"R"` cases that don't exist in upstream. `"d"` duplicates `"D"`; `"R"` maps to `typeMetadataMangledNameRef`. Likely stale old-mangling remnants. | `Demangler.cpp:2534-2633` has no such cases. |
| 10 | `Main/Demangle/Demangler.swift:123-127` | `parseAndPushNames` does not treat an embedded `\0` as end-of-symbol; it throws `unexpectedError` instead. | `Demangler.cpp:822-823` `if (peekChar() == '\0') return true;`. |
| 11 | `Main/Demangle/Demangler.swift:54` | `readManglingPrefix` accepts `$e` / `_$e` but never sets `flavor = .embedded`. Embedded-specific demangling / printing is effectively disabled. | `Demangler.cpp:759-760`. |

### NodePrinter

| # | Swift location | Issue | Upstream reference |
|---|---|---|---|
| 12 | `Node/Printer/NodePrinter.swift` `printConcreteProtocolConformance` | Writes `" #<index>"` unconditionally, with `" #"` / `"#"` spacing mismatched against upstream, even when `hasIndex()` would be false upstream. | `NodePrinter.cpp:3261` guards on `hasIndex()` and emits `"#<i> "`. |
| 13 | `Node/Printer/NodePrinter.swift` `.globalVariableOnceToken` case | Falls through to the `.globalVariableOnceFunction` path and prefixes `"one-time initialization ..."`. Upstream routes it through the default `printEntity` path with no such prefix. | `NodePrinter.cpp:599`. |

### Remangler

| # | Swift location | Issue | Upstream reference |
|---|---|---|---|
| 14 | `Main/Remangle/Remangler.swift:1338` | `mangleGlobal` hard-codes the emitted prefix as `"_$s"` (with a leading underscore). Upstream emits a bare `"$s"`; the leading underscore is only added by tools that want Mach-O linker form. Every `mangleNodeAsString` call therefore produces a form that does not round-trip against a plain `$s...` input. The Swift port's test roundtrip has to canonicalize both sides to compare. | `Remangler.cpp` `Remangler::mangleGlobal` writes `"$s"`. |
| 15 | `Main/Remangle/Remangler.swift` standard substitution path | The substitution pass collapses fully-qualified stdlib type paths too aggressively. `_$Ss10DictionaryV3t17E…` re-mangles to `_$sSD3t17E…` (where `SD` is the standard substitution for `Swift.Dictionary`); upstream preserves `s10DictionaryV` when the original symbol also wrote it out. The discrepancy surfaces whenever a stdlib type has both a standard-substitution form and a long-form encoding in the same symbol. | `Remangler.cpp` standard substitution tracking uses position-aware merging. |

## 2. Options declared but never implemented

| Option | Status |
|---|---|
| `DisplayLocalNameContexts` | `.localDeclName` in `NodePrinter` always appends `" #N"`; the option flag is never read. |
| `ShowPrivateDiscriminators` | `.privateDeclName` single-child branch does not emit `"(in <ctx>)"`. |
| `DisplayWhereClauses` | `printGenericSignature` ignores the flag entirely. |

The upstream `DemangleOptions` struct also declares three fields that the Swift `DemangleOptions` OptionSet lacks entirely:

- `HidingCurrentModule` (a string, used to suppress a specific module qualifier)
- `GenericParameterName` (a callback for custom generic-parameter naming)
- `DisplayLocalNameContexts` (the boolean that drives gap #12 above)

## 3. Structural gaps

### Missing subsystems

- **`OldDemangler.cpp` is only partially ported.** The V1 `_T` / `_Tt` / `_TW` / `_TT*` grammar covered by upstream `lib/Demangling/OldDemangler.cpp` is not fully implemented. The port handles a subset (basic `_T0…`, simple `_TtBf*` builtins) but throws `unexpectedError` / `matchFailed` on the majority of V1 forms. **Test-confirmed:** 130+ of the 134 `manglings.txt` failures and all 42 `simplified-manglings.txt` failures are V1 inputs — `_TtC`, `_TtT`, `_TtTSi`, `_TtQd_`, `_TtU___*`, `_TW`, `_TWo`, `_TWvd`, `_TWV`, `_TM`, `_TC`, `_TTRXFo*` (reabstraction thunks), `_TTSg*` (generic specialization), `_TTSf*` (function signature specialization), `_TPA*` (partial apply). Consequence: the port cannot demangle Swift 3 or earlier symbols that any ObjC-bridged or legacy binary will still emit.
- **`OldRemangler.cpp` is not ported at all.** All 3174 C++ lines and every `mangleOld*` entry point are absent. Consequence: even the V1 symbols the port *can* demangle cannot be re-mangled. Any consumer that needs objc-runtime mangling output is broken.
- **`Context` class is not ported.** The upstream `Demangle::Context` wraps the node factory and exposes stateful helpers:
  - `demangleSymbolAsNode`, `demangleTypeAsNode`, `demangleSymbolAsString`, `demangleTypeAsString`
  - `isThunkSymbol`, `getThunkTarget`, `hasSwiftCallingConvention`, `getModuleName`
  - `isAlias`, `isClass`, `isEnum`, `isProtocol`, `isStruct`, `isObjCSymbol`
  - `isOldFunctionTypeMangling`
- **`mangleNodeOld` free function** (used by the objc-runtime remangle path) is missing.

### Missing NodePrinter safeguards

- **Recursion limit and `<<too complex>>` marker** are absent. Upstream `NodePrinter` caps recursion depth and replaces the unreachable subtree with the literal text `<<too complex>>` (see `bigtype-demangle.txt`: `type metadata for (((…<<too complex>>…)))`). The Swift port has `maxDepth = 1024` protection only in `TypeDecoder` (`Main/TypeDecoder/TypeDecoder.swift:17`) and `Remangler` (`Main/Remangle/Remangler.swift:18`). Feeding `bigtype.txt` (`$sBf32__t_t_…_tN` with hundreds of repeated `_t`s) through `Node.print(...)` triggers a stack overflow rather than producing `<<too complex>>`. Consequence: the `bigtype*.txt` upstream test inputs cannot currently be wired into the test suite.

### Missing Node kinds

- `Node.Kind.preambleAttachedMacroExpansion` (Swift 6.1). Upstream: `NodePrinter.cpp:464,1594`; `DemangleNodes.def` preamble macro entry.

### `ManglingError` missing error codes

Upstream `ManglingError::Code` declares 24 variants. The Swift enum is missing 12:

`Uninitialized`, `NotAStorageNode`, `WrongNodeType`, `WrongDependentMemberType`, `BadDirectness`, `UnknownEncoding`, `InvalidImplDifferentiability`, `InvalidMetatypeRepresentation`, `MultiByteRelatedEntity`, `BadValueWitnessKind`, `NotAContextNode`, `AssertionFailed`.

The Swift port adds its own variants (`invalidGenericSignature`, `invalidDependentMemberType`, `missingChildNode`, `invalidNodeStructure`, `missingSymbolicResolver`, `indexOutOfBound`, `genericError`) which have no 1:1 upstream counterpart.

## 3b. Test coverage snapshot (2026-04-14)

Upstream test inputs are copied verbatim into `Tests/DemanglingTests/UpstreamInputs/` and driven through four parametrized Swift Testing suites (`SwiftUpstreamDemangleTests`, `SwiftUpstreamSimplifiedTests`, `SwiftUpstreamRemangleTests`, `SwiftUpstreamMiscTests`) plus their shared `SwiftUpstreamTestSupport`. The existing per-method `DemangleSwiftProjectDerivedTests` file is untouched.

| Suite | Source | Total | Pass | Fail |
|---|---|---|---|---|
| `Upstream: manglings.txt` | `manglings.txt` | 500 | 366 | 134 |
| `Upstream: simplified-manglings.txt` | `simplified-manglings.txt` | 217 | 175 | 42 |
| `Upstream: remangle roundtrip on manglings.txt` | `manglings.txt` filtered to `$s` / `$S` / `_$s` / `_$S` inputs | 191 | 176 | 15 |
| `Upstream: manglings-with-clang-types.txt` | `manglings-with-clang-types.txt` | 2 | 2 | 0 |
| `Upstream: standalone cases` | `demangle-embedded.swift` (`$e` prefix) | 1 | 1 | 0 |
| **Total** | | **911** | **720** | **191** |

Not yet wired:

- `bigtype.txt` / `bigtype-demangle.txt` / `bigtype-remangle.txt` / `bigtype-objcrt.txt` — blocked on the missing NodePrinter recursion limit (see section 3).
- `demangle-embedded.swift`'s second and third RUN lines (`e4main…` without `$`) — upstream `readManglingPrefix` tolerates a bare `e` prefix; the port does not.
- `remangle.swift`'s `-remangle-objc-rt` inputs — blocked on `OldRemangler` / `mangleNodeOld`.

Test canonicalization applied in `SwiftUpstreamRemangleTests.canonicalize`: strip leading `_`, lowercase `$S` → `$s`, prepend `_`. This absorbs gaps #14 (forced `_` prefix) and the `$S` → `$s` canonicalization the port already performs. Without this helper the suite would report ≥ 191 issues instead of 15.

## 4. Areas confirmed aligned

- `Node.Kind` enum (~294 kinds) is otherwise fully covered, including Swift 5.1–6.x features: async / isolated / sending / typed throws / `~Copyable` / `~Escapable` / macros / AutoDiff / extended existential shapes / lifetime dependence / `mutateAccessor` / `borrowAccessor` / `coroFunctionPointer` / `defaultOverride`.
- New Remangler (`$s`) covers all 378 upstream `mangleXxx` entry points. The only anomaly is one stale function name: Swift's `manglePredefinedObjCAsyncCompletionHandlerImpl` is the dispatch target for `.checkedObjCAsyncCompletionHandlerImpl`; the emitted bytes `TZ` match upstream so this is cosmetic.
- Substitution hash-based merging, Punycode encode/decode, TypeDecoder main flow, `ManglingFlavor`, and most of `NodePrinter`'s helper methods are structurally equivalent.

## 5. Recommended fix order

1. Group 1 items #1–#11 (Demangler correctness bugs, each 1–5 lines in a single file)
2. Group 1 items #12–#13 (NodePrinter `printConcreteProtocolConformance` + `.globalVariableOnceToken`)
3. Group 1 item #14 (decide whether `Remangler.mangleGlobal` should emit `_$s` or `$s`; if the port keeps `_$s`, document the intentional divergence instead of treating it as a bug) and #15 (substitution aggressiveness in stdlib paths)
4. Group 2 (wire the three `NodePrinter` options through)
5. Add `preambleAttachedMacroExpansion` kind + printer case
6. Add NodePrinter recursion limit + `<<too complex>>` marker so `bigtype.txt` can be wired in
7. Expand `ManglingError::Code` (add the 12 missing variants, then migrate callers)
8. Introduce a `Context` façade over the free functions
9. Flesh out `OldDemangler` coverage so the 130+ V1 `manglings.txt` failures turn green
10. Port `OldRemangler.cpp` (largest single item, only needed if V1 mangling output is required)
