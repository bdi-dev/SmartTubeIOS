// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SmartTubeIOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        // Stream extractor: InnerTube API, client profiles, PoToken/BotGuard, HLS manifest
        // parsing and the wire models they return. No app state, no UI, no stores — the one
        // module to patch when YouTube changes its API.
        .library(
            name: "InnerTubeKit",
            targets: ["InnerTubeKit"]
        ),
        // Cross-platform core: view models, stores, SponsorBlock services. Re-exports InnerTubeKit.
        .library(
            name: "SmartTubeIOSCore",
            targets: ["SmartTubeIOSCore"]
        ),
        // SwiftUI UI layer (iOS/iPadOS/macOS).
        .library(name: "SmartTubeIOS", targets: ["SmartTubeIOS"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk",
            from: "12.0.0"
        ),
        // libmpv (FFmpeg + libplacebo/MoltenVK) for the opt-in tvOS player engine.
        // LGPL-3.0 build; linked only into the tvOS slice (see the target dependency below).
        .package(
            url: "https://github.com/mpvkit/MPVKit.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        // MARK: Extractor – InnerTube API + stream models (no dependencies, no app state)
        .target(
            name: "InnerTubeKit",
            dependencies: [],
            path: "Sources/InnerTubeKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // MARK: Core – iOS, macOS (Foundation only)
        .target(
            name: "SmartTubeIOSCore",
            dependencies: ["InnerTubeKit"],
            path: "Sources/SmartTubeIOSCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // MARK: UI – iOS/iPadOS/macOS (SwiftUI)
        .target(
            name: "SmartTubeIOS",
            dependencies: [
                "SmartTubeIOSCore",
                .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
                .product(name: "MPVKit", package: "MPVKit", condition: .when(platforms: [.tvOS])),
            ],
            path: "Sources/SmartTubeIOS",
            resources: [
                .process("Localizable.xcstrings"),
                .copy("Resources/yt.solver.lib.min.js"),
                .copy("Resources/yt.solver.core.min.js"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // MARK: Tests
        .testTarget(
            name: "SmartTubeIOSTests",
            dependencies: ["InnerTubeKit", "SmartTubeIOSCore", "SmartTubeIOS"],
            path: "Tests/SmartTubeIOSTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
