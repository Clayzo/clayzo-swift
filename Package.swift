// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "Clayzo", targets: ["Clayzo"])],
  targets: [
    .binaryTarget(name: "Clayzo", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.19/Clayzo.xcframework.zip", checksum: "ef7572ff9454c4837303a312e98e75b23918028d251847ed1c2772606da11fbc"),
  ]
)
