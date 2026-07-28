// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pleiades",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Maia", targets: ["Maia"]),
        .library(name: "Electra", targets: ["Electra"]),
        .executable(name: "pleiades", targets: ["PleiadesCLI"]),
    ],
    targets: [
        .target(name: "Maia"),
        .target(name: "Electra", dependencies: ["Maia"]),
        .executableTarget(name: "PleiadesCLI", dependencies: ["Maia", "Electra"]),
        .testTarget(name: "MaiaTests", dependencies: ["Maia"]),
        .testTarget(name: "ElectraTests", dependencies: ["Electra", "Maia"]),
    ]
)
