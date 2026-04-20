// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-demangling",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .macCatalyst(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Demangling",
            targets: ["Demangling"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Mx-Iris/FrameworkToolbox", from: "0.4.0"),
        .package(url: "https://github.com/MxIris-Reverse-Engineering/MachOKit.git", from: "0.46.100"),
    ],
    targets: [
        .target(
            name: "Demangling",
            dependencies: [
                .product(name: "FoundationToolbox", package: "FrameworkToolbox"),
            ]
        ),
        .target(
            name: "DemanglingTestingSupportC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DemanglingTestingSupport",
            dependencies: [
                "Demangling",
                "DemanglingTestingSupportC",
                .product(name: "MachOKit", package: "MachOKit"),
            ]
        ),
        .testTarget(
            name: "DemanglingTests",
            dependencies: [
                "Demangling",
                "DemanglingTestingSupport",
            ]
        ),
    ]
)
