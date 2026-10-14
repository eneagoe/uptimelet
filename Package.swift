// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Uptimelet",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "Uptimelet", targets: ["Uptimelet"])],
    targets: [
        .target(name: "UptimeCore"),
        .executableTarget(name: "Uptimelet", dependencies: ["UptimeCore"]),
        .testTarget(name: "UptimeCoreTests", dependencies: ["UptimeCore"]),
        .testTarget(name: "UptimeletTests", dependencies: ["Uptimelet", "UptimeCore"])
    ]
)
