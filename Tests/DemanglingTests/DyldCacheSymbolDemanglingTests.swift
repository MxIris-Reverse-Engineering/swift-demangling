import Foundation
import Testing
import MachOKit
@testable import Demangling
@testable import DemanglingTestingSupport

@Suite
final class DyldCacheSymbolDemanglingTests: DyldCacheSymbolTests, DemanglingTests, @unchecked Sendable {
    @Test func main() async throws {
        try await mainTest()
    }
}
