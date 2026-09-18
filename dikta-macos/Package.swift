// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dikta",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "Dikta", targets: ["Dikta"]),
        .executable(name: "DiktaBench", targets: ["DiktaBench"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", "2.0.0"..<"3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Dikta",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Dikta",
            exclude: ["Resources/Info.plist", "Resources/Dikta.entitlements"],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "DiktaTests",
            dependencies: ["Dikta"],
            path: "DiktaTests"
        ),
        .executableTarget(
            name: "DiktaBench",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "bench/DiktaBench"
        )
    ]
)
