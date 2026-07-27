/*
 * JobOptions+CUPS.swift - Fill in JobOptions from a CUPS options string
 *
 * This is the only part of option handling that knows CUPS exists. The model
 * itself lives in EpilogKit so the application can build one without dragging
 * in libcups.
 */

import Foundation
import CUPSBridge
import EpilogKit

extension JobOptions {
    /// Parse options from CUPS job options string (argv[5])
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

        // Mirroring
        if let m = getOption("Mirror").flatMap({ MirrorMode(rawValue: $0) }) {
            options.mirror = m
        }

        // Vector path ordering
        if let v = getOption("VectorSorting") {
            options.vectorSorting = (v == "true" || v == "On" || v == "1")
        }

        // Per-colour raster power/speed table
        if let c = getOption("ColorMapping") {
            options.colorMapping = (c == "true" || c == "On" || c == "1")
        }

        // Artwork placement
        if let p = getOption("Position").flatMap({ PositionMode(rawValue: $0) }) {
            options.position = p
        }

        // Material size, given in hundredths of an inch by the PPD so the option
        // keywords stay integers
        if let w = getOption("PieceWidth").flatMap({ Double($0) }),
           let h = getOption("PieceHeight").flatMap({ Double($0) }), w > 0, h > 0 {
            options.pieceWidthPoints = w * 72.0 / 100.0
            options.pieceHeightPoints = h * 72.0 / 100.0
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
