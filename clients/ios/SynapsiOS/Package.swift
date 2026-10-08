// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SynapsiOS",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "SynapsiOS", targets: ["SynapsiOS"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SynapsiOS",
            dependencies: [],
            path: "Sources"
        )
    ]
)
