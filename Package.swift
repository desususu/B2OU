// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "B2OU",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "b2ou", targets: ["b2ou"]),
        .library(name: "B2OUCore", targets: ["B2OUCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "B2OUCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "b2ou",
            dependencies: [
                "B2OUCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "B2OUMenuBar",
            dependencies: ["B2OUCore"],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "B2OUCoreTests",
            dependencies: ["B2OUCore"]
        ),
    ]
)
