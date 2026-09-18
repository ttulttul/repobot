// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Repobot", platforms: [.macOS("15.0")],
  products: [
    .library(name: "RepobotCore", targets: ["RepobotCore"]),
    .executable(name: "repobot", targets: ["repobot"]),
    .executable(name: "RepobotApp", targets: ["RepobotApp"]),
  ],
  targets: [
    .target(name: "CProcess"),
    .systemLibrary(name: "CSQLite"),
    .target(name: "RepobotCore", dependencies: ["CProcess", "CSQLite"], resources: [.copy("Resources")]),
    .executableTarget(name: "repobot", dependencies: ["RepobotCore"]),
    .executableTarget(name: "RepobotApp", dependencies: ["RepobotCore"], exclude: ["Info.plist"]),
    .testTarget(name: "RepobotCoreTests", dependencies: ["RepobotCore"]),
    .testTarget(name: "RepobotAppTests", dependencies: ["RepobotApp", "RepobotCore"]),
  ])
