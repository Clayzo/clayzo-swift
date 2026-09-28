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
    .binaryTarget(name: "ClayzoEngineCore", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.9/ClayzoEngineCore.xcframework.zip", checksum: "b95b96c92a2c00f251f9dd338996f2208a3ae024510d69493667483d1b731212"),
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
