// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayKitApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RelayKitApp", targets: ["RelayKitApp"])
    ],
    targets: [
        .executableTarget(name: "RelayKitApp")
    ]
)
