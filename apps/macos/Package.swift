// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Segue",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SegueKit", targets: ["SegueKit"]),
        .library(name: "SegueHelperProtocol", targets: ["SegueHelperProtocol"]),
        .library(name: "SegueHelperCore", targets: ["SegueHelperCore"]),
        .executable(name: "Segue", targets: ["Segue"]),
        .executable(name: "segue-core-helper", targets: ["SegueCoreHelper"]),
        .library(name: "SegueReleaseCore", targets: ["SegueReleaseCore"]),
        .executable(name: "segue-release", targets: ["SegueRelease"]),
    ],
    targets: [
        .target(name: "SegueHelperProtocol"),
        .target(
            name: "SegueKit",
            dependencies: ["SegueHelperProtocol"]
        ),
        .target(
            name: "SegueHelperCore",
            dependencies: ["SegueHelperProtocol", "SegueAILayer"]
        ),
        .executableTarget(
            name: "Segue",
            dependencies: ["SegueKit"]
        ),
        .executableTarget(
            name: "SegueCoreHelper",
            dependencies: ["SegueHelperCore"]
        ),
        .testTarget(
            name: "SegueKitTests",
            dependencies: ["SegueKit"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "SegueHelperCoreTests",
            dependencies: ["SegueHelperCore", "SegueAILayer"]
        ),
        // AI lock layer (stage 2 groundwork) — pure rendering and answering,
        // no side effects. Own block so concurrent helper work merges cleanly.
        .target(name: "SegueAILayer"),
        .testTarget(
            name: "SegueAILayerTests",
            dependencies: ["SegueAILayer"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        // Release daemon (design §3) — the escape hatch that restores the
        // network without the helper. Own blocks, nothing above changes.
        .target(
            name: "SegueReleaseCore",
            dependencies: ["SegueHelperProtocol", "SegueAILayer", "SegueHelperCore"]
        ),
        .executableTarget(
            name: "SegueRelease",
            dependencies: ["SegueReleaseCore", "SegueHelperCore"]
        ),
        .testTarget(
            name: "SegueReleaseCoreTests",
            dependencies: [
                "SegueReleaseCore", "SegueHelperProtocol", "SegueAILayer", "SegueHelperCore",
            ]
        ),
    ]
)
