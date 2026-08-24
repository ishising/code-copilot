// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeCopilot",
    // ScreenCaptureKit's SCScreenshotManager is macOS 14; the SDK itself
    // runs on 13, but the screenshot half of the capture handler does not.
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/socratic-ai/cosmo-swift-sdk",
            from: "0.7.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "CodeCopilot",
            dependencies: [
                .product(name: "CosmoRealtime", package: "cosmo-swift-sdk")
            ],
            path: "Sources/CodeCopilot"
        ),
        .testTarget(
            name: "CodeCopilotTests",
            dependencies: ["CodeCopilot"],
            path: "Tests/CodeCopilotTests"
        ),
    ]
)
