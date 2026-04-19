# Alignment Gaps Group A Implementation Plan

> **Status:** Completed 2026-04-18 via PR #2 (merged into `main` at commit `b20b57f`). Final `swift test` issue count: **189** (baseline 191, −2). All 8 tasks landed; Task 7 received one follow-up refinement (`b8b4171 fix(Demangler): preserve type alongside label list in typeMangling`) that was not in the original plan.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 13 correctness bugs in Group A of `docs/alignment-gaps.md` (11 Demangler + 2 NodePrinter), reducing `UpstreamInputs/` failures below the 2026-04-14 baseline of 191 without introducing regressions in any other suite.

**Architecture:** Each bug is localized (1–10 lines in a single file, except #8 which introduces one helper). Fixes are grouped into 8 commits ordered by blast radius: 6 trivial single-line fixes are bundled into one commit for review efficiency; the remaining 7 fixes get independent commits so regressions are easy to bisect. All verification goes through the existing `SwiftUpstreamDemangleTests`, `SwiftUpstreamSimplifiedTests`, and `SwiftUpstreamRemangleTests` suites wired up in commit `144c131`; no new test infrastructure is needed.

**Tech Stack:** Swift 6.2, Swift Package Manager, Swift Testing (`@Suite`/`@Test`/`#expect`), `xcsift` for summarized output.

---

## File Structure

All edits are confined to four files plus optional unit-test additions:

- `Sources/Demangling/Main/Demangle/Demangler.swift` — host of bugs #1–#11 (all 11 Demangler items)
- `Sources/Demangling/Main/Remangle/Remangler.swift` — host of the Remangler side of #5
- `Sources/Demangling/Node/Printer/NodePrinter.swift` — host of bugs #12 and #13
- `Sources/Demangling/Node/NodeFactory.swift` — may drop 3 unused singletons after #4
- `Tests/DemanglingTests/` — add at most one focused unit test file for bugs not covered by the upstream corpus (#11)

## Test Strategy

The upstream corpus already exercises most bugs. Validation recipe:

```bash
swift test 2>&1 | tail -1
```

Expected pattern: `Test run with 363 tests in 15 suites failed after X.XXXs with N issues.`

Baseline (pre-plan): **`N = 191`**.

For each task: record `N_before` and `N_after`; require `N_after ≤ N_before`. A decrease confirms the fix is exercised; equality is acceptable only when the bug has no upstream coverage (documented per task).

When targeting a single suite for faster iteration:

```bash
swift test --filter "DemanglingTests.SwiftUpstreamDemangleTests" 2>&1 | tail -3
swift test --filter "DemanglingTests.SwiftUpstreamRemangleTests" 2>&1 | tail -3
```

---

## Task 0: Establish baseline

**Files:** none — read-only verification.

- [x] **Step 1: Record baseline failure count**

```bash
swift package update && swift test 2>&1 | tail -1
```

Expected: `Test run with 363 tests in 15 suites failed after X.XXXs with 191 issues.`

If the number is not 191, stop and reconcile with `docs/alignment-gaps.md` section 3b before starting Task 1.

- [x] **Step 2: Commit nothing — proceed to Task 1**

No files changed; no commit.

---

## Task 1: Batch six trivial single-line fixes (#1, #3, #5, #6, #9, #10)

These six bugs each touch 1–2 lines and are independent. Bundling them keeps the review surface small while still allowing clean bisection via the individual `fix:` bullets in the commit body.

**Files:**
- Modify: `Sources/Demangling/Main/Demangle/Demangler.swift:123-127,1410-1411,1715,2178-2184,2376,2687-2693`
- Modify: `Sources/Demangling/Main/Remangle/Remangler.swift:4004-4010`

- [x] **Step 1: Fix #1 — `nativePinningMutableAddressor` uppercase `P`**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` line 2376:

```diff
         case "a":
             switch try scanner.readScalar() {
             case "O": kind = .owningMutableAddressor
             case "o": kind = .nativeOwningMutableAddressor
-            case "p": kind = .nativePinningMutableAddressor
+            case "P": kind = .nativePinningMutableAddressor
             case "u": kind = .unsafeMutableAddressor
             default: throw failure
             }
```

Upstream: `swift/lib/Demangling/Demangler.cpp:4140` uses `'P'`.

- [x] **Step 2: Fix #3 — consume the `q` byte in KeyPath thunk helpers**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` line 1715:

```diff
         case "H",
              "h":
             let nodeKind: Node.Kind = c == "H" ? .keyPathEqualsThunkHelper : .keyPathHashThunkHelper
-            let isSerialized = scanner.peek() == "q"
+            let isSerialized = scanner.conditional(scalar: "q")
             var types = [Node]()
```

Upstream: `swift/lib/Demangling/Demangler.cpp:3110` calls `nextIf('q')`.

- [x] **Step 3: Fix #5 — stop the Remangler from negating an already-positive index**

Root cause: the Demangler stores the raw absolute value (e.g. `3`) in `.negativeInteger`. The Printer already renders it correctly as `"-\(index)"`. Only the Remangler wrongly re-applies two's-complement negation, producing `UInt64.max - 2` on the wire.

Edit `Sources/Demangling/Main/Remangle/Remangler.swift` line 4009:

```diff
     private mutating func mangleNegativeInteger(_ node: Node, depth: Int) throws(ManglingError) {
         guard let index = node.index else {
             throw .invalidNodeStructure(node, message: "NegativeInteger has no index")
         }
         append("$n")
-        mangleIndex(0 &- index)
+        mangleIndex(index)
     }
```

Validation-specific check: `$s$n3_SSBV` should round-trip to itself (not `_$s$n18446744073709551613_SSBV`). The line already appears in `UpstreamInputs/manglings.txt:493` under `SwiftUpstreamRemangleTests`.

- [x] **Step 4: Fix #6 — reverse `globalVariableOnceDeclList` children after popping**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` line 2182 (insertion only):

```diff
         case "Z",
              "z":
             var declChildren: [Node] = []
             while pop(kind: .firstElementMarker) != nil {
                 guard let identifier = pop(where: { $0.isDeclName }) else { throw failure }
                 declChildren.append(identifier)
             }
+            declChildren.reverse()
             let declList = Node.create(kind: .globalVariableOnceDeclList, children: declChildren)
             return try Node.create(kind: c == "Z" ? .globalVariableOnceFunction : .globalVariableOnceToken, children: [popContext(), declList])
```

Upstream: `swift/lib/Demangling/Demangler.cpp:3859-3869` walks popped vars in reverse.

- [x] **Step 5: Fix #9 — delete two stale `demangleMetatype` cases**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` lines 1410–1411 (deletion only):

```diff
         case "D": return try Node.create(kind: .typeMetadataDemanglingCache, child: require(pop(kind: .type)))
-        case "d": return try Node.create(kind: .typeMetadataDemanglingCache, child: require(pop(kind: .type)))
-        case "R": return try Node.create(kind: .typeMetadataMangledNameRef, child: require(pop(kind: .type)))
         case "f": return try Node.create(kind: .fullTypeMetadata, child: require(pop(kind: .type)))
```

Upstream: `swift/lib/Demangling/Demangler.cpp:2534-2633` has no `'d'` or `'R'` cases in `demangleMetatype`.

- [x] **Step 6: Fix #10 — treat embedded `\0` as symbol terminator in `parseAndPushNames`**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` lines 123–127:

```diff
     private mutating func parseAndPushNames() throws(DemanglingError) {
         while !scanner.isAtEnd {
+            if scanner.peek() == "\u{0}" { return }
             try nameStack.append(demangleOperator())
         }
     }
```

Upstream: `swift/lib/Demangling/Demangler.cpp:822-823` does `if (peekChar() == '\0') return true;`.

- [x] **Step 7: Run full test suite and verify no regression**

```bash
swift test 2>&1 | tail -1
```

Expected: issue count `≤ 191`. A decrease of 1–10 is expected (at minimum, the `$s$n3_SSBV` remangle round-trip should start passing).

- [x] **Step 8: Commit**

```bash
git add Sources/Demangling/Main/Demangle/Demangler.swift Sources/Demangling/Main/Remangle/Remangler.swift
git commit -m "$(cat <<'EOF'
fix(Demangler,Remangler): batch six single-line alignment bugs

Each bullet is a standalone upstream-alignment fix from
docs/alignment-gaps.md Group A.

- #1 nativePinningMutableAddressor: 'p' -> 'P' to match upstream 'aP'
  spelling (Demangler.cpp:4140).
- #3 keyPath{Equals,Hash}ThunkHelper: consume the 'q' byte with
  conditional(scalar:) instead of peek() so the next operator sees a
  fresh scanner position (Demangler.cpp:3110).
- #5 negativeInteger remangle: drop the stray '0 &- index' in
  mangleNegativeInteger so '$s\$n3_SSBV' round-trips to itself rather
  than '\$n18446744073709551613'.
- #6 globalVariableOnceDeclList: reverse popped decl children so they
  appear in source order (Demangler.cpp:3859-3869).
- #9 demangleMetatype: drop stale 'd' and 'R' subcases that have no
  upstream counterpart and shadowed valid inputs.
- #10 parseAndPushNames: stop at embedded NUL instead of throwing
  unexpectedError (Demangler.cpp:822-823).
EOF
)"
```

---

## Task 2: Fix #2 — `demangleWitness` "O" inner "B" double-pop

**Files:**
- Modify: `Sources/Demangling/Main/Demangle/Demangler.swift:2140-2175`

Root cause: the outer `case "O"` pre-pops `(type, sig)` into `children`, but the inner `case "B"` pops them again, consuming two extra stack entries. Every other inner case already reuses `children`; only `"B"` is inconsistent.

- [x] **Step 1: Edit the inner `case "B"` to reuse `children`**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` lines 2145–2151:

```diff
             switch try scanner.readScalar() {
             case "B":
-                let type = try require(pop(kind: .type))
-                if let sig = pop(kind: .dependentGenericSignature) {
-                    return Node.create(kind: .outlinedInitializeWithTakeNoValueWitness, children: [type, sig])
-                } else {
-                    return Node.create(kind: .outlinedInitializeWithTakeNoValueWitness, children: [type])
-                }
+                return Node.create(kind: .outlinedInitializeWithTakeNoValueWitness, children: children)
             case "C": return Node.create(kind: .outlinedInitializeWithCopyNoValueWitness, children: children)
```

- [x] **Step 2: Run tests**

```bash
swift test --filter "DemanglingTests.SwiftUpstreamDemangleTests" 2>&1 | tail -3
```

Expected: the suite's failure count decreases by the number of `WOB…` inputs in `UpstreamInputs/manglings.txt`, or stays flat. No other suite should regress.

```bash
swift test 2>&1 | tail -1
```

Expected: issue count `≤ Task 1 result`.

- [x] **Step 3: Commit**

```bash
git add Sources/Demangling/Main/Demangle/Demangler.swift
git commit -m "fix(Demangler): stop double-popping in demangleWitness O/B

The outer 'O' case pre-pops (type, sig) into 'children' for every
inner sub-case; only 'B' incorrectly popped them again. Reuse
'children' so 'B' behaves like its siblings and the stack is
consumed exactly once (Demangler.cpp:3724-3855)."
```

---

## Task 3: Fix #7 — `demangleOperator` must skip 0xFF alignment-padding bytes

**Files:**
- Modify: `Sources/Demangling/Main/Demangle/Demangler.swift:162-178`

Root cause: symbolic references emit a `0xFF` byte as alignment padding before the payload. Upstream `Demangler.cpp:1029-1033` recurses on this byte. The Swift port never handles it, so any mangled symbol with an aligned symbolic reference throws at the first `0xFF` encounter.

- [x] **Step 1: Add a loop that skips 0xFF before the switch**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` lines 162–164:

```diff
     private mutating func demangleOperator() throws(DemanglingError) -> Node {
-        let scalar = try scanner.readScalar()
+        var scalar = try scanner.readScalar()
+        while scalar.value == 0xFF {
+            scalar = try scanner.readScalar()
+        }
         switch scalar {
```

- [x] **Step 2: Run tests**

```bash
swift test 2>&1 | tail -1
```

Expected: issue count `≤ Task 2 result`. Aligned symbolic references do not appear in the plain-text `UpstreamInputs/manglings.txt` corpus (they require binary 0xFF bytes), so the count is likely flat. This fix unblocks downstream consumers that feed binary-encoded symbols through the demangler.

- [x] **Step 3: Commit**

```bash
git add Sources/Demangling/Main/Demangle/Demangler.swift
git commit -m "fix(Demangler): skip 0xFF alignment padding in demangleOperator

Aligned symbolic references prefix their payload with a 0xFF byte;
the upstream compiler recurses on this byte (Demangler.cpp:1029-1033).
The Swift port now mirrors that behavior so binary-encoded inputs
don't trip unexpectedError on the padding."
```

---

## Task 4: Fix #12 — `printConcreteProtocolConformance` index spacing

**Files:**
- Modify: `Sources/Demangling/Node/Printer/NodePrinter.swift:886-898`

Root cause: the printer emits `" #N"` (leading space, no trailing space) while upstream `NodePrinter.cpp:3261` emits `"#N "` (no leading space, trailing space). Because the subsequent `target.write(" to ")` already starts with a space, the result has a double-space gap and no space after the index.

- [x] **Step 1: Move the space to the trailing side**

Edit `Sources/Demangling/Node/Printer/NodePrinter.swift` lines 886–890:

```diff
     private mutating func printConcreteProtocolConformance(_ name: Node) {
         target.write("concrete protocol conformance ")
         if let index = name.index {
-            target.write(" #\(index)")
+            target.write("#\(index) ")
         }
         printFirstChild(name)
```

- [x] **Step 2: Run tests**

```bash
swift test --filter "DemanglingTests.SwiftUpstreamDemangleTests" 2>&1 | tail -3
```

Expected: any `HC…` conformance cases in `manglings.txt` that previously failed on the `" #"` / `"# "` discrepancy now pass. Issue count `≤ Task 3 result`.

- [x] **Step 3: Commit**

```bash
git add Sources/Demangling/Node/Printer/NodePrinter.swift
git commit -m "fix(NodePrinter): concrete protocol conformance index spacing

Upstream formats the optional index as '#N ' (trailing space) so the
following ' to ' separator renders with a single gap. The port wrote
' #N', producing '  #N to' with a double space and no trailing space
(NodePrinter.cpp:3261)."
```

---

## Task 5: Fix #13 — `globalVariableOnceToken` must route through `printEntity`

**Files:**
- Modify: `Sources/Demangling/Node/Printer/NodePrinter.swift:239,1269-1277`

Root cause: upstream treats `globalVariableOnceToken` as a plain entity (no prefix text); the port falls through to `printGlobalVariableOnceFunction`, which prepends `"one-time initialization token for "`. Remove the dispatch to that helper and let the default entity path handle it.

- [x] **Step 1: Split the shared dispatch and route the token through `printEntity`**

Edit `Sources/Demangling/Node/Printer/NodePrinter.swift` lines 238–239:

```diff
-        case .globalVariableOnceFunction,
-             .globalVariableOnceToken: printGlobalVariableOnceFunction(name)
+        case .globalVariableOnceFunction: printGlobalVariableOnceFunction(name)
+        case .globalVariableOnceToken: return printEntity(name, asPrefixContext: asPrefixContext, typePrinting: .withColon, hasName: true)
```

Rationale: upstream treats `globalVariableOnceToken` as a variable-like entity (`NodePrinter.cpp:599`). The `printEntity(..., typePrinting: .withColon, hasName: true)` call mirrors the handling already used by `case .variable` at `NodePrinter.swift:473`.

- [x] **Step 2: Simplify `printGlobalVariableOnceFunction` (remove dead branch)**

Since the helper is now only called for `globalVariableOnceFunction`, simplify its prefix to the unconditional string. Edit `NodePrinter.swift:1269-1277`:

```diff
     private mutating func printGlobalVariableOnceFunction(_ name: Node) {
-        target.write(name.kind == .globalVariableOnceToken ? "one-time initialization token for " : "one-time initialization function for ")
+        target.write("one-time initialization function for ")
         if let firstChild = name.children.first {
             _ = shouldPrintContext(firstChild)
         }
```

- [x] **Step 3: Run tests**

```bash
swift test 2>&1 | tail -1
```

Expected: issue count `≤ Task 4 result`. `Wz…` tokens in the corpus now render as plain entities.

- [x] **Step 4: Commit**

```bash
git add Sources/Demangling/Node/Printer/NodePrinter.swift
git commit -m "fix(NodePrinter): route globalVariableOnceToken through printEntity

Upstream treats 'Wz' tokens as plain entities with no verbal prefix
(NodePrinter.cpp:599). Dropping the shared case keeps
printGlobalVariableOnceFunction focused on the 'Z' variant."
```

---

## Task 6: Fix #4 — sugared `Sq` / `Sa` / `Sp` must pop element type

**Files:**
- Modify: `Sources/Demangling/Main/Demangle/Demangler.swift:2297-2311`
- Optional: `Sources/Demangling/Node/NodeFactory.swift:299-301,407-409` (remove unused singletons once call sites are gone)

Root cause: the three sugared cases return the childless `NodeFactory` singletons, silently dropping the element `.type` child that the rest of the pipeline expects. The printer then renders `[]`, `()`, or `Optional<>` with no inner type.

- [x] **Step 1: Rewrite the three affected cases**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` lines 2299–2305:

```diff
         case "S":
             switch try scanner.readScalar() {
-            case "q": return Node.create(kind: .type, child: NodeFactory.sugaredOptional)
-            case "a": return Node.create(kind: .type, child: NodeFactory.sugaredArray)
+            case "q":
+                let elementType = try require(pop(kind: .type))
+                return Node.create(kind: .type, child: Node.create(kind: .sugaredOptional, child: elementType))
+            case "a":
+                let elementType = try require(pop(kind: .type))
+                return Node.create(kind: .type, child: Node.create(kind: .sugaredArray, child: elementType))
             case "D":
                 let value = try require(pop(kind: .type))
                 let key = try require(pop(kind: .type))
                 return Node.create(kind: .type, child: Node.create(kind: .sugaredDictionary, children: [key, value]))
-            case "p": return Node.create(kind: .type, child: NodeFactory.sugaredParen)
+            case "p":
+                let elementType = try require(pop(kind: .type))
+                return Node.create(kind: .type, child: Node.create(kind: .sugaredParen, child: elementType))
             case "A":
```

Upstream reference: `Demangler.cpp:4025-4045` pops `Kind::Type` as a child for each.

- [x] **Step 2: Verify the three `NodeFactory` singletons are no longer referenced**

```bash
rg -n "NodeFactory\.sugaredOptional|NodeFactory\.sugaredArray|NodeFactory\.sugaredParen"
```

Expected: no results. If any remain, leave the singletons in place; otherwise delete them in Step 3.

- [x] **Step 3: Remove the unused singletons from `NodeFactory.swift` (only if Step 2 is clean)**

Edit `Sources/Demangling/Node/NodeFactory.swift` — delete the three `public static let sugared{Optional,Array,Paren}` declarations (around lines 407–409) and their entries in the factory enumeration list (around lines 299–301). Preserve `sugaredDictionary` and `sugaredInlineArray`, which do have children set at call sites.

- [x] **Step 4: Run tests**

```bash
swift test 2>&1 | tail -1
```

Expected: issue count decreases noticeably — every `Sq…`, `Sa…`, `Sp…` input that the corpus contains should now round-trip cleanly.

- [x] **Step 5: Commit**

```bash
git add Sources/Demangling/Main/Demangle/Demangler.swift Sources/Demangling/Node/NodeFactory.swift
git commit -m "fix(Demangler): Sq/Sa/Sp must attach element type as child

The sugared Optional / Array / Paren branches returned the
childless NodeFactory singletons, silently dropping the popped
element .type child (Demangler.cpp:4025-4045). Now each branch
pops the element type and wraps it inside the sugared node, so
the printer renders 'T?', '[T]', and '(T)' correctly.

Drop the three unused NodeFactory singletons now that nothing
references them."
```

---

## Task 7: Fix #8 — `case "D"` must run `popFunctionParamLabels`

**Files:**
- Modify: `Sources/Demangling/Main/Demangle/Demangler.swift:182` and add one new private method inside the same `Demangler` struct.

Root cause: the upstream `case 'D'` routes through `demangleTypeMangling()`, which pops the type and then calls `popFunctionParamLabels` to re-attach any label list previously pushed by `case 'y'`. The port short-circuits this to a bare `Node.create`, so function types in `D`-prefixed global symbols lose their parameter labels.

- [x] **Step 1: Replace the inline `case "D"` with a helper call**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` line 182:

```diff
         case "C": return try demangleAnyGenericType(kind: .class)
-        case "D": return try Node.create(kind: .typeMangling, child: require(pop(kind: .type)))
+        case "D": return try demangleTypeMangling()
         case "E": return try demangleExtensionContext()
```

- [x] **Step 2: Add the helper near the other `demangleX` private methods**

`popFunctionParamLabels` already exists at `Demangler.swift:368`. Add the new helper inside the same struct (adjacent to other private mangling helpers):

```swift
    private mutating func demangleTypeMangling() throws(DemanglingError) -> Node {
        let type = try require(pop(kind: .type))
        let labeled = try popFunctionParamLabels(type: type) ?? type
        return Node.create(kind: .typeMangling, child: labeled)
    }
```

Upstream reference: `swift/lib/Demangling/Demangler.cpp:907-915`.

- [x] **Step 3: Run tests**

```bash
swift test 2>&1 | tail -1
```

Expected: issue count `≤ Task 6 result`. Any symbol with `$sD` containing a labeled function type should now demangle with labels intact.

- [x] **Step 4: Commit**

```bash
git add Sources/Demangling/Main/Demangle/Demangler.swift
git commit -m "fix(Demangler): route 'D' typeMangling through popFunctionParamLabels

Upstream's demangleTypeMangling() pops the type *and* re-attaches
any function-param-label list pushed earlier by case 'y'
(Demangler.cpp:907-915). Extracting a helper mirrors the upstream
shape and restores labels on D-prefixed type manglings."
```

---

## Task 8: Fix #11 — set `flavor = .embedded` for `$e` / `_$e` prefixes

**Files:**
- Modify: `Sources/Demangling/Main/Demangle/Demangler.swift:49-59`
- Create: `Tests/DemanglingTests/EmbeddedFlavorTests.swift` (new focused test because upstream corpus only exercises demangle output, not the internal `flavor` field)

Root cause: `readManglingPrefix` accepts `$e` and `_$e` but never updates the `flavor: ManglingFlavor` field, so embedded-specific behavior downstream (the `if flavor == .embedded` checks that the rest of the demangler performs) is effectively dead code.

- [x] **Step 1: Write a failing unit test**

Create `Tests/DemanglingTests/EmbeddedFlavorTests.swift`:

```swift
import Testing
@testable import Demangling

@Suite("Embedded flavor detection")
struct EmbeddedFlavorTests {
    @Test("$e prefix sets flavor to .embedded")
    func dollarEPrefixSetsEmbeddedFlavor() throws {
        var demangler = Demangler(scalars: "$e4main4testyyF".unicodeScalars)
        _ = try demangler.demangleSymbol()
        #expect(demangler.flavor == .embedded)
    }

    @Test("_$e prefix sets flavor to .embedded")
    func underscoreDollarEPrefixSetsEmbeddedFlavor() throws {
        var demangler = Demangler(scalars: "_$e4main4testyyF".unicodeScalars)
        _ = try demangler.demangleSymbol()
        #expect(demangler.flavor == .embedded)
    }

    @Test("$s prefix keeps flavor at .default")
    func dollarSPrefixKeepsDefaultFlavor() throws {
        var demangler = Demangler(scalars: "$s4main4testyyF".unicodeScalars)
        _ = try demangler.demangleSymbol()
        #expect(demangler.flavor == .default)
    }
}
```

Note: `flavor` is currently `private`. If the test cannot reach it via `@testable import`, promote it to `internal` with an explanatory comment — `private` → `internal` is the smallest visibility change that makes the field testable without exposing it publicly.

- [x] **Step 2: Run the new test to confirm it fails**

```bash
swift test --filter "DemanglingTests.EmbeddedFlavorTests" 2>&1 | tail -5
```

Expected: two failures on the `$e` / `_$e` tests (flavor stays `.default`). The third test passes by coincidence.

- [x] **Step 3: Fix `readManglingPrefix`**

Edit `Sources/Demangling/Main/Demangle/Demangler.swift` lines 49–59:

```diff
     private mutating func readManglingPrefix() throws(DemanglingError) {
-        let prefixes = [
-            "_T0", "$S", "_$S", "$s", "_$s", "$e", "_$e", "@__swiftmacro_",
-        ]
-        for prefix in prefixes {
-            if scanner.conditional(string: prefix) {
-                return
-            }
-        }
+        let prefixTable: [(prefix: String, flavor: ManglingFlavor?)] = [
+            ("_T0", nil),
+            ("$S", nil),
+            ("_$S", nil),
+            ("$s", nil),
+            ("_$s", nil),
+            ("$e", .embedded),
+            ("_$e", .embedded),
+            ("@__swiftmacro_", nil),
+        ]
+        for (prefix, prefixFlavor) in prefixTable {
+            if scanner.conditional(string: prefix) {
+                if let prefixFlavor {
+                    flavor = prefixFlavor
+                }
+                return
+            }
+        }
         throw scanner.unexpectedError()
     }
```

Upstream reference: `swift/lib/Demangling/Demangler.cpp:759-760`.

- [x] **Step 4: Run the new test to confirm it passes**

```bash
swift test --filter "DemanglingTests.EmbeddedFlavorTests" 2>&1 | tail -5
```

Expected: all three tests pass.

- [x] **Step 5: Run the full suite to confirm no regression**

```bash
swift test 2>&1 | tail -1
```

Expected: issue count `≤ Task 7 result`. The existing `$e` test in `demangle-embedded.swift` should stay green.

- [x] **Step 6: Commit**

```bash
git add Sources/Demangling/Main/Demangle/Demangler.swift Tests/DemanglingTests/EmbeddedFlavorTests.swift
git commit -m "fix(Demangler): $e/_$e prefixes now set flavor to .embedded

readManglingPrefix accepted the embedded prefixes but left 'flavor'
at .default, so every 'flavor == .embedded' branch downstream was
dead code (Demangler.cpp:759-760). Add a prefix/flavor table plus
EmbeddedFlavorTests covering both variants and the default case."
```

---

## Global Verification

- [x] **Step 1: Re-run the full suite and compare against baseline**

```bash
swift test 2>&1 | tail -1
```

Expected: issue count strictly less than 191. Record the new number in the PR description.

- [x] **Step 2: Run a direct round-trip smoke test for #5**

```bash
swift test --filter "DemanglingTests.SwiftUpstreamRemangleTests" 2>&1 | tail -3
```

Expected: the remangle suite reports a lower failure count than the pre-plan 15. At minimum, `$s$n3_SSBV` should no longer produce the `18446744073709551613` round-trip artefact.

- [x] **Step 3: Open a PR referencing this plan**

```bash
gh pr create --base main --title "fix: alignment-gaps Group A (13 correctness bugs)" --body "$(cat <<'EOF'
## Summary
Implements `docs/superpowers/plans/2026-04-18-alignment-gaps-group-a.md`, fixing 11 Demangler bugs and 2 NodePrinter bugs identified in `docs/alignment-gaps.md` Group A.

## Test plan
- [x] `swift test` issue count drops from 191 baseline to < 191
- [x] `SwiftUpstreamRemangleTests` failures drop (at minimum `\$s\$n3_SSBV` round-trips)
- [x] `EmbeddedFlavorTests` passes (new)
EOF
)"
```

---

## Open Items Deferred

Out of scope for this plan (tracked in `docs/alignment-gaps.md`):
- **#14** `_$s` vs `$s` prefix decision (policy, not bug)
- **#15** Remangler substitution aggressiveness for stdlib paths
- **Section 2** three unimplemented `DemangleOptions` flags
- **Section 3** `preambleAttachedMacroExpansion` kind, NodePrinter recursion limit, `ManglingError` expansion, `Context` façade, `OldDemangler` / `OldRemangler`

## Self-Review Notes

- **Spec coverage:** All 13 bugs from `docs/alignment-gaps.md` section 1 Demangler + NodePrinter tables have a dedicated task (Task 1 bundles 6 trivial, Tasks 2–7 each fix one, Task 8 fixes #11 with a new test).
- **Placeholder scan:** Every code step has concrete diffs or complete new-file contents. No "TBD" / "handle appropriately" remain.
- **Type consistency:** `ManglingFlavor` cases (`.default`, `.embedded`) and `Node.Contents.index: UInt64` match the current source tree as of commit `144c131`.
