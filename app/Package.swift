// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RelayKitApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RelayKitApp", targets: ["RelayKitApp"]),
        .executable(name: "RelayKitAppValidationTests", targets: ["RelayKitAppValidationTests"])
    ],
    targets: [
        .target(name: "RelayKitCore"),
        .executableTarget(name: "RelayKitApp", dependencies: ["RelayKitCore"]),
        .executableTarget(name: "RelayKitAppValidationTests", dependencies: ["RelayKitCore"])
    ]
)
