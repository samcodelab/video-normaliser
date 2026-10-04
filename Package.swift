// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoNormaliser",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VideoNormaliser", targets: ["VideoNormaliser"])],
    targets: [
        .executableTarget(name: "VideoNormaliser"),
        .testTarget(name: "VideoNormaliserTests", dependencies: ["VideoNormaliser"], resources: [.copy("Fixtures")])
    ]
)
