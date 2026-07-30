// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pleiades",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Maia", targets: ["Maia"]),
        .library(name: "Electra", targets: ["Electra"]),
        .library(name: "Sterope", targets: ["Sterope"]),
        .library(name: "Celaeno", targets: ["Celaeno"]),
        .library(name: "Alcyone", targets: ["Alcyone"]),
        .executable(name: "pleiades", targets: ["PleiadesCLI"]),
        .executable(name: "alcyone", targets: ["AlcyoneApp"]),
    ],
    targets: [
        .target(name: "Maia", resources: [
            .copy("Resources/dtc-codes.json"),
            .copy("Resources/ATTRIBUTION.md"),
        ]),
        .target(name: "Electra", dependencies: ["Maia"]),
        .target(name: "Sterope", dependencies: ["Maia"]),
        .target(name: "Celaeno"),
        .target(name: "Alcyone", dependencies: ["Maia", "Electra", "Sterope", "Celaeno"]),
        // Info.plist is embedded at link time by scripts/ble-probe.sh, not
        // bundled as a resource — see that script for why.
        .executableTarget(
            name: "PleiadesCLI",
            dependencies: ["Maia", "Electra"],
            exclude: ["Info.plist"]
        ),
        .executableTarget(name: "AlcyoneApp", dependencies: ["Alcyone"]),
        .testTarget(name: "MaiaTests", dependencies: ["Maia"]),
        .testTarget(name: "ElectraTests", dependencies: ["Electra", "Maia"]),
        .testTarget(name: "SteropeTests", dependencies: ["Sterope", "Maia"]),
        .testTarget(name: "CelaenoTests", dependencies: ["Celaeno"]),
        .testTarget(name: "AlcyoneTests", dependencies: ["Alcyone"]),
    ]
)
