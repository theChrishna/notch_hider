// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchHider",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchHider",
            path: "Sources/NotchHider"
        )
    ]
)
