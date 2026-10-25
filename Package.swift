// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacStatus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacStatus", targets: ["MacStatus"])],
    targets: [
        .executableTarget(name: "MacStatus"),
        .testTarget(name: "MacStatusTests", dependencies: ["MacStatus"])
    ]
)
