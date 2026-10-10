// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SupersEmuServer",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "SupersEmuKit", targets: ["SupersEmuKit"]),
        .library(name: "SupersEmuServerCore", targets: ["SupersEmuServerCore"]),
        .executable(name: "supersemu-server", targets: ["supersemu-server"]),
        .executable(name: "supersemu", targets: ["supersemu"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
    ],
    targets: [
        // Shared API models + HTTP client. Used by the apps, the CLI and the server. No dependencies.
        .target(name: "SupersEmuKit"),
        .target(
            name: "SupersEmuServerCore",
            dependencies: [
                "SupersEmuKit",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]),
        .executableTarget(
            name: "supersemu-server",
            dependencies: [
                "SupersEmuServerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "supersemu",
            dependencies: [
                "SupersEmuKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(
            name: "SupersEmuServerCoreTests",
            dependencies: [
                "SupersEmuServerCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "X509", package: "swift-certificates"),
            ]),
        .testTarget(
            name: "SupersEmuCLITests",
            dependencies: [
                "supersemu",
                "SupersEmuServerCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]),
    ],
    swiftLanguageModes: [.v5]
)
