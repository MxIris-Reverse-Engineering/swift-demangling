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

/// Opt-in acceptance harness for proposal 0008 B2 (store print walk must not
/// retain/release the store per visited child). Gated behind an environment
/// flag so ordinary consumers never see the extra executable; see
/// `Sources/RetainCountVerification/main.swift` for the run recipe.
let buildingRetainCountVerification = envEnable("DEMANGLING_RETAIN_HARNESS")

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
                .product(name: "SwiftStdlibToolbox", package: "FrameworkToolbox"),
            ],
            swiftSettings: [
                // Proposal 0008: the byte-based demangler stores Span<UInt8>
                // in its ~Escapable scanner, which requires lifetime
                // dependence support; @_lifetime-based direct-return borrowed
                // views are additionally gated by #if hasFeature(Lifetimes)
                // at each use site. Compilers that do not know the feature
                // name ignore the flag (verified on 6.3.3) — the module then
                // fails on the Span stored property, so the effective
                // compiler floor is a Lifetimes-capable toolchain.
                .enableExperimentalFeature("Lifetimes"),
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
            resources: [
                // Upstream's manglings.txt at swift-6.4.0-RELEASE, read by
                // UpstreamManglingsTests.
                .copy("Resources/manglings.txt"),
            ],
            swiftSettings: [
                // Must mirror the Demangling target: #if hasFeature(Lifetimes)
                // tests compile out silently when the flag is missing here,
                // leaving the direct-return borrowed views with zero coverage
                // while the suite stays green (ReviewFindingsPR7 F3). Guarded
                // by BorrowedTextViewTests.lifetimesFeatureIsEnabledInTestTarget.
                .enableExperimentalFeature("Lifetimes"),
            ],
        ),
    ] + (buildingRetainCountVerification ? [
        .executableTarget(
            name: "RetainCountVerification",
            dependencies: ["Demangling"],
        ),
    ] : []),
)

// MARK: - Upcoming features

// Every Swift target adopts three upcoming features that Swift 7 turns on:
// ExistentialAny, MemberImportVisibility and InferIsolatedConformances.
// MachOSwiftSection's proposal swift6-mode-and-upcoming-features covers the
// MachO packages together.
let upcomingFeatureSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + upcomingFeatureSettings
}

// MARK: - Tuist development workspace

// MachOSwiftSection's Tuist development workspace (its Documentations/Internal/TuistDevelopment.md)
// maps this package's tests with Tuist, which rejects shapes SwiftPM accepts: a test that depends on
// an executable target or on a macro target (Tuist builds a macro as a plugin, so `@testable import`
// of it finds no module), and a test that depends on a target no product contains. Only while Tuist
// resolves the packages, with TUIST_MAPS_LOCAL_PACKAGE_TESTS=1, the first kinds are left out — the
// macro expansion tests then run under `swift test` only — and the last kind gets a library product
// of its own. Nothing changes without the variable.
if Context.environment["TUIST_MAPS_LOCAL_PACKAGE_TESTS"] == "1" {
    let executableOrMacroTargetNames = Set(package.targets.filter { $0.type == .executable || $0.type == .macro }.map(\.name))
    func dependencyName(_ dependency: Target.Dependency) -> String? {
        switch dependency {
        case .targetItem(let name, _), .byNameItem(let name, _):
            return name
        default:
            return nil
        }
    }
    package.targets.removeAll { target in
        target.type == .test && target.dependencies.contains { dependency in
            dependencyName(dependency).map(executableOrMacroTargetNames.contains) ?? false
        }
    }
    let productTargetNames = Set(package.products.flatMap { product in (product as? Product.Library)?.targets ?? [] })
    let testDependencyNames = Set(package.targets.filter { $0.type == .test }.flatMap { $0.dependencies.compactMap(dependencyName) })
    package.products += package.targets
        .filter { target in target.type == .regular && testDependencyNames.contains(target.name) && !productTargetNames.contains(target.name) }
        .map { target in Product.library(name: target.name, targets: [target.name]) }
}
