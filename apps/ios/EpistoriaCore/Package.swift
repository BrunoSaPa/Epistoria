// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EpistoriaCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "EpistoriaCore", targets: ["EpistoriaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.17.0"),
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
        // 0.2.5 requires Swift tools 6.1; Xcode 16.2 ships Swift 6.0.
        .package(url: "https://github.com/Kingpin-Apps/swift-mnemonic.git", exact: "0.2.4"),
    ],
    targets: [
        .target(
            name: "EpistoriaCore",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "SwiftMnemonic", package: "swift-mnemonic"),
            ],
            cSettings: [.define("SQLITE_HAS_CODEC")],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "EpistoriaCoreTests",
            dependencies: ["EpistoriaCore"],
            resources: [
                .copy("Fixtures/crypto-vectors.json"),
            ]
        ),
    ]
)
