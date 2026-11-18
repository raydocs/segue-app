// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Segue",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SegueKit", targets: ["SegueKit"]),
        .executable(name: "Segue", targets: ["Segue"]),
    ],
    targets: [
        .target(name: "SegueKit"),
        .executableTarget(
            name: "Segue",
            dependencies: ["SegueKit"]
        ),
        .testTarget(
            name: "SegueKitTests",
            dependencies: ["SegueKit"],
            resources: [
                .copy("Fixtures"),
            ]
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
