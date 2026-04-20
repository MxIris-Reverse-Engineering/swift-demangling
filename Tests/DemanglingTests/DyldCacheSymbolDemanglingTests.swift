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

    @Test func demangle() async throws {
        let node = try await Demangling.demangleAsNode("_$sSis15WritableKeyPathCy17RealityFoundation23PhysicallyBasedMaterialVAE9BaseColorVGTHTm")
        node.description.print()
    }

    @Test func stdlib_demangleNodeTree() async throws {
        let mangledName = "_$s7SwiftUI11DisplayListV10PropertiesVs9OptionSetAAsAFP8rawValuex03RawI0Qz_tcfCTW"
        let demangleNodeTree = DemanglingTestingSupport.stdlib_demangleNodeTree(mangledName)
        let stdlibNodeDescription = try #require(demangleNodeTree)
        let node = try await demangleAsNode(mangledName)
        let swiftSectionNodeDescription = node.description + "\n"
        #expect(stdlibNodeDescription == swiftSectionNodeDescription)
    }
}
