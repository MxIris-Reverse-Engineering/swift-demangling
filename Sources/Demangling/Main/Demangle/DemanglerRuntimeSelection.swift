import Foundation
import SwiftStdlibToolbox

// Axis-1 (OS runtime) selection points for the byte-based demangler
// (proposal 0008): the entry fixes three choices once per demangle — input
// borrowing (`String.utf8Span` vs `withUTF8`), text materialization
// (revalidation-free copying vs decoding), and word-table storage
// (stack-resident `InlineArray` vs `ContiguousArray`) — and the shared
// scanning core runs branch-free on whatever was chosen. Availability is
// re-checked only inside `TextMaterializationStrategy.materialize`, where the
// language requires a static gate around the macOS 26 API; the strategy is
// only ever selected under the same gate, so the check never fails there.

/// Number of entries the identifier word-substitution table can hold, from
/// the mangling grammar (`a`–`z` back-references). `InlineWordRanges` spells
/// the value out literally because value-generic arguments cannot reference
/// a constant yet.
let maxNumWords = 26

/// Testability seam (proposal 0008, dual-path discipline 3): forces every
/// demangle entry onto the legacy (pre-macOS 26) runtime path — `withUTF8`
/// input borrowing, validating text materialization, heap-backed word table —
/// so one modern machine can cover both paths across the full corpus. Without
/// this, the legacy path would silently lose test coverage as new OS versions
/// become the norm.
@_spi(Internals)
public enum DemanglingRuntimePath {
    /// Seeded from `DEMANGLING_FORCE_LEGACY_PATH=1` so a CI double-run can
    /// force the legacy path for a whole test process without per-suite
    /// wiring; the SPI setter still overrides at runtime.
    private static let forcedLegacyPathStorage = Mutex(
        ProcessInfo.processInfo.environment["DEMANGLING_FORCE_LEGACY_PATH"] == "1"
    )

    /// When true, demangle entries behave as on a pre-macOS 26 runtime, and
    /// stores created while it is true snapshot legacy text materialization.
    /// Process-wide; the supported way to set it is the env var at process
    /// launch (CI double-runs).
    ///
    /// Do NOT flip this from a test mid-run: `.serialized` only orders tests
    /// within one suite, so a flipped seam drags every concurrently running
    /// suite onto the legacy path and non-deterministically un-covers the
    /// modern one — exactly how `DualPathParityTests` polluted the rest of
    /// the suite before it switched to calling
    /// `demangleAsNodeOnLegacyRuntimePath` directly (ReviewFindingsPR7 F12).
    /// This guard is documentation, not enforcement — it cannot stop a new
    /// call site; the reviewable surface is that no test in the repo assigns
    /// here.
    public static var forcesLegacyPath: Bool {
        get { forcedLegacyPathStorage.withLockUnchecked { $0 } }
        set { forcedLegacyPathStorage.withLockUnchecked { $0 = newValue } }
    }
}

/// How scanner byte ranges become `String`s. Fixed once at the demangle
/// entry; the demangling core never re-decides.
enum TextMaterializationStrategy: Sendable {
    /// The whole input is known ASCII (`UTF8Span.isKnownASCII` at the entry),
    /// so every byte subrange is valid UTF-8 on its own and materialization
    /// skips revalidation via `String(copying: UTF8Span(unchecked:))`.
    ///
    /// The ASCII precondition is load-bearing: a byte subrange of non-ASCII
    /// UTF-8 can split a scalar, and `unchecked` on such a slice would forge
    /// an invalid `String`. Selecting this case from anything but a
    /// known-ASCII entry is a soundness bug, not a performance choice.
    case prevalidatedCopying
    /// Baseline for legacy OS runtimes and non-ASCII inputs:
    /// `String(decoding:as: UTF8.self)` — validates, substituting U+FFFD for
    /// invalid sequences.
    case decoding

    func materialize(_ spanBytes: Span<UInt8>) -> String {
        switch self {
        case .prevalidatedCopying:
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
                return String(copying: UTF8Span(unchecked: spanBytes))
            }
            // Unreachable: the case is only selected under the same gate.
            return Self.decode(spanBytes)
        case .decoding:
            return Self.decode(spanBytes)
        }
    }

    /// Materializes bytes accumulated outside the input span (identifier
    /// assembly). The prevalidated case is sound there because every
    /// component is either an ASCII input range or the UTF-8 of an already
    /// valid `String` (punycode output), and concatenation preserves
    /// validity.
    func materialize(ownedBytes: [UInt8]) -> String {
        switch self {
        case .prevalidatedCopying:
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *) {
                return ownedBytes.withUnsafeBufferPointer { buffer in
                    String(copying: UTF8Span(unchecked: buffer.span))
                }
            }
            return String(decoding: ownedBytes, as: UTF8.self)
        case .decoding:
            return String(decoding: ownedBytes, as: UTF8.self)
        }
    }

    private static func decode(_ spanBytes: Span<UInt8>) -> String {
        spanBytes.withUnsafeBufferPointer { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }
}

/// Storage for the identifier word-substitution table: at most `maxNumWords`
/// ranges into the mangled input (the demangler materializes a word only when
/// a back-reference uses it, matching the C++ demangler's input-slice table).
/// Axis-1 storage selection point — the demangling core is generic over this
/// and unaware of the choice.
protocol WordRangeStorage {
    init()
    var count: Int { get }
    mutating func append(_ wordRange: Range<Int>)
    /// Returns nil when `index` is out of bounds (the demangler turns that
    /// into a parse failure).
    func range(at index: Int) -> Range<Int>?
    mutating func removeAll()
}

/// Modern-OS word table: a stack-resident fixed-capacity array, zero heap
/// allocation per demangle.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, macCatalyst 26.0, *)
struct InlineWordRanges: WordRangeStorage {
    private var storage = InlineArray<26, Range<Int>>(repeating: 0 ..< 0)
    private(set) var count = 0

    init() {}

    mutating func append(_ wordRange: Range<Int>) {
        precondition(count < maxNumWords, "word table overflow — appends must stay guarded by maxNumWords")
        storage[count] = wordRange
        count += 1
    }

    func range(at index: Int) -> Range<Int>? {
        guard index >= 0, index < count else { return nil }
        return storage[index]
    }

    mutating func removeAll() {
        count = 0
    }
}

/// Legacy-OS word table: heap-backed with reserved capacity, one allocation
/// per demangle that uses word substitutions.
struct ArrayWordRanges: WordRangeStorage {
    private var storage: ContiguousArray<Range<Int>>

    init() {
        storage = []
    }

    var count: Int { storage.count }

    mutating func append(_ wordRange: Range<Int>) {
        if storage.isEmpty {
            storage.reserveCapacity(maxNumWords)
        }
        storage.append(wordRange)
    }

    func range(at index: Int) -> Range<Int>? {
        guard index >= 0, index < storage.count else { return nil }
        return storage[index]
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }
}
