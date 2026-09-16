public enum DyldSharedCachePath: String, CaseIterable {
    case current = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e"
    /// Built with Swift 6.4 — the first cache that can carry 6.4-only manglings
    /// (evolution 0015). Lives on the reverse-engineering volume, not the OS.
    case macOS_27_0 = "/Volumes/DyldSharedCaches/macOS/27.0/dyld_shared_cache_arm64e"
    case macOS_15_5 = "/Volumes/RE/Dyld-Shared-Cache/macOS/15.5/dyld_shared_cache_arm64e"
    case iOS_18_5 = "/Volumes/Generic/iOS Systems/22F76__iPhone17,5/dyld_shared_cache_arm64e"
    case iOS_26_1 = "/Volumes/Generic/iOS Systems/23B85__iPhone17,5/dyld_shared_cache_arm64e"

    /// The case whose name equals `name`, for selecting a corpus from an
    /// environment variable (`DEMANGLING_DYLD_CACHE=macOS_27_0`).
    public static func named(_ name: String) -> DyldSharedCachePath? {
        allCases.first { String(describing: $0) == name }
    }
}
