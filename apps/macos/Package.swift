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
    ]
)
