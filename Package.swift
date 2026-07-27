// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EpilogDriver",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        // Shared core: artwork import, layer model, and the Epilog wire protocol.
        .library(name: "EpilogKit", targets: ["EpilogKit"]),
        // CUPS filter executable - converts raster/PDF to Epilog format
        .executable(name: "rastertoepiloz", targets: ["RasterToEpilog"]),
        // CUPS USB backend - enables USB printing to Epilog
        .executable(name: "epilog-usb", targets: ["EpilogUSB"]),
        // Interactive laser studio application
        .executable(name: "EpilogStudio", targets: ["EpilogStudio"]),
    ],
    targets: [
        // C bridging module for CUPS APIs
        .systemLibrary(
            name: "CUPSBridge",
            path: "Sources/CUPSBridge",
            pkgConfig: nil,
            providers: []
        ),

        // Everything that is not tied to a particular front end: reading
        // artwork, deciding what to cut and what to engrave, and generating the
        // byte stream the laser expects.
        .target(
            name: "EpilogKit",
            dependencies: [],
            path: "Sources/EpilogKit"
        ),

        // Main CUPS filter
        .executableTarget(
            name: "RasterToEpilog",
            dependencies: ["CUPSBridge", "EpilogKit"],
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

        // The application. Built as a plain executable and then assembled into
        // an .app bundle by Installer/build-app.sh, which is what gives it a
        // dock icon, a menu bar and document handling.
        .executableTarget(
            name: "EpilogStudio",
            dependencies: ["EpilogKit"],
            path: "Sources/EpilogStudio"
        ),

        // Unit tests
        .testTarget(
            name: "RasterToEpilogTests",
            dependencies: ["EpilogKit"],
            path: "Tests/RasterToEpilogTests"
        ),
    ]
)
