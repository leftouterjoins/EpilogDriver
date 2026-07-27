/*
 * JobOptions.swift - Laser parameters for a single job
 *
 * Deliberately free of CUPS: the CUPS filter fills this in from its options
 * string (see RasterToEpilog/JobOptions+CUPS.swift), and the application fills
 * it in from its own project model. Everything downstream reads only this.
 */

import Foundation

/// Epilog job options
public struct JobOptions {
    // Resolution
    public var resolution: Int = 500  // DPI: 100, 200, 250, 400, 500, 1000

    // Raster engraving settings
    public var rasterPower: Int = 100      // 1-100%
    public var rasterSpeed: Int = 100      // 1-100%

    // Vector cutting settings
    public var vectorPower: Int = 100      // 0-100%
    public var vectorSpeed: Int = 100      // 1-100%
    public var vectorFrequency: Int = 5000 // 1-5000 Hz

    // Focus adjustment (in Epilog units, not mm)
    // Each unit = 0.0252mm, range: -500 to +500
    public var focus: Int = 0

    // Job type
    public var jobType: JobType = .combined

    // Raster encoding mode (1-bit bitmap vs 8-bit 3D greyscale)
    public var rasterMode: RasterMode = .bitmap

    // How continuous tone becomes on/off dots in 1-bit mode
    public var dither: DitherMode = .none

    // Test frame: trace the outline of where the job will land, so material
    // can be positioned before committing to a real run
    public var testFrame: TestFrameMode = .off

    /// Mirror the job. Needed when engraving the back face of clear material,
    /// where the artwork is read through the substrate.
    public var mirror: MirrorMode = .off

    /// Reorder vector paths before cutting
    public var vectorSorting: Bool = true

    /// Send a per-colour power/speed table so raster areas of different colours
    /// engrave differently
    public var colorMapping: Bool = false

    /// Material dimensions in points, if the operator declared them. Used to
    /// warn when artwork will not fit and as the reference for centring.
    public var pieceWidthPoints: Double = 0
    public var pieceHeightPoints: Double = 0
    public var hasPieceSize: Bool { pieceWidthPoints > 0 && pieceHeightPoints > 0 }

    /// Where the artwork sits within the page
    public var position: PositionMode = .topLeft

    public enum MirrorMode: String {
        case off = "Off"
        case horizontal = "Horizontal"
        case vertical = "Vertical"
        case both = "Both"

        public var flipX: Bool { self == .horizontal || self == .both }
        public var flipY: Bool { self == .vertical || self == .both }
    }

    public enum PositionMode: String {
        /// Artwork keeps the coordinates the document gave it
        case topLeft = "TopLeft"
        /// Artwork is centred on the material, or on the page if no piece size
        /// was given. This centres on the bed, not on the head's current
        /// position - that is a machine-side behaviour we cannot drive.
        case center = "Center"
    }

    /// Selected page size in PostScript points, read from the PPD. Used to
    /// scale down documents whose page is larger than the bed, which happens
    /// whenever an application exports at one point per pixel.
    public var pageWidthPoints: Double = 0
    public var pageHeightPoints: Double = 0

    public var hasPageSize: Bool { pageWidthPoints > 0 && pageHeightPoints > 0 }

    /// How to run a positioning pass instead of the real job
    public enum TestFrameMode: String {
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
        public var vectorSettings: (power: Int, speed: Int) {
            switch self {
            case .off:   return (0, 50)
            case .trace: return (0, 40)
            case .mark:  return (8, 40)
            }
        }
    }

    // Raster direction
    public var engraveBottomUp: Bool = false

    // Autofocus
    public var autofocus: Bool = false

    // Color mapping settings (optional, for different colors)
    public var colorMappings: [ColorMapping] = []

    public enum JobType: String {
        case raster = "Raster"
        case vector = "Vector"
        case combined = "Combined"
    }

    public init() {}
}

/// Color mapping for different speed/power per color
public struct ColorMapping: Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public var power: Int
    public var speed: Int
    public var frequency: Int

    public init(red: UInt8, green: UInt8, blue: UInt8,
                power: Int, speed: Int, frequency: Int) {
        self.red = red
        self.green = green
        self.blue = blue
        self.power = power
        self.speed = speed
        self.frequency = frequency
    }

    /// Standard Epilog color mapping colors
    public static let standardColors: [(UInt8, UInt8, UInt8)] = [
        (255, 0, 0),     // Red
        (0, 255, 0),     // Green
        (0, 0, 255),     // Blue
        (0, 255, 255),   // Cyan
        (255, 255, 0),   // Yellow
        (255, 0, 255),   // Magenta
    ]

    /// Check if this mapping matches a given color (exact match)
    public func matches(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        return red == r && green == g && blue == b
    }

    /// Check if power is set to skip (0)
    public var shouldSkip: Bool {
        return power == 0
    }
}

extension JobOptions {
    /// Find color mapping for a specific RGB color
    /// Returns nil if no specific mapping exists (use default settings)
    public func colorMapping(for r: UInt8, g: UInt8, b: UInt8) -> ColorMapping? {
        return colorMappings.first { $0.matches(r: r, g: g, b: b) }
    }

    /// Get vector settings for a color, falling back to defaults
    public func vectorSettings(for r: UInt8, g: UInt8, b: UInt8)
        -> (power: Int, speed: Int, frequency: Int, skip: Bool) {
        if let mapping = colorMapping(for: r, g: g, b: b) {
            return (mapping.power, mapping.speed, mapping.frequency, mapping.shouldSkip)
        }
        return (vectorPower, vectorSpeed, vectorFrequency, false)
    }
}
