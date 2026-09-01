// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DexBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DexBar", targets: ["DexBar"]),
        .library(name: "DexBarCore", targets: ["DexBarCore"]),
    ],
    targets: [
        .target(
            name: "DexBarCore",
            path: "Sources/DexBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DexBar",
            dependencies: ["DexBarCore"],
            path: "Sources/DexBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DexBarCoreTests",
            dependencies: ["DexBarCore"],
            path: "Tests/DexBarCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
