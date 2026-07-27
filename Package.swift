// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let localEnvironment: [String: String] = {
    let localEnvironmentFilePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(".package.env")
        .path
    guard FileManager.default.fileExists(atPath: localEnvironmentFilePath),
          let contents = try? String(contentsOfFile: localEnvironmentFilePath, encoding: .utf8)
    else {
        return [:]
    }
    var environment: [String: String] = [:]
    for line in contents.components(separatedBy: .newlines) {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
            continue
        }
        let parts = trimmedLine.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        environment[key] = value
    }
    return environment
}()

func envEnable(_ key: String, default defaultValue: Bool = false) -> Bool {
    let value = localEnvironment[key] ?? Context.environment[key]
    guard let value else {
        return defaultValue
    }
    if value == "1" {
        return true
    } else if value == "0" {
        return false
    } else {
        return defaultValue
    }
}

let usingLocalDependencies = envEnable("USING_LOCAL_DEPENDENCIES")

extension Package.Dependency {
    enum LocalSearchPath {
        case package(path: String, isRelative: Bool, isEnabled: Bool = usingLocalDependencies, traits: Set<PackageDescription.Package.Dependency.Trait> = [.defaults])
    }

    static func package(local localSearchPaths: LocalSearchPath..., remote: Package.Dependency) -> Package.Dependency {
        let currentFilePath = #filePath
        let isClonedDependency = currentFilePath.contains("/checkouts/") ||
            currentFilePath.contains("/SourcePackages/") ||
            currentFilePath.contains("/.build/")

        if isClonedDependency {
            return remote
        }
        for local in localSearchPaths {
            switch local {
            case .package(let path, let isRelative, let isEnabled, let traits):
                guard isEnabled else { continue }
                let url = if isRelative {
                    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: #filePath))
                } else {
                    URL(fileURLWithPath: path)
                }

                if FileManager.default.fileExists(atPath: url.path) {
                    return .package(path: url.path, traits: traits)
                }
            }
        }
        return remote
    }
}

let package = Package(
    name: "swift-demangling",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .macCatalyst(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Demangling",
            targets: ["Demangling"],
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Mx-Iris/FrameworkToolbox",
            from: "0.5.5"
        ),
        .package(
            local: .package(
                path: "../MachOKit",
                isRelative: true,
            ),
            remote: .package(
                url: "https://github.com/MxIris-Reverse-Engineering/MachOKit",
                from: "0.50.100"
            ),
        ),
    ],
    targets: [
        .target(
            name: "Demangling",
            dependencies: [
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ],
        ),
        .target(
            name: "DemanglingTestingSupportC",
            publicHeadersPath: "include",
        ),
        .target(
            name: "DemanglingTestingSupport",
            dependencies: [
                "Demangling",
                "DemanglingTestingSupportC",
                .product(name: "MachOKit", package: "MachOKit"),
            ],
        ),
        .testTarget(
            name: "DemanglingTests",
            dependencies: [
                "Demangling",
                "DemanglingTestingSupport",
            ],
        ),
    ],
)
