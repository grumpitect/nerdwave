// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nerdwave",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MusicCore", targets: ["MusicCore"])],
    targets: [
        // Everything testable: playlists, levels, volume, shuffle queue, player logic, menu layout.
        .target(name: "MusicCore"),
        // The menu bar app itself (AppKit glue only).
        .executableTarget(name: "App", dependencies: ["MusicCore"]),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"]),
    ]
)
