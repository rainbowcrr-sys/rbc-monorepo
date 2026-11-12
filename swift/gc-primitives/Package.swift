// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "gc-primitives",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "GCPrimitives", targets: ["GCPrimitives"]),
    ],
    targets: [
        .target(name: "GCPrimitives"),
        .testTarget(name: "GCPrimitivesTests", dependencies: ["GCPrimitives"]),
    ],
    swiftLanguageVersions: [.v5]
)
