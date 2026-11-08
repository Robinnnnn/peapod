// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MinesE2EE",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "MinesE2EE", targets: ["MinesE2EE"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "MinesE2EE", dependencies: ["CSQLite"]),
        .testTarget(name: "MinesE2EETests", dependencies: ["MinesE2EE"])
    ]
)
