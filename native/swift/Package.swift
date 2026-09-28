// swift-tools-version:6.4
import PackageDescription

let package = Package(
  name: "pdoom-native",
  platforms: [.macOS("26.0")],
  targets: [
    .executableTarget(
      name: "pdoom-native",
      path: "Sources/pdoom-native",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
