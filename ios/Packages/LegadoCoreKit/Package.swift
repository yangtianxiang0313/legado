// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LegadoCoreKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LegadoCoreKit", targets: ["LegadoCore"]),
    ],
    targets: [
        .target(name: "LegadoCore"),
        .testTarget(name: "LegadoCoreTests", dependencies: ["LegadoCore"]),
    ],
    swiftLanguageModes: [.v6]
)
