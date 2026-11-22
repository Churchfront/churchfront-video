// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CueVideo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CueVideo", targets: ["CueVideo"]),
        // The MCP server Claude uses to control CueVideo (ships inside CueVideo.app).
        .executable(name: "cuevideo-mcp", targets: ["CueVideoMCP"]),
        // The ATEM and PTZ engine, shared with CueScreens and CueStack.
        .library(name: "CueATEM", targets: ["CueATEM"]),
    ],
    dependencies: [
        // Churchfront Kit (formerly CueKit), shared with the other suite apps: the Signal design tokens and Figtree.
        .package(url: "https://github.com/Churchfront/churchfront-kit.git", from: "0.2.1"),
    ],
    targets: [
        // Engine messages people see (camera and switcher problems) are in Resources/Localizable.xcstrings.
        .target(name: "CueATEM", path: "Sources/CueATEM", resources: [.process("Resources")]),
        // NDI in by loading the runtime at run time (no SDK needed to build).
        .target(name: "NDIBridge", path: "Sources/NDIBridge"),
        .executableTarget(name: "CueVideoMCP", path: "Sources/CueVideoMCP"),
        .executableTarget(
            name: "CueVideo",
            dependencies: ["CueATEM", "NDIBridge", .product(name: "CueDesign", package: "churchfront-kit")],
            path: "Sources/CueVideo",
            // Every word in the app, with its translations: Resources/Localizable.xcstrings (see docs/localization.md).
            resources: [.process("Resources")]
        ),
        // Runs the camera code against pretend cameras on this Mac: swift test
        .testTarget(name: "CueATEMTests", dependencies: ["CueATEM"], path: "Tests/CueATEMTests"),
        .testTarget(name: "CueVideoTests", dependencies: ["CueVideo", "CueATEM"], path: "Tests/CueVideoTests"),
    ]
)
