// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PortManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "PortManager",
            targets: ["PortManager"]
        )
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "PortManager",
            dependencies: ["Core"],
            path: "Sources/PortManager"
        ),
        .testTarget(
            name: "PortManagerTests",
            dependencies: ["Core"],
            path: "Tests/PortManagerTests"
        )
    ]
)
