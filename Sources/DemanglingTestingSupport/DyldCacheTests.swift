import Foundation
import Testing
import MachOKit

open class DyldCacheTests: @unchecked Sendable {
    public let mainCache: DyldCache

    public let subCache: DyldCache

    public let fullCache: FullDyldCache

    public let machOFileInMainCache: MachOFile

    public let machOFileInSubCache: MachOFile

    public let machOFileInCache: MachOFile

    open class var platform: MachOKit.Platform { .macOS }

    open class var mainCacheImageName: MachOImageName { .SwiftUI }

    open class var cacheImageName: MachOImageName { .AttributeGraph }

    open class var cachePath: DyldSharedCachePath { .current }

    public init() async throws {
        self.mainCache = try DyldCache(path: Self.cachePath)
        self.subCache = try required(mainCache.subCaches?.first?.subcache(for: mainCache))
        self.fullCache = try FullDyldCache(path: Self.cachePath)
        self.machOFileInCache = try #require(mainCache.machOFile(named: Self.cacheImageName))
        self.machOFileInMainCache = try #require(mainCache.machOFile(named: Self.mainCacheImageName))
        self.machOFileInSubCache = try #require(subCache.machOFiles().first(where: { _ in true }))
    }
}
