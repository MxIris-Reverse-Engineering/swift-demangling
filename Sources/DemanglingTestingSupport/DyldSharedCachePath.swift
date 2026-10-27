public enum DyldSharedCachePath: String, CaseIterable, Sendable {
    case current = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e"
    /// Built with Swift 6.4 — the first cache that can carry 6.4-only manglings
    /// (evolution 0015). Lives on the reverse-engineering volume, not the OS.
    case macOS_27_0 = "/Volumes/DyldSharedCaches/macOS/27.0/dyld_shared_cache_arm64e"
    case macOS_15_5 = "/Volumes/DyldSharedCaches/macOS/15.5/dyld_shared_cache_arm64e"

    /// The case whose name equals `name`, for selecting a corpus from an
    /// environment variable (`DEMANGLING_DYLD_CACHE=macOS_27_0`).
    public static func named(_ name: String) -> DyldSharedCachePath? {
        allCases.first { String(describing: $0) == name }
    }

    /// The environment variable that selects the oracle's corpus.
    public static let selectionVariable = "DEMANGLING_DYLD_CACHE"

    /// A ``selectionVariable`` value that names no case.
    public struct UnknownName: Error, CustomStringConvertible {
        public let name: String

        public var description: String {
            "\(DyldSharedCachePath.selectionVariable)=\(name) names no cache; known names: "
                + DyldSharedCachePath.allCases.map { String(describing: $0) }.joined(separator: ", ")
        }
    }

    /// The cache `environment` selects: ``current`` when ``selectionVariable``
    /// is unset, otherwise the case it names.
    ///
    /// A name that matches no case throws. Falling back to ``current`` ran the
    /// whole oracle on the live cache and reported its numbers as the
    /// requested corpus's — `macOS_27` for `macOS_27_0` was enough.
    public static func selected(by environment: [String: String]) throws -> DyldSharedCachePath {
        guard let name = environment[selectionVariable] else {
            return .current
        }
        guard let path = named(name) else {
            throw UnknownName(name: name)
        }
        return path
    }
}
