import FoundationToolbox

/// Gives an adopting type an `os.Logger` / `OSLog` under this library's own
/// subsystem, so `#log` can be called from anywhere inside it.
///
/// Applied to a *protocol* rather than to each type directly, because the
/// types that need to report are generic. On a concrete type `@Loggable`
/// emits `static let` storage and Swift rejects stored statics inside a
/// generic type — `DemanglingPrinter<Target, SomeNode>` cannot carry the
/// macro itself. On a protocol the macro emits *computed* accessors backed by
/// `LoggableMacro`'s per-metatype cache instead, which a generic type may
/// hold, so conformance gets the printer what direct annotation could not.
///
/// `asProtocolRequirement: false` on purpose: nothing here is ever meant to be
/// overridden, and emitting real protocol requirements would put the accessors
/// behind a witness table. Every call site resolves statically to the default
/// implementation instead — the same static-dispatch property the store path
/// already relies on, chosen deliberately here rather than stumbled into.
///
/// The subsystem is spelled out rather than defaulted. `@Loggable`'s default
/// derives it from `Bundle.main.bundleIdentifier`, which in a library names
/// whichever app happens to be hosting us — the same diagnostic would land
/// under a different subsystem in every consumer, and no single
/// `log stream --subsystem` filter would find them all. A fixed string also
/// sidesteps a SILGen crash: emitting the defaulted `Bundle.main` accessor
/// crashes swift-frontend 6.3.3 while lowering the generated `subsystem`
/// getter.
@Loggable(
    .internal,
    asProtocolRequirement: false,
    subsystem: "com.mx-iris.swift-demangling",
    category: "Diagnostics"
)
protocol DemanglingLogging {}
