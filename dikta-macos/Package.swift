// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dikta",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "Dikta", targets: ["Dikta"]),
        .executable(name: "DiktaBench", targets: ["DiktaBench"]),
        .executable(name: "TimestampProbe", targets: ["TimestampProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", "2.0.0"..<"3.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.3"),
    ],
    targets: [
        .executableTarget(
            name: "Dikta",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio"),
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
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "bench/DiktaBench"
        ),
        .executableTarget(
            name: "TimestampProbe",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "bench/TimestampProbe"
        )
    ]
)
