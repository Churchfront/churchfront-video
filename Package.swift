// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CueVideo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CueVideo", targets: ["CueVideo"]),
        // The ATEM and PTZ engine, shared with CueScreens and CueStack.
        .library(name: "CueATEM", targets: ["CueATEM"]),
    ],
    targets: [
        .target(name: "CueATEM", path: "Sources/CueATEM"),
        // NDI in by loading the runtime at run time (no SDK needed to build).
        .target(name: "NDIBridge", path: "Sources/NDIBridge"),
        .executableTarget(
            name: "CueVideo",
            dependencies: ["CueATEM", "NDIBridge"],
            path: "Sources/CueVideo"
        ),
    ]
)
