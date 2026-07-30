// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LegadoKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "LegadoStoreSafeKit",
            targets: [
                "AppUseCases",
                "AppNavigation",
                "DatabaseGRDB",
                "HTMLSwiftSoup",
            ]
        ),
        .library(
            name: "LegadoFullCompatKit",
            targets: [
                "AppUseCases",
                "AppNavigation",
                "DatabaseGRDB",
                "ScriptJavaScriptCore",
                "HTMLSwiftSoup",
            ]
        ),
        .executable(name: "ConformanceCLI", targets: ["ConformanceCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            exact: "2.13.6"
        ),
    ],
    targets: [
        .target(name: "LegadoCore"),
        .target(name: "LibraryDomain", dependencies: ["LegadoCore"]),
        .target(name: "SourceFormat", dependencies: ["LegadoCore"]),
        .target(name: "RuleRuntime", dependencies: ["LegadoCore"]),
        .target(
            name: "HTMLSwiftSoup",
            dependencies: [
                "LegadoCore",
                "RuleRuntime",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .target(
            name: "SourceRuntime",
            dependencies: ["LegadoCore", "LibraryDomain", "SourceFormat", "RuleRuntime"]
        ),
        .target(
            name: "ScriptJavaScriptCore",
            dependencies: ["SourceRuntime"],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .target(name: "ReaderCore", dependencies: ["LegadoCore", "LibraryDomain"]),
        .target(
            name: "AppUseCases",
            dependencies: [
                "LegadoCore",
                "LibraryDomain",
                "SourceFormat",
                "SourceRuntime",
                "RuleRuntime",
                "ReaderCore",
            ]
        ),
        .target(
            name: "AppNavigation",
            dependencies: ["LegadoCore", "LibraryDomain"]
        ),
        .target(
            name: "DatabaseGRDB",
            dependencies: [
                "LegadoCore",
                "LibraryDomain",
                "AppUseCases",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
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
                "ReaderCore",
                "SourceFormat",
                "RuleRuntime",
                "SourceRuntime",
                "HTMLSwiftSoup",
                "TestSupport",
            ]
        ),
        .testTarget(name: "LegadoCoreTests", dependencies: ["LegadoCore"]),
        .testTarget(
            name: "SourceRuntimeTests",
            dependencies: ["LegadoCore", "SourceRuntime", "TestSupport"]
        ),
        .testTarget(
            name: "HTMLSwiftSoupTests",
            dependencies: ["HTMLSwiftSoup", "RuleRuntime"]
        ),
        .testTarget(
            name: "ScriptJavaScriptCoreTests",
            dependencies: ["ScriptJavaScriptCore", "SourceRuntime"]
        ),
        .testTarget(
            name: "ReaderCoreTests",
            dependencies: ["ReaderCore"]
        ),
        .testTarget(
            name: "LibraryDomainTests",
            dependencies: ["LibraryDomain"]
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
        .testTarget(
            name: "AppNavigationTests",
            dependencies: ["AppNavigation", "AppUseCases"]
        ),
        .testTarget(
            name: "DatabaseGRDBTests",
            dependencies: [
                "LibraryDomain",
                "AppUseCases",
                "DatabaseGRDB",
            ]
        ),
        .testTarget(
            name: "AppUseCasesTests",
            dependencies: ["AppUseCases", "ReaderCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
