// swift-tools-version: 5.9
import PackageDescription

// Relay — Oslo Sprint side-challenge assistant.
//
// RelayCore, RelayAdapters and RelayRunner use only Foundation (plus Security on Apple
// platforms for Keychain), so they build and test on macOS and Linux. The SwiftUI app target
// is added only on macOS. No third-party packages are used.
var products: [Product] = [
    .library(name: "RelayCore", targets: ["RelayCore"]),
    .library(name: "RelayAdapters", targets: ["RelayAdapters"]),
    .executable(name: "relay-runner", targets: ["RelayRunner"]),
]
var targets: [Target] = [
    .target(name: "RelayCore"),
    .target(name: "RelayAdapters", dependencies: ["RelayCore"]),
    .executableTarget(name: "RelayRunner", dependencies: ["RelayCore"]),
    .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
    .testTarget(name: "RelayAdaptersTests", dependencies: ["RelayAdapters", "RelayCore"]),
]
#if os(macOS)
products.append(.executable(name: "Relay", targets: ["RelayApp"]))
targets.append(.executableTarget(name: "RelayApp", dependencies: ["RelayCore", "RelayAdapters"]))
#endif

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
