// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexNetworkMonitor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexNetworkMonitor", targets: ["CodexNetworkMonitor"])],
    targets: [
        .target(name: "MonitorCore"),
        .executableTarget(name: "CodexNetworkMonitor", dependencies: ["MonitorCore"]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"])
    ],
    swiftLanguageModes: [.v5]
)
