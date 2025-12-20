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
        // CUPS USB backend - enables USB printing to Epilog
        .executable(name: "epilog-usb", targets: ["EpilogUSB"]),
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

        // USB backend for direct USB printing
        .executableTarget(
            name: "EpilogUSB",
            dependencies: [],
            path: "Sources/EpilogUSB",
            linkerSettings: [
                .linkedFramework("IOKit"),
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
