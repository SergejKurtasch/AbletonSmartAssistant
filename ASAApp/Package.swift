// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ASAApp",
    platforms: [
        .macOS(.v13) // ScreenCaptureKit is available from macOS 12.3+, but the project uses macOS 13+ APIs
    ],
    products: [
        .executable(
            name: "ASAApp",
            targets: ["ASAApp"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI", from: "0.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ASAApp",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI")
            ],
            path: "Sources/ASAApp"
        )
    ]
)

