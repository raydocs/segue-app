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
    ]
)
