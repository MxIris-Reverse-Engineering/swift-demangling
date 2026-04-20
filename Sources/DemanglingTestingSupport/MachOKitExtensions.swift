import Foundation
import MachOKit

public enum DyldCacheImageSearchMode {
    case name(String)
    case path(String)
}

extension MachOFile {
    fileprivate func match(by mode: DyldCacheImageSearchMode) -> Bool {
        switch mode {
        case .name(let name):
            let fileName = URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent
            return fileName == name
        case .path(let path):
            return imagePath == path
        }
    }
}

extension DyldCache {
    public convenience init(path: DyldSharedCachePath) throws {
        try self.init(url: URL(fileURLWithPath: path.rawValue))
    }

    public func machOFile(by mode: DyldCacheImageSearchMode) -> MachOFile? {
        if let found = machOFiles().first(where: { $0.match(by: mode) }) {
            return found
        }

        guard let mainCache else { return nil }

        if let found = mainCache.machOFiles().first(where: { $0.match(by: mode) }) {
            return found
        }

        if let subCaches {
            for subCacheEntry in subCaches {
                if let subCache = try? subCacheEntry.subcache(for: mainCache),
                   let found = subCache.machOFiles().first(where: { $0.match(by: mode) }) {
                    return found
                }
            }
        }
        return nil
    }

    public func machOFile(named: MachOImageName) -> MachOFile? {
        machOFile(by: .name(named.rawValue))
    }
}

extension FullDyldCache {
    public convenience init(path: DyldSharedCachePath) throws {
        try self.init(url: URL(fileURLWithPath: path.rawValue))
    }

    public func machOFile(by mode: DyldCacheImageSearchMode) -> MachOFile? {
        machOFiles().first(where: { $0.match(by: mode) })
    }

    public func machOFile(named: MachOImageName) -> MachOFile? {
        machOFile(by: .name(named.rawValue))
    }
}

extension CustomStringConvertible {
    public func print() {
        #if !SILENT_TEST
        Swift.print(self)
        #endif
    }
}

extension Error {
    public func print() {
        #if !SILENT_TEST
        Swift.print(self)
        #endif
    }
}
