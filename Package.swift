// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Serce",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Serce", path: "Sources/Serce")
    ]
)
