// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "desnotch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DesnotchCore",
            path: "Sources/DesnotchCore",
            resources: [
                .copy("MediaRemote/Vendor/MediaRemoteAdapter")
            ]
        ),
        .executableTarget(
            name: "desnotch",
            dependencies: ["DesnotchCore"],
            path: "Sources/desnotch"
        ),
        .testTarget(
            name: "DesnotchCoreTests",
            dependencies: ["DesnotchCore"],
            path: "Tests/DesnotchCoreTests"
        )
    ]
)
