// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cutmark",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Cutmark", path: "Sources/Cutmark"),
        // The face finder for check_edit's framing check (mcp/cutmark_mcp.py chk_framing).
        .executableTarget(name: "cutmark-faces", path: "Sources/CutmarkFaces"),
        .testTarget(name: "CutmarkTests", dependencies: ["Cutmark"], path: "Tests/CutmarkTests")
    ],
    swiftLanguageModes: [.v5]
)
