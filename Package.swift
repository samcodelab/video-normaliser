// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FrankLuma",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FrankLuma", targets: ["FrankLuma"])],
    targets: [
        .executableTarget(name: "FrankLuma"),
        .testTarget(name: "FrankLumaTests", dependencies: ["FrankLuma"], resources: [.copy("Fixtures")])
    ]
)
