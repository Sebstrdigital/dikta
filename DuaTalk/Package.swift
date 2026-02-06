// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DuaTalk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DuaTalk", targets: ["DuaTalk"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", "0.9.0"..<"0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "DuaTalk",
            dependencies: ["WhisperKit"],
            path: "DuaTalk",
            exclude: ["Resources/Info.plist", "Resources/DuaTalk.entitlements"],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        )
    ]
)
