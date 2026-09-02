// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DexBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DexBar", targets: ["DexBar"]),
        .library(name: "DexBarCore", targets: ["DexBarCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
    ],
    targets: [
        .target(
            name: "DexBarCore",
            path: "Sources/DexBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DexBar",
            dependencies: [
                "DexBarCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DexBar",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "DexBarCoreTests",
            dependencies: ["DexBarCore"],
            path: "Tests/DexBarCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
