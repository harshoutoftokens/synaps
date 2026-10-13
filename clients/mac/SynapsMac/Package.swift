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
        ),
        // `@testable import SynapsMac` works for executable targets on macOS (SwiftPM 5.5+).
        // Live NAS tests are skipped unless SYNAPS_LIVE_NAS_URL is set.
        .testTarget(
            name: "SynapsMacTests",
            dependencies: ["SynapsMac"],
            path: "Tests"
        )
    ]
)
