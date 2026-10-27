// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FOHCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FOHCore", targets: ["FOHCore"]),
        .library(name: "FOHMacKit", targets: ["FOHMacKit"]),
        .executable(name: "fohctl", targets: ["fohctl"]),
    ],
    targets: [
        // Platform-neutral model shared by the iPad app and the Mac bridge.
        .target(name: "FOHCore"),
        // macOS-only pieces: virtual MIDI ports, AU plugin discovery, the bridge server.
        .target(name: "FOHMacKit", dependencies: ["FOHCore"]),
        // Command-line tool for spikes and headless testing.
        .executableTarget(name: "fohctl", dependencies: ["FOHCore", "FOHMacKit"]),
        .testTarget(name: "FOHCoreTests", dependencies: ["FOHCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FOHMacKitTests", dependencies: ["FOHCore", "FOHMacKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
