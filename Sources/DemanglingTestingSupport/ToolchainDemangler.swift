import Foundation
import DemanglingTestingSupportC

/// The toolchain's `libswiftDemangle.dylib`: the referee every oracle in this
/// package compares against.
///
/// `nil` from the comparison functions means "the toolchain does not demangle
/// this symbol" — which only holds when there was a toolchain to ask. Every
/// oracle therefore calls ``requireLoadedLibrary()`` before its first
/// comparison, and the comparison functions trap without a library rather than
/// answer `nil` for every symbol, which the oracles would count as passes.
public enum ToolchainDemangler {
    /// Where an Xcode toolchain keeps the library, relative to its developer
    /// directory.
    static let libraryPathInDeveloperDirectory = "/Toolchains/XcodeDefault.xctoolchain/usr/lib/libswiftDemangle.dylib"

    /// The developer directory tried when `DEVELOPER_DIR` is unset.
    static let defaultDeveloperDirectory = "/Applications/Xcode.app/Contents/Developer"

    /// The libraries to try, in order, for a `DEVELOPER_DIR` value.
    ///
    /// An explicit developer directory is the only candidate. Falling back from
    /// it to the default Xcode swapped in a different Swift's demangler without
    /// a word — Xcode 26.6's, which rejects every Swift 6.4 mangling, so the
    /// oracle skipped the tree check for all of those symbols and still
    /// reported zero mismatches. An empty value counts as unset.
    public static func candidateLibraryPaths(developerDirectory: String?) -> [String] {
        if let developerDirectory, !developerDirectory.isEmpty {
            return [developerDirectory + libraryPathInDeveloperDirectory]
        }
        return [defaultDeveloperDirectory + libraryPathInDeveloperDirectory, "libswiftDemangle.dylib"]
    }

    private static var developerDirectoryFromEnvironment: String? {
        ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    }

    /// The library that was loaded, or `nil` when no candidate could be.
    public static let loadedLibraryPath: String? = candidateLibraryPaths(
        developerDirectory: developerDirectoryFromEnvironment
    ).first { candidate in
        swift_demangle_loadLibrary(candidate)
    }

    /// Why an oracle cannot run.
    public struct LibraryUnavailable: Error, CustomStringConvertible {
        public let triedPaths: [String]

        public var description: String {
            "libswiftDemangle.dylib could not be loaded from \(triedPaths.joined(separator: ", ")); "
                + "point DEVELOPER_DIR at an Xcode whose toolchain ships it"
        }
    }

    /// The loaded library's path. Throws when no library could be loaded, so
    /// an oracle fails instead of comparing against nothing.
    @discardableResult
    public static func requireLoadedLibrary() throws -> String {
        guard let loadedLibraryPath else {
            throw LibraryUnavailable(triedPaths: candidateLibraryPaths(developerDirectory: developerDirectoryFromEnvironment))
        }
        return loadedLibraryPath
    }

    /// The node tree dump for `mangledName` — `swift-demangle --tree-only`
    /// without its header line — or `nil` when the toolchain does not
    /// demangle it.
    public static func nodeTree(for mangledName: String) -> String? {
        precondition(loadedLibraryPath != nil, missingLibraryMessage)
        return takeString(swift_demangle_getNodeTreeAsString(mangledName))
    }

    /// The text `swift-demangle` prints for `mangledName` by default
    /// (`DemangleOptions()` with type sugar), or `nil` when the toolchain does
    /// not demangle it.
    public static func demangledName(for mangledName: String) -> String? {
        precondition(loadedLibraryPath != nil, missingLibraryMessage)
        return takeString(swift_demangle_copyDemangledName(mangledName))
    }

    /// The text `swift-demangle -simplified` prints for `mangledName`
    /// (`DemangleOptions::SimplifiedUIDemangleOptions()`), or `nil` when the
    /// toolchain does not demangle it.
    public static func simplifiedDemangledName(for mangledName: String) -> String? {
        precondition(loadedLibraryPath != nil, missingLibraryMessage)
        return takeString(swift_demangle_copySimplifiedDemangledName(mangledName))
    }

    private static let missingLibraryMessage = "no libswiftDemangle.dylib is loaded, so every symbol would read as rejected by the toolchain; "
        + "call ToolchainDemangler.requireLoadedLibrary() before comparing"

    private static func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
