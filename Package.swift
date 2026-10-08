// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "Clayzo", targets: ["Clayzo"])],
  targets: [
    .binaryTarget(name: "Clayzo", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.16/Clayzo.xcframework.zip", checksum: "47eca9ecd1009c95ecf6b990071422de4f4be3e86632c21b24e59855a95d3256"),
  ]
)
