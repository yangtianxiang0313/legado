// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LegadoKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LegadoStoreSafeKit", targets: ["AppUseCases"]),
        .library(name: "LegadoFullCompatKit", targets: ["AppUseCases"]),
        .executable(name: "ConformanceCLI", targets: ["ConformanceCLI"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "LegadoCore"),
        .target(name: "LibraryDomain", dependencies: ["LegadoCore"]),
        .target(name: "SourceFormat", dependencies: ["LegadoCore"]),
        .target(name: "RuleRuntime", dependencies: ["LegadoCore"]),
        .target(
            name: "SourceRuntime",
            dependencies: ["LegadoCore", "LibraryDomain", "SourceFormat", "RuleRuntime"]
        ),
        .target(name: "ReaderCore", dependencies: ["LegadoCore", "LibraryDomain"]),
        .target(
            name: "AppUseCases",
            dependencies: ["LegadoCore", "LibraryDomain", "SourceRuntime", "ReaderCore"]
        ),
        .target(
            name: "TestSupport",
            dependencies: [
                "LegadoCore",
                "LibraryDomain",
                "SourceFormat",
                "RuleRuntime",
                "SourceRuntime",
                "ReaderCore",
                "AppUseCases",
            ]
        ),
        .executableTarget(
            name: "ConformanceCLI",
            dependencies: [
                "LegadoCore",
                "LibraryDomain",
                "SourceFormat",
                "RuleRuntime",
                "SourceRuntime",
                "TestSupport",
            ]
        ),
        .testTarget(name: "LegadoCoreTests", dependencies: ["LegadoCore"]),
        .testTarget(
            name: "SourceRuntimeTests",
            dependencies: ["LegadoCore", "SourceRuntime", "TestSupport"]
        ),
        .testTarget(
            name: "TestSupportTests",
            dependencies: ["LegadoCore", "TestSupport"]
        ),
        .testTarget(
            name: "ConformanceCLITests",
            dependencies: ["LegadoCore", "ConformanceCLI", "TestSupport"]
        ),
        .testTarget(
            name: "SourceFormatTests",
            dependencies: ["LegadoCore", "SourceFormat", "TestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
