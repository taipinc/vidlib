// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Vidlib",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Vidlib", targets: ["Vidlib"])],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .executableTarget(name: "Vidlib", dependencies: ["CSQLite"]),
    .testTarget(name: "VidlibTests", dependencies: ["Vidlib"]),
  ],
  swiftLanguageModes: [.v5]
)
