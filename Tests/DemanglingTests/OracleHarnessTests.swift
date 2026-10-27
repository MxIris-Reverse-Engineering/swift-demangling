import Testing
@testable import DemanglingTestingSupport

/// Ways the corpus oracles could report success while comparing against the
/// wrong referee or the wrong corpus.
@Suite("Oracle harness")
struct OracleHarnessTests {
    // An explicit DEVELOPER_DIR is the only place the toolchain demangler is
    // looked for. Falling back from it to /Applications/Xcode.app swapped in
    // Xcode 26.6's demangler, which rejects every Swift 6.4 mangling; the
    // oracle then skipped the tree check for all of those symbols and still
    // reported zero mismatches.
    @Test func explicitDeveloperDirectoryIsTheOnlyLibraryCandidate() {
        let candidates = ToolchainDemangler.candidateLibraryPaths(
            developerDirectory: "/Applications/Xcode-27.2.0.app/Contents/Developer"
        )
        #expect(candidates == [
            "/Applications/Xcode-27.2.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libswiftDemangle.dylib",
        ])
    }

    @Test(arguments: [nil, ""] as [String?])
    func withoutDeveloperDirectoryTheDefaultXcodeIsTriedFirst(developerDirectory: String?) {
        let candidates = ToolchainDemangler.candidateLibraryPaths(developerDirectory: developerDirectory)
        #expect(candidates == [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libswiftDemangle.dylib",
            "libswiftDemangle.dylib",
        ])
    }

    // A misspelled corpus name ran the whole oracle on the live cache and
    // reported its numbers as the requested corpus's.
    @Test func unknownCacheNameIsAnError() {
        #expect(throws: DyldSharedCachePath.UnknownName.self) {
            try DyldSharedCachePath.selected(by: ["DEMANGLING_DYLD_CACHE": "macOS_27"])
        }
    }

    @Test func unsetCacheVariableSelectsTheLiveCache() throws {
        #expect(try DyldSharedCachePath.selected(by: [:]) == .current)
    }

    @Test func cacheVariableSelectsTheNamedCache() throws {
        #expect(try DyldSharedCachePath.selected(by: ["DEMANGLING_DYLD_CACHE": "macOS_27_0"]) == .macOS_27_0)
    }
}
