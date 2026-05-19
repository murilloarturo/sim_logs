// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimConsole",
    platforms: [.iOS(.v15), .macOS(.v11)],
    products: [
        .library(name: "SimConsole", type: .dynamic, targets: ["SimConsole"])
    ],
    targets: [
        .target(
            name: "SimConsole",
            path: "Sources/SimConsole"
        ),
        .testTarget(
            name: "SimConsoleTests",
            dependencies: ["SimConsole"],
            path: "Tests/SimConsoleTests"
        )
    ]
)
