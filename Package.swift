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
    .binaryTarget(name: "ClayzoEngineCore", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.11/ClayzoEngineCore.xcframework.zip", checksum: "53233f81a1891b9b8a0ae5a3bda16218fef24ac34899e52f972c9878c5e320fd"),
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
