// swift-tools-version: 6.2
import PackageDescription

// The app target compiles disk/Core directly through its synced folder. This package
// exists so the same files can be tested with `swift test`, without launching the app.
let package = Package(
    name: "DiskCore",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "DiskCore",
            path: "disk/Core",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "DiskCoreTests",
            dependencies: ["DiskCore"],
            path: "Tests/DiskCoreTests"
        ),
    ]
)
