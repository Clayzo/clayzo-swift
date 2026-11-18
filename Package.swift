// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "Clayzo", targets: ["Clayzo"])],
  targets: [
    .binaryTarget(name: "Clayzo", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.23/Clayzo.xcframework.zip", checksum: "b57de0b95e430fbed8244bd0606ebe4e5853a4d6afeb15f58f71c9a8bca809f4"),
  ]
)
