import Foundation
import Testing
import MachOKit
@testable import Demangling
@testable import DemanglingTestingSupport

@Suite
final class DyldCacheSymbolDemanglingTests: DyldCacheSymbolTests, DemanglingTests, @unchecked Sendable {
    /// `DEMANGLING_DYLD_CACHE=<case name>` runs the oracle over another corpus
    /// (`macOS_27_0` is the Swift 6.4-built cache); default is the live cache.
    override class var cachePath: DyldSharedCachePath {
        get throws { try DyldSharedCachePath.selected(by: ProcessInfo.processInfo.environment) }
    }

    @Test func main() async throws {
        try await mainTest()
    }
}
