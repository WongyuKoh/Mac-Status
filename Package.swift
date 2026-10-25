// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacStatus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacStatus", targets: ["MacStatus"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .executableTarget(name: "MacStatus", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MacStatusTests", dependencies: ["MacStatus"])
    ]
)
