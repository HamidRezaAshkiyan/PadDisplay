// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PadDisplay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PadDisplay", targets: ["PadDisplay"]),
        .library(name: "PadDisplayCore", targets: ["PadDisplayCore"])
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "PadDisplayCore",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "Sources/PadDisplayCore",
            resources: [
                .copy("Resources/WebClient")
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "PadDisplay",
            dependencies: ["PadDisplayCore"],
            path: "Sources/PadDisplay",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage")
            ]
        ),
        .executableTarget(
            name: "PadDisplaySelfTest",
            dependencies: ["PadDisplayCore"],
            path: "Sources/PadDisplaySelfTest"
        )
    ]
)
