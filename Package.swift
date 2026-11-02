// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Seamline",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Seamline", targets: ["Seamline"]),
    ],
    targets: [
        .target(
            name: "SeamlineCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Seamline",
            dependencies: ["SeamlineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SeamlineCoreTests",
            dependencies: ["SeamlineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
