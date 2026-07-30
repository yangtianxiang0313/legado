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
                "SourceRuntimeComposition",
            ]
        ),
        .library(
            name: "LegadoFullCompatKit",
            targets: [
                "AppUseCases",
                "AppNavigation",
                "DatabaseGRDB",
                "SourceRuntimeComposition",
                "SourceScriptComposition",
            ]
        ),
        .executable(name: "ConformanceCLI", targets: ["ConformanceCLI"]),
    ],
    dependencies: [
        .package(path: "../LegadoCoreKit"),
        .package(path: "../LegadoSourceKit"),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
    ],
    targets: [
        .target(
            name: "LibraryDomain",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
            ]
        ),
        .target(
            name: "SourceRuntimeComposition",
            dependencies: [
                .product(
                    name: "LegadoHTMLSwiftSoupKit",
                    package: "LegadoSourceKit"
                ),
            ]
        ),
        .target(
            name: "SourceScriptComposition",
            dependencies: [
                .product(
                    name: "LegadoScriptJavaScriptCoreKit",
                    package: "LegadoSourceKit"
                ),
            ]
        ),
        .target(
            name: "ReaderCore",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "LibraryDomain",
            ]
        ),
        .target(
            name: "AppUseCases",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                .product(
                    name: "LegadoSourceRuntimeKit",
                    package: "LegadoSourceKit"
                ),
                "LibraryDomain",
                "ReaderCore",
            ]
        ),
        .target(
            name: "AppNavigation",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "LibraryDomain",
            ]
        ),
        .target(
            name: "DatabaseGRDB",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "LibraryDomain",
                "AppUseCases",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "TestSupport",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                .product(
                    name: "LegadoSourceRuntimeKit",
                    package: "LegadoSourceKit"
                ),
                "LibraryDomain",
                "ReaderCore",
                "AppUseCases",
            ]
        ),
        .executableTarget(
            name: "ConformanceCLI",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                .product(
                    name: "LegadoSourceFullCompatKit",
                    package: "LegadoSourceKit"
                ),
                "LibraryDomain",
                "ReaderCore",
                "TestSupport",
            ]
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
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "TestSupport",
            ]
        ),
        .testTarget(
            name: "ConformanceCLITests",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "ConformanceCLI",
                "TestSupport",
            ]
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
