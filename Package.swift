// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Lighten",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "LightenKit", targets: ["LightenKit"]),
    .executable(name: "Lighten", targets: ["Lighten"]),
  ],
  dependencies: [],
  targets: [
    .target(
      name: "LightenKit",
      path: "Sources/LightenKit"
    ),
    .executableTarget(
      name: "Lighten",
      dependencies: ["LightenKit"],
      path: "Sources/Lighten",
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
      ]
    ),
    .testTarget(
      name: "LightenKitTests",
      dependencies: ["LightenKit"],
      path: "Tests/LightenKitTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
