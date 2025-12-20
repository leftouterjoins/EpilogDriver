/*
 * JobOptions.swift - Parse CUPS job options for Epilog laser
 *
 * Extracts laser parameters from the CUPS options string (argv[5]).
 */

import Foundation
import CUPSBridge

/// Epilog job options parsed from CUPS
struct JobOptions {
    // Resolution
    var resolution: Int = 500  // DPI: 100, 200, 250, 400, 500, 1000

    // Raster engraving settings
    var rasterPower: Int = 100      // 1-100%
    var rasterSpeed: Int = 100      // 1-100%

    // Vector cutting settings
    var vectorPower: Int = 100      // 0-100%
    var vectorSpeed: Int = 100      // 1-100%
    var vectorFrequency: Int = 5000 // 1-5000 Hz

    // Focus adjustment (in Epilog units, not mm)
    // Each unit = 0.0252mm, range: -500 to +500
    var focus: Int = 0

    // Job type
    var jobType: JobType = .combined

    // Raster direction
    var engraveBottomUp: Bool = false

    // Autofocus
    var autofocus: Bool = false

    // Color mapping settings (optional, for different colors)
    var colorMappings: [ColorMapping] = []

    enum JobType: String {
        case raster = "Raster"
        case vector = "Vector"
        case combined = "Combined"
    }

    /// Parse options from CUPS options string
    static func parse(from optionsString: String) -> JobOptions {
        var options = JobOptions()

        // Parse using CUPS API
        var cupsOptions: UnsafeMutablePointer<CupsOption>?
        let numOptions = cups_parse_options(optionsString, 0, &cupsOptions)

        defer {
            if let opts = cupsOptions {
                cups_free_options(numOptions, opts)
            }
        }

        guard numOptions > 0, let opts = cupsOptions else {
            return options
        }

        // Helper to get option value
        func getOption(_ name: String) -> String? {
            if let value = cups_get_option(name, numOptions, opts) {
                return String(cString: value)
            }
            return nil
        }

        // Resolution
        if let res = getOption("Resolution")?.replacingOccurrences(of: "dpi", with: ""),
           let dpi = Int(res) {
            options.resolution = dpi
        }

        // Raster settings
        if let power = getOption("RasterPower").flatMap({ Int($0) }) {
            options.rasterPower = max(1, min(100, power))
        }
        if let speed = getOption("RasterSpeed").flatMap({ Int($0) }) {
            options.rasterSpeed = max(1, min(100, speed))
        }

        // Vector settings
        if let power = getOption("VectorPower").flatMap({ Int($0) }) {
            options.vectorPower = max(0, min(100, power))
        }
        if let speed = getOption("VectorSpeed").flatMap({ Int($0) }) {
            options.vectorSpeed = max(1, min(100, speed))
        }
        if let freq = getOption("VectorFrequency").flatMap({ Int($0) }) {
            options.vectorFrequency = max(1, min(5000, freq))
        }

        // Focus
        if let focusValue = getOption("Focus").flatMap({ Int($0) }) {
            options.focus = max(-500, min(500, focusValue))
        }

        // Job type
        if let typeStr = getOption("JobType"),
           let type = JobType(rawValue: typeStr) {
            options.jobType = type
        }

        // Engrave direction
        if let bottomUp = getOption("EngraveBottomUp") {
            options.engraveBottomUp = (bottomUp == "true" || bottomUp == "1")
        }

        // Autofocus
        if let af = getOption("AutoFocus") {
            options.autofocus = (af == "true" || af == "1")
        }

        return options
    }
}

/// Color mapping for different speed/power per color
struct ColorMapping {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    var power: Int
    var speed: Int
    var frequency: Int

    /// Standard Epilog color mapping colors
    static let standardColors: [(UInt8, UInt8, UInt8)] = [
        (255, 0, 0),     // Red
        (0, 255, 0),     // Green
        (0, 0, 255),     // Blue
        (0, 255, 255),   // Cyan
        (255, 255, 0),   // Yellow
        (255, 0, 255),   // Magenta
    ]
}
