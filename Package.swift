// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Lighten",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "LightenKit", targets: ["LightenKit"]),
    .executable(name: "Lighten", targets: ["Lighten"]),
    .executable(name: "lighten-bench", targets: ["LightenBench"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "CLightenPlatform", path: "Sources/CLightenPlatform",
      cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]),
    .target(
      name: "LightenKit",
      dependencies: ["CLightenPlatform"],
      path: "Sources/LightenKit",
      resources: [.process("Clean/Resources")]
    ),
    .executableTarget(
      name: "Lighten",
      dependencies: ["LightenKit", "CLightenPlatform"],
      path: "Sources/Lighten",
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
      ]
    ),
    .executableTarget(
      name: "LightenBench",
      dependencies: ["LightenKit"],
      path: "Sources/LightenBench"
    ),
    .testTarget(
      name: "LightenKitTests",
      dependencies: ["LightenKit"],
      path: "Tests/LightenKitTests"
    ),
    .testTarget(
      name: "LightenAppTests",
      dependencies: ["Lighten", "CLightenPlatform"],
      path: "Tests/LightenAppTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
