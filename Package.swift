// swift-tools-version: 5.9
import PackageDescription

// The SwiftUI app imports AppKit and is built only on macOS (CI and
// scripts/build-app.sh). Linux hosts run the Foundation core tests.
#if os(macOS)
  let products: [Product] = [
    .library(name: "PublicEarFiCore", targets: ["PublicEarFiCore"]),
    .executable(name: "RoomCast", targets: ["PublicEarFi"]),
  ]
#else
  let products: [Product] = [
    .library(name: "PublicEarFiCore", targets: ["PublicEarFiCore"])
  ]
#endif

let coreTarget: Target = .target(
  name: "PublicEarFiCore",
  path: "Sources/PublicEarFiCore",
  resources: [
    .copy("ListenerPage.en.json")
  ]
)

let testTarget: Target = .testTarget(
  name: "PublicEarFiCoreTests",
  dependencies: ["PublicEarFiCore"],
  path: "Tests/PublicEarFiCoreTests",
  exclude: ["mediamtx-keys.txt"]
)

#if os(macOS)
  let appTarget: Target = .executableTarget(
    name: "PublicEarFi",
    dependencies: ["PublicEarFiCore"],
    path: "Sources/PublicEarFi",
    exclude: [
      "PublicEarFi.entitlements"
    ],
    resources: [
      .copy("Resources")
    ]
  )
  let audioTestTarget: Target = .testTarget(
    name: "PublicEarFiAudioTests",
    dependencies: ["PublicEarFi", "PublicEarFiCore"],
    path: "Tests/PublicEarFiAudioTests"
  )
  let targets = [coreTarget, appTarget, testTarget, audioTestTarget]
#else
  let targets = [coreTarget, testTarget]
#endif

let package = Package(
  name: "PublicEarFi",
  platforms: [
    .macOS(.v13)
  ],
  products: products,
  targets: targets
)
