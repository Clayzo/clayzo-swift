// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "Clayzo", targets: ["Clayzo"])],
  targets: [
    .binaryTarget(name: "Clayzo", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.18/Clayzo.xcframework.zip", checksum: "19e04680f59aa838a73b9c6aaf3481c1106d102d5842d47d198f777a3a0eea4e"),
  ]
)
