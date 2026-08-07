// Proposal 0008 B2 acceptance harness: counts swift_retain/swift_release
// events targeting the frozen `NodeStore` during a print walk, comparing the
// ARC-free `UnretainedNodeReference` engine (what `NodeReference.print` runs)
// against the retained-handle engine (`DemanglingPrinter<String,
// NodeReference>`) on identical input.
//
// Requires the interpose dylib from `Scripts/RetainCounter/retain-counter.c`
// inserted at launch:
//
//   clang -dynamiclib Scripts/RetainCounter/retain-counter.c -o /tmp/claude/libretaincounter.dylib
//   DEMANGLING_RETAIN_HARNESS=1 swift build -c release --product RetainCountVerification --scratch-path <agent scratch>
//   DYLD_INSERT_LIBRARIES=/tmp/claude/libretaincounter.dylib <build dir>/RetainCountVerification [symbols file]
//
// Exit codes: 0 parity holds (unretained walk below 5% of the retained
// walk's store ARC traffic), 1 it does not, 2 the dylib was not inserted.

import Darwin
import Foundation
@_spi(Internals) import Demangling

typealias WatchFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias EventCountFunction = @convention(c) () -> UInt64

guard
    let watchSymbol = dlsym(dlopen(nil, RTLD_NOW), "retain_counter_watch"),
    let retainCountSymbol = dlsym(dlopen(nil, RTLD_NOW), "retain_counter_retains"),
    let releaseCountSymbol = dlsym(dlopen(nil, RTLD_NOW), "retain_counter_releases")
else {
    print("retain-counter dylib not loaded; insert it with DYLD_INSERT_LIBRARIES (see Scripts/RetainCounter/retain-counter.c)")
    exit(2)
}

let watch = unsafeBitCast(watchSymbol, to: WatchFunction.self)
let retainEvents = unsafeBitCast(retainCountSymbol, to: EventCountFunction.self)
let releaseEvents = unsafeBitCast(releaseCountSymbol, to: EventCountFunction.self)

let defaultSymbols = [
    "$s7SwiftUI4ViewPAAE4task8priority_QrScP_yyYaYbScMYccntF",
    "$s10Foundation4DataV15withUnsafeBytesyxxSWKXEKlF",
    "$s7Combine9PublisherPAAE4sink18receiveCompletion0C5ValueAA14AnyCancellableCyAA11SubscribersO0D0Oy_7FailureQZGc_y6OutputQZctF",
    "$s7SwiftUI18DynamicViewContentPAAE8onDelete7performQrys8IndexSetVcSg_tF",
    "$ss2eeoiySbx_xtSQRzlF",
    "$s8mangling0022egbpdajGbuEbxfgehfvwxnyyF",
    "$s3use1xAA3OfPVy3lib1GVyAA1fQryFQOyQo_GAjE1PAAxAeKHD1_AIHO_HCg_Gvp",
    "_$s9localtest5outeryyF11LocalStructL_V6methodyyF",
]

let symbols: [String]
if CommandLine.arguments.count > 1, let contents = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
    symbols = contents.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
} else {
    symbols = defaultSymbols
}

func buildStore(from symbols: [String]) -> (NodeStore, [NodeStore.NodeIndex]) {
    var builder = NodeStoreBuilder()
    let roots = symbols.compactMap { try? builder.demangle($0) }
    return (builder.freeze(), roots)
}

let (store, roots) = buildStore(from: symbols)
guard !roots.isEmpty else {
    print("no symbols demangled; nothing to measure")
    exit(1)
}

// Warm both engines so lazy runtime setup does not land in a window.
for root in roots {
    _ = store.reference(at: root).print(using: .default)
    _ = DemanglingPrinter<String, NodeReference>.print(store.reference(at: root), options: .default)
}

let storePointer = Unmanaged.passUnretained(store).toOpaque()
let passCount = 20

watch(storePointer)
for _ in 0 ..< passCount {
    for root in roots {
        _ = store.reference(at: root).print(using: .default)
    }
}
let unretainedWalkRetains = retainEvents()
let unretainedWalkReleases = releaseEvents()

watch(storePointer)
for _ in 0 ..< passCount {
    for root in roots {
        _ = DemanglingPrinter<String, NodeReference>.print(store.reference(at: root), options: .default)
    }
}
let retainedWalkRetains = retainEvents()
let retainedWalkReleases = releaseEvents()
watch(nil)

let walkCount = roots.count * passCount
print("""
[0008-retain-verification] symbols=\(roots.count) passes=\(passCount) (\(walkCount) walks)
[0008-retain-verification] unretained engine (NodeReference.print): store retains=\(unretainedWalkRetains) releases=\(unretainedWalkReleases) (\(String(format: "%.2f", Double(unretainedWalkRetains) / Double(walkCount))) per walk)
[0008-retain-verification] retained engine (DemanglingPrinter<String, NodeReference>): store retains=\(retainedWalkRetains) releases=\(retainedWalkReleases) (\(String(format: "%.2f", Double(retainedWalkRetains) / Double(walkCount))) per walk)
""")

if unretainedWalkRetains * 20 < retainedWalkRetains {
    print("[0008-retain-verification] PASS: unretained walk carries <5% of the retained walk's store ARC traffic")
    exit(0)
} else {
    print("[0008-retain-verification] FAIL: unretained walk still pays comparable store ARC traffic")
    exit(1)
}
