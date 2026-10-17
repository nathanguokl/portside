// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Portside",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Portside", targets: ["Portside"]),
        .executable(name: "portside-cli", targets: ["PortsideCLI"])
    ],
    targets: [
        .target(name: "PortsideCore"),
        .executableTarget(name: "Portside", dependencies: ["PortsideCore"], resources: [.copy("Resources/Branding")]),
        .executableTarget(name: "PortsideCLI", dependencies: ["PortsideCore"]),
        .testTarget(name: "PortsideCoreTests", dependencies: ["PortsideCore"]),
        .testTarget(name: "PortsideAppTests", dependencies: ["Portside", "PortsideCore"])
    ]
)
