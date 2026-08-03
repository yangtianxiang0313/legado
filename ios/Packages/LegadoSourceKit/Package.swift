// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LegadoSourceKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "LegadoSourceFormatKit",
            targets: ["SourceFormat"]
        ),
        .library(
            name: "LegadoSourceRuntimeKit",
            targets: [
                "SourceFormat",
                "RuleRuntime",
                "SourceRuntime",
            ]
        ),
        .library(
            name: "LegadoHTMLSwiftSoupKit",
            targets: ["HTMLSwiftSoup"]
        ),
        .library(
            name: "LegadoScriptJavaScriptCoreKit",
            targets: ["ScriptJavaScriptCore"]
        ),
        .library(
            name: "LegadoSourceNetworkKit",
            targets: ["NetworkFoundation"]
        ),
        .library(
            name: "LegadoSourceStoreSafeKit",
            targets: [
                "SourceFormat",
                "RuleRuntime",
                "SourceRuntime",
                "HTMLSwiftSoup",
            ]
        ),
        .library(
            name: "LegadoSourceFullCompatKit",
            targets: [
                "SourceFormat",
                "RuleRuntime",
                "SourceRuntime",
                "HTMLSwiftSoup",
                "ScriptJavaScriptCore",
            ]
        ),
    ],
    dependencies: [
        .package(path: "../LegadoCoreKit"),
        .package(
            url: "https://github.com/scinfu/SwiftSoup.git",
            exact: "2.13.6"
        ),
    ],
    targets: [
        .target(
            name: "SourceFormat",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
            ]
        ),
        .target(
            name: "RuleRuntime",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
            ]
        ),
        .target(
            name: "SourceRuntime",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "SourceFormat",
                "RuleRuntime",
            ]
        ),
        .target(
            name: "HTMLSwiftSoup",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "RuleRuntime",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .target(
            name: "ScriptJavaScriptCore",
            dependencies: ["SourceRuntime"],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .target(
            name: "NetworkFoundation",
            dependencies: ["SourceRuntime"]
        ),
        .testTarget(
            name: "SourceFormatTests",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "SourceFormat",
            ]
        ),
        .testTarget(
            name: "SourceRuntimeTests",
            dependencies: [
                .product(name: "LegadoCoreKit", package: "LegadoCoreKit"),
                "SourceRuntime",
            ]
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
            name: "NetworkFoundationTests",
            dependencies: ["NetworkFoundation", "SourceRuntime"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
