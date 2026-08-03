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
                "IntegrationKit",
                "WebDAVFoundation",
                "ArchiveZIPFoundation",
                "AndroidBackupInterop",
                "BackupInteropUseCases",
                "SourceRuntimeComposition",
                "SourceNetworkComposition",
            ]
        ),
        .library(
            name: "LegadoFullCompatKit",
            targets: [
                "AppUseCases",
                "AppNavigation",
                "DatabaseGRDB",
                "IntegrationKit",
                "WebDAVFoundation",
                "ArchiveZIPFoundation",
                "AndroidBackupInterop",
                "BackupInteropUseCases",
                "SourceRuntimeComposition",
                "SourceScriptComposition",
                "SourceNetworkComposition",
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
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
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
                .product(
                    name: "LegadoXPathKannaKit",
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
            name: "SourceNetworkComposition",
            dependencies: [
                .product(
                    name: "LegadoSourceNetworkKit",
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
            name: "IntegrationKit",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
            ]
        ),
        .target(
            name: "WebDAVFoundation",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "IntegrationKit",
            ]
        ),
        .target(
            name: "ArchiveZIPFoundation",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "ReaderCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "AndroidBackupInterop",
            dependencies: [
                "ArchiveZIPFoundation",
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                .product(
                    name: "LegadoSourceFormatKit",
                    package: "LegadoSourceKit"
                ),
            ]
        ),
        .target(
            name: "BackupInteropUseCases",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "AndroidBackupInterop",
                "AppUseCases",
                "IntegrationKit",
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
                "IntegrationKit",
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
                "BackupInteropUseCases",
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
                "SourceRuntimeComposition",
                "SourceNetworkComposition",
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
                "BackupInteropUseCases",
                "DatabaseGRDB",
            ]
        ),
        .testTarget(
            name: "AppUseCasesTests",
            dependencies: ["AppUseCases", "ReaderCore"]
        ),
        .testTarget(
            name: "IntegrationKitTests",
            dependencies: ["IntegrationKit"]
        ),
        .testTarget(
            name: "WebDAVFoundationTests",
            dependencies: ["WebDAVFoundation", "IntegrationKit"]
        ),
        .testTarget(
            name: "ArchiveZIPFoundationTests",
            dependencies: ["ArchiveZIPFoundation"]
        ),
        .testTarget(
            name: "AndroidBackupInteropTests",
            dependencies: [
                "AndroidBackupInterop",
                "ArchiveZIPFoundation",
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                .product(
                    name: "LegadoSourceFormatKit",
                    package: "LegadoSourceKit"
                ),
            ]
        ),
        .testTarget(
            name: "BackupInteropUseCasesTests",
            dependencies: [
                "AndroidBackupInterop",
                "BackupInteropUseCases",
                "IntegrationKit",
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
