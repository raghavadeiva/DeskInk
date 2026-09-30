// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeskInk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DeskInk", targets: ["DeskInk"])
    ],
    targets: [
        .executableTarget(
            name: "DeskInk",
            path: "Sources/DeskInk",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "DeskInkTests",
            dependencies: ["DeskInk"],
            path: "Tests/DeskInkTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
