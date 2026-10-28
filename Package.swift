// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "Clayzo", targets: ["Clayzo"])],
  targets: [
    .binaryTarget(name: "Clayzo", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.20/Clayzo.xcframework.zip", checksum: "b6bcfb5cafd8ecb21ff688cf7741308f77057c287f15429b60cd61600d40e85b"),
  ]
)
