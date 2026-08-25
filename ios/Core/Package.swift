// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VHOSCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "VHOSCore", targets: ["VHOSCore"])
    ],
    targets: [
        .target(name: "VHOSCore"),
        .testTarget(
            name: "VHOSCoreTests",
            dependencies: ["VHOSCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
