// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared SMC core: talks to the AppleSMC IOKit user client.
        .target(name: "SMCFan"),
        // Command-line front-end.
        .executableTarget(name: "fan", dependencies: ["SMCFan"]),
        // Menu bar GUI front-end.
        .executableTarget(name: "FanControlApp", dependencies: ["SMCFan"]),
    ]
)
