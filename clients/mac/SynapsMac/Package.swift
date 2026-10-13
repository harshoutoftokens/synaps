// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SynapsMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SynapsMac", targets: ["SynapsMac"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SynapsMac",
            dependencies: [],
            path: "Sources"
        )
    ]
)
