// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "B2OU",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "b2ou", targets: ["b2ou"]),
        .executable(name: "B2OUMenuBar", targets: ["B2OUMenuBar"]),
        .executable(name: "B2OUBundler", targets: ["B2OUBundler"]),
        .executable(name: "B2OUCoreSmokeTests", targets: ["B2OUCoreSmokeTests"]),
        .executable(name: "B2OUCoreRegressionTests", targets: ["B2OUCoreRegressionTests"]),
        .executable(name: "B2OUCoreContractTests", targets: ["B2OUCoreContractTests"]),
        .executable(name: "B2OUWorkflowTests", targets: ["B2OUWorkflowTests"]),
        .library(name: "B2OUAppSupport", targets: ["B2OUAppSupport"]),
        .library(name: "B2OUCore", targets: ["B2OUCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/johnxnguyen/Down.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "B2OUCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "B2OUAppSupport",
            dependencies: ["B2OUCore"]
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
            dependencies: [
                "B2OUCore",
                "B2OUAppSupport",
                .product(name: "Down", package: "Down"),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("WebKit"),
            ]
        ),
        .executableTarget(
            name: "B2OUBundler"
        ),
        .executableTarget(
            name: "B2OUCoreSmokeTests",
            dependencies: ["B2OUCore"]
        ),
        .executableTarget(
            name: "B2OUCoreRegressionTests",
            dependencies: ["B2OUCore"]
        ),
        .executableTarget(
            name: "B2OUCoreContractTests",
            dependencies: ["B2OUCore"]
        ),
        .executableTarget(
            name: "B2OUWorkflowTests",
            dependencies: [
                "B2OUCore",
                "B2OUAppSupport",
            ]
        ),
    ]
)
