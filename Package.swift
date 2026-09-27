// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "Clayzo", targets: ["Clayzo"]),
    .executable(name: "clayzo-fidelity", targets: ["ClayzoFidelity"]),
  ],
  targets: [
    // Built by scripts/build-xcframework.sh from packages/engine-core-rs.
    .binaryTarget(name: "ClayzoEngineCore", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.7/ClayzoEngineCore.xcframework.zip", checksum: "1e1dc70f74b6ee3e427d8d9c62c56787ef77f224d96caf9064bc802c679dfd3d"),
    .target(name: "Clayzo", dependencies: ["ClayzoEngineCore"]),
    // Pixel harness against the CanvasKit reference; macOS only.
    .executableTarget(name: "ClayzoFidelity", dependencies: ["Clayzo"]),
    .testTarget(
      name: "ClayzoTests",
      dependencies: ["Clayzo"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
