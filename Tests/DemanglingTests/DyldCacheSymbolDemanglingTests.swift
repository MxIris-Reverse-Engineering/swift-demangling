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
        if let name = ProcessInfo.processInfo.environment["DEMANGLING_DYLD_CACHE"],
           let path = DyldSharedCachePath.named(name) {
            return path
        }
        return .current
    }

    @Test func main() async throws {
        try await mainTest()
    }
}
