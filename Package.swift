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
    .binaryTarget(name: "ClayzoEngineCore", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.14/ClayzoEngineCore.xcframework.zip", checksum: "bbe98ae34b0f5f2f808beceaab02a7810ac026b68027594e5e6a846689b12d21"),
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
