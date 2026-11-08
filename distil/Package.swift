// swift-tools-version: 5.9
import PackageDescription

// The SwiftUI app target exists only on macOS. The core engine and its tests have no UI or
// platform-specific dependencies, so they can also be built and tested on Linux (for example in CI).
var products: [Product] = [.library(name: "TokenLabCore", targets: ["TokenLabCore"])]
var targets: [Target] = [
    .target(name: "TokenLabCore"),
    .testTarget(name: "TokenLabCoreTests", dependencies: ["TokenLabCore"])
]
#if os(macOS)
// The executable is named Distil so the menu bar, Dock and `swift run Distil` show the product name.
// Package, module and bundle identifiers are unchanged.
products.append(.executable(name: "Distil", targets: ["TokenLabApp"]))
targets.append(.executableTarget(name: "TokenLabApp", dependencies: ["TokenLabCore"]))
#endif

let package = Package(
    name: "TokenLab",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
