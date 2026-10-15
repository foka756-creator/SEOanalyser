// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiteCrawler",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SiteCrawler", path: "Sources/SiteCrawler")
    ],
    swiftLanguageModes: [.v5]
)
