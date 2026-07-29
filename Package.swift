// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "desnotch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "desnotch",
            path: "Sources/desnotch",
            resources: [
                .copy("MediaRemote/Vendor/MediaRemoteAdapter")
            ]
        )
    ]
)
