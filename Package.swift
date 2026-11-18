// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "rd-host", targets: ["rd-host"]),
        .executable(name: "rd-client", targets: ["rd-client"]),
    ],
    targets: [
        // Shared code: pairing secret, secure transport, wire protocol.
        .target(name: "RDCore"),
        // Runs on the computer being controlled (the Mac Studio).
        .executableTarget(name: "rd-host", dependencies: ["RDCore"]),
        // Runs on the computer you sit at (the MacBook).
        .executableTarget(name: "rd-client", dependencies: ["RDCore"]),
        .testTarget(name: "RDCoreTests", dependencies: ["RDCore"]),
    ]
)
