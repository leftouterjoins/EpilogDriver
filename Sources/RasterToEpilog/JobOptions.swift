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

    // Raster encoding mode (1-bit bitmap vs 8-bit 3D greyscale)
    var rasterMode: RasterMode = .bitmap

    // How continuous tone becomes on/off dots in 1-bit mode
    var dither: DitherMode = .none

    // Test frame: trace the outline of where the job will land, so material
    // can be positioned before committing to a real run
    var testFrame: TestFrameMode = .off

    /// Selected page size in PostScript points, read from the PPD. Used to
    /// scale down documents whose page is larger than the bed, which happens
    /// whenever an application exports at one point per pixel.
    var pageWidthPoints: Double = 0
    var pageHeightPoints: Double = 0

    var hasPageSize: Bool { pageWidthPoints > 0 && pageHeightPoints > 0 }

    /// How to run a positioning pass instead of the real job
    enum TestFrameMode: String {
        /// Normal job
        case off = "Off"
        /// Trace the bounding box with the laser off - motion only
        case trace = "Trace"
        /// Trace the bounding box at low power, leaving a faint mark
        case mark = "Mark"

        /// Power and speed for the framing pass.
        ///
        /// Trace uses zero power deliberately. With the laser off the lid
        /// interlock still allows head movement, so the operator can leave the
        /// window open and watch the outline against the material while placing
        /// it - which is the entire point of the pass, and how Epilog's own
        /// driver behaves.
        ///
        /// Speed is moderate rather than maximum: at 100 the head crosses a
        /// two-foot rectangle in about a second, far too fast to follow.
        var vectorSettings: (power: Int, speed: Int) {
            switch self {
            case .off:   return (0, 50)
            case .trace: return (0, 40)
            case .mark:  return (8, 40)
            }
        }
    }

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

        // Focus (PPD values are in mm, convert to Epilog units: 1mm ≈ 40 units)
        if let focusMm = getOption("Focus").flatMap({ Int($0) }) {
            let focusUnits = focusMm * 40  // Convert mm to Epilog units
            options.focus = max(-500, min(500, focusUnits))
        }

        // Parse color-specific vector settings
        options.colorMappings = parseColorMappings(getOption: getOption, defaultOptions: options)

        // Job type
        if let typeStr = getOption("JobType"),
           let type = JobType(rawValue: typeStr) {
            options.jobType = type
        }

        // Raster encoding mode
        if let modeStr = getOption("RasterMode"),
           let mode = RasterMode(rawValue: modeStr) {
            options.rasterMode = mode
        }

        // Dithering
        if let ditherStr = getOption("Dithering"),
           let d = DitherMode(rawValue: ditherStr) {
            options.dither = d
        }

        // Test frame (material positioning pass)
        if let frameStr = getOption("TestFrame"),
           let frame = TestFrameMode(rawValue: frameStr) {
            options.testFrame = frame
        }

        // Page size, resolved through the PPD so it works for both models and
        // for custom sizes without hardcoding any bed dimensions here.
        if let size = resolvePageSize(named: getOption("PageSize")) {
            options.pageWidthPoints = size.width
            options.pageHeightPoints = size.height
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

    /// Look up a page size in the PPD CUPS handed us via $PPD.
    ///
    /// Reading the PPD rather than hardcoding bed dimensions means this works
    /// for both Zing models, and for any custom size the user defines, without
    /// the driver needing to know which machine it is talking to.
    private static func resolvePageSize(named name: String?) -> (width: Double, height: Double)? {
        guard let ppdPath = ProcessInfo.processInfo.environment["PPD"],
              let text = try? String(contentsOfFile: ppdPath, encoding: .isoLatin1) else {
            return nil
        }

        // Fall back to the PPD's own default when the option is absent.
        var wanted = name
        if wanted == nil || wanted?.isEmpty == true {
            wanted = matchFirst(in: text, pattern: "^\\*DefaultPageSize:\\s*(\\S+)")
        }
        guard let pageName = wanted else { return nil }

        // A custom size carries its dimensions in the option value itself,
        // e.g. Custom.1728x864 - there is no PaperDimension line for it.
        if pageName.hasPrefix("Custom.") {
            let dims = pageName.dropFirst("Custom.".count).split(separator: "x")
            if dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]) {
                return (w, h)
            }
        }

        let escaped = NSRegularExpression.escapedPattern(for: pageName)
        guard let dims = matchFirst(in: text,
                                    pattern: "^\\*PaperDimension\\s+\(escaped):\\s*\"([^\"]+)\"") else {
            return nil
        }
        let parts = dims.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// First capture group of the first line matching `pattern`.
    private static func matchFirst(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }

    /// Parse color-specific vector settings from CUPS options
    private static func parseColorMappings(
        getOption: (String) -> String?,
        defaultOptions: JobOptions
    ) -> [ColorMapping] {
        // Color names and their RGB values
        let colorDefs: [(name: String, r: UInt8, g: UInt8, b: UInt8)] = [
            ("Red", 255, 0, 0),
            ("Green", 0, 255, 0),
            ("Blue", 0, 0, 255),
            ("Cyan", 0, 255, 255),
            ("Yellow", 255, 255, 0),
            ("Magenta", 255, 0, 255),
        ]

        var mappings: [ColorMapping] = []

        for (name, r, g, b) in colorDefs {
            // Get color-specific options (nil or "Default" means use global default)
            let powerStr = getOption("\(name)Power")
            let speedStr = getOption("\(name)Speed")
            let freqStr = getOption("\(name)Frequency")

            // Parse power (special handling for "Default" and "0" = skip)
            let power: Int?
            if let ps = powerStr, ps != "Default" {
                power = Int(ps)
            } else {
                power = nil  // Use default
            }

            // Parse speed
            let speed: Int?
            if let ss = speedStr, ss != "Default" {
                speed = Int(ss)
            } else {
                speed = nil
            }

            // Parse frequency
            let frequency: Int?
            if let fs = freqStr, fs != "Default" {
                frequency = Int(fs)
            } else {
                frequency = nil
            }

            // Only add mapping if at least one setting is specified (not default)
            if power != nil || speed != nil || frequency != nil {
                mappings.append(ColorMapping(
                    red: r,
                    green: g,
                    blue: b,
                    power: power ?? defaultOptions.vectorPower,
                    speed: speed ?? defaultOptions.vectorSpeed,
                    frequency: frequency ?? defaultOptions.vectorFrequency
                ))
            }
        }

        return mappings
    }
}

/// Color mapping for different speed/power per color
struct ColorMapping: Equatable {
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

    /// Check if this mapping matches a given color (exact match)
    func matches(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        return red == r && green == g && blue == b
    }

    /// Check if power is set to skip (0)
    var shouldSkip: Bool {
        return power == 0
    }
}

extension JobOptions {
    /// Find color mapping for a specific RGB color
    /// Returns nil if no specific mapping exists (use default settings)
    func colorMapping(for r: UInt8, g: UInt8, b: UInt8) -> ColorMapping? {
        return colorMappings.first { $0.matches(r: r, g: g, b: b) }
    }

    /// Get vector settings for a color, falling back to defaults
    func vectorSettings(for r: UInt8, g: UInt8, b: UInt8) -> (power: Int, speed: Int, frequency: Int, skip: Bool) {
        if let mapping = colorMapping(for: r, g: g, b: b) {
            return (mapping.power, mapping.speed, mapping.frequency, mapping.shouldSkip)
        }
        return (vectorPower, vectorSpeed, vectorFrequency, false)
    }
}
