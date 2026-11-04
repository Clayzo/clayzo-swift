// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "Clayzo", targets: ["Clayzo"])],
  targets: [
    .binaryTarget(name: "Clayzo", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.21/Clayzo.xcframework.zip", checksum: "eb021ec6cded41aac40c06629c3fa3a211815b40e833db31adbc2af027162b66"),
  ]
)
