// swift-tools-version:6.4
import PackageDescription

let package = Package(
  name: "pdoom-native",
  platforms: [.macOS("26.0")],
  targets: [
    .target(
      name: "PdoomCore",
      path: "Sources/PdoomCore",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
      name: "pdoom-native",
      dependencies: ["PdoomCore"],
      path: "Sources/pdoom-native",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "PdoomCoreTests",
      dependencies: ["PdoomCore"],
      path: "Tests/PdoomCoreTests",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
