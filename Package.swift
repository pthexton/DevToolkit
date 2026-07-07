// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevToolkit",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "DevToolkitApp"
        )
    ]
)
