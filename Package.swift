// swift-tools-version:5.10
//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import PackageDescription

/// Compilation gate for the render-faithful navigation test hooks (#1525).
///
/// The host app's live-renderer journey needs a few phase-only probes into the
/// navigator's readiness and frame-capability state. `@_spi` alone cannot keep them
/// out of a shipping binary — it restricts who may *import* a symbol, not whether the
/// symbol is *compiled* — so the hooks are gated on this define and simply do not
/// exist without it.
///
/// `.debug` covers every ordinary test run, including from the Xcode UI. The
/// environment override exists so a Release test product can compile the same hooks.
/// A production archive sets neither, so the symbols are absent from it by
/// construction rather than by visibility. `scripts/check-render-faithful-testing-symbols-absent.sh`
/// in the host repo is the standing proof, and enumerates the exact symbol list.
let renderFaithfulNavTestingSettings: [SwiftSetting] = {
    var settings: [SwiftSetting] = [
        .define("RENDER_FAITHFUL_NAV_TESTING", .when(configuration: .debug)),
    ]
    if ProcessInfo.processInfo.environment["RENDER_FAITHFUL_NAV_TESTING"] != nil {
        settings.append(.define("RENDER_FAITHFUL_NAV_TESTING"))
    }
    return settings
}()

let package = Package(
    name: "Readium",
    defaultLocalization: "en",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "ReadiumShared", targets: ["ReadiumShared"]),
        .library(name: "ReadiumStreamer", targets: ["ReadiumStreamer"]),
        .library(name: "ReadiumNavigator", targets: ["ReadiumNavigator"]),
        .library(name: "ReadiumOPDS", targets: ["ReadiumOPDS"]),
        .library(name: "ReadiumLCP", targets: ["ReadiumLCP"]),

        // Adapters to third-party dependencies.
        .library(name: "ReadiumAdapterGCDWebServer", targets: ["ReadiumAdapterGCDWebServer"]),
        .library(name: "ReadiumAdapterLCPSQLite", targets: ["ReadiumAdapterLCPSQLite"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.10.0"),
        .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.2"),
        .package(url: "https://github.com/ra1028/DifferenceKit.git", from: "1.3.0"),
        .package(url: "https://github.com/readium/Fuzi.git", from: "4.0.0"),
        .package(url: "https://github.com/readium/GCDWebServer.git", from: "4.0.0"),
        .package(url: "https://github.com/readium/ZIPFoundation.git", from: "3.0.1"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.5"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.16.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ReadiumShared",
            dependencies: [
                "ReadiumInternal",
                "SwiftSoup",
                "Zip",
                .product(name: "ReadiumFuzi", package: "Fuzi"),
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/Shared",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("UIKit"),
            ]
        ),
        .testTarget(
            name: "ReadiumSharedTests",
            dependencies: [
                "ReadiumShared",
                "TestPublications",
            ],
            path: "Tests/SharedTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),

        .target(
            name: "ReadiumStreamer",
            dependencies: [
                "CryptoSwift",
                "ReadiumShared",
                .product(name: "ReadiumFuzi", package: "Fuzi"),
            ],
            path: "Sources/Streamer",
            resources: [
                .copy("Assets"),
            ]
        ),
        .testTarget(
            name: "ReadiumStreamerTests",
            dependencies: ["ReadiumStreamer", "TestPublications"],
            path: "Tests/StreamerTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),

        .target(
            name: "ReadiumNavigator",
            dependencies: [
                "ReadiumInternal",
                "ReadiumShared",
                "DifferenceKit",
                "SwiftSoup",
            ],
            path: "Sources/Navigator",
            exclude: [
                "EPUB/Scripts",
            ],
            resources: [
                .copy("EPUB/Assets"),
                .process("Resources"),
            ],
            swiftSettings: renderFaithfulNavTestingSettings
        ),
        .testTarget(
            name: "ReadiumNavigatorTests",
            dependencies: ["ReadiumNavigator"],
            path: "Tests/NavigatorTests",
            exclude: [
                "UITests",
            ]
        ),

        .target(
            name: "ReadiumOPDS",
            dependencies: [
                "ReadiumShared",
                .product(name: "ReadiumFuzi", package: "Fuzi"),
            ],
            path: "Sources/OPDS"
        ),
        .testTarget(
            name: "ReadiumOPDSTests",
            dependencies: ["ReadiumOPDS"],
            path: "Tests/OPDSTests",
            resources: [
                .copy("Samples"),
            ]
        ),

        .target(
            name: "ReadiumLCP",
            dependencies: [
                "CryptoSwift",
                "ReadiumInternal",
                "ReadiumShared",
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/LCP",
            resources: [
                .process("Resources"),
            ]
        ),
        // These tests require a R2LCPClient.framework to run.
        // TODO: Find a solution to run the tests with GitHub action.
        // .testTarget(
        //     name: "ReadiumLCPTests",
        //     dependencies: [
        //         "ReadiumLCP",
        //         "ReadiumShared",
        //         "ReadiumStreamer",
        //         "TestPublications",
        //     ],
        //     path: "Tests/LCPTests"
        // ),

        .target(
            name: "ReadiumAdapterGCDWebServer",
            dependencies: [
                .product(name: "ReadiumGCDWebServer", package: "GCDWebServer"),
                "ReadiumShared",
            ],
            path: "Sources/Adapters/GCDWebServer"
        ),

        .target(
            name: "ReadiumAdapterLCPSQLite",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                "ReadiumLCP",
            ],
            path: "Sources/Adapters/LCPSQLite"
        ),

        .target(
            name: "ReadiumInternal",
            path: "Sources/Internal"
        ),
        .testTarget(
            name: "ReadiumInternalTests",
            dependencies: ["ReadiumInternal"],
            path: "Tests/InternalTests"
        ),

        // Shared test publications used across multiple test targets.
        .target(
            name: "TestPublications",
            path: "Tests/Publications",
            resources: [
                .copy("Publications"),
            ]
        ),
    ]
)
