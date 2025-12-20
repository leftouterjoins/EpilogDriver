// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EpilogDriver",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        // CUPS filter executable - converts raster/PDF to Epilog format
        .executable(name: "rastertoepiloz", targets: ["RasterToEpilog"]),
    ],
    targets: [
        // C bridging module for CUPS APIs
        .systemLibrary(
            name: "CUPSBridge",
            path: "Sources/CUPSBridge",
            pkgConfig: nil,
            providers: []
        ),

        // Main CUPS filter
        .executableTarget(
            name: "RasterToEpilog",
            dependencies: ["CUPSBridge"],
            path: "Sources/RasterToEpilog",
            linkerSettings: [
                .linkedLibrary("cups"),
                .linkedLibrary("cupsimage"),
            ]
        ),

        // Unit tests
        .testTarget(
            name: "RasterToEpilogTests",
            dependencies: ["RasterToEpilog"],
            path: "Tests/RasterToEpilogTests"
        ),
    ]
)
