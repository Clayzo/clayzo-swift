// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "Clayzo", targets: ["Clayzo"])],
  targets: [
    .binaryTarget(name: "Clayzo", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.22/Clayzo.xcframework.zip", checksum: "e8a4ecb408e52c158cec164e1b94e688e85191a85ec851e47301025422e39dc3"),
  ]
)
