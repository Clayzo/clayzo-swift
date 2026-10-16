// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Clayzo",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "Clayzo", targets: ["Clayzo"])],
  targets: [
    .binaryTarget(name: "Clayzo", url: "https://raw.githubusercontent.com/Clayzo/clayzo-swift/v0.3.17/Clayzo.xcframework.zip", checksum: "24d265c45f8b08fd87101489bcf488afc502f0146eb576d1d1c7ff93e913a512"),
  ]
)
