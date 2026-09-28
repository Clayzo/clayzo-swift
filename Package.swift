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
    .binaryTarget(name: "ClayzoEngineCore", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.8/ClayzoEngineCore.xcframework.zip", checksum: "d8537e4e2733c64726de7a41a46155d1f035656c6f65d953208e5c26ce0b39ee"),
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
