// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SecureMessaging",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "SecureMessagingKit", targets: ["SecureMessagingKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.11.0"),
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.10.0"),
    ],
    targets: [
        .target(
            name: "SecureMessagingKit",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium"),
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "SecureMessagingKitTests",
            dependencies: ["SecureMessagingKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
