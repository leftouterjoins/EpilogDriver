/*
 * LaserMachine.swift - What is on the other end of the wire
 */

import Foundation
import CoreGraphics

/// A laser and its physical limits.
public struct LaserMachine: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String

    /// Usable bed, in inches.
    public var bedWidthInches: Double
    public var bedHeightInches: Double

    /// Tube wattage. Nothing in the protocol carries it; it is here because
    /// power settings are only meaningful next to it, and material presets
    /// worked out on a 30W machine will overcook on a 60W one.
    public var watts: Int

    /// Network address, for sending over LPD.
    public var host: String
    public var port: Int

    /// Resolutions the machine accepts.
    public var resolutions: [Int]

    public init(id: String, name: String,
                bedWidthInches: Double, bedHeightInches: Double,
                watts: Int, host: String = "", port: Int = 515,
                resolutions: [Int] = LaserMachine.standardResolutions) {
        self.id = id
        self.name = name
        self.bedWidthInches = bedWidthInches
        self.bedHeightInches = bedHeightInches
        self.watts = watts
        self.host = host
        self.port = port
        self.resolutions = resolutions
    }

    /// Bed size in PostScript points, which is the unit the project works in.
    public var bedSizePoints: CGSize {
        CGSize(width: bedWidthInches * 72, height: bedHeightInches * 72)
    }

    public static let standardResolutions = [100, 200, 250, 400, 500, 1000]

    // The Zing family. Bed sizes are the published usable engraving areas.
    public static let zing16 = LaserMachine(id: "zing16", name: "Epilog Zing 16",
                                            bedWidthInches: 16, bedHeightInches: 12,
                                            watts: 30)
    public static let zing24 = LaserMachine(id: "zing24", name: "Epilog Zing 24",
                                            bedWidthInches: 24, bedHeightInches: 12,
                                            watts: 40)

    public static let presets: [LaserMachine] = [zing24, zing16]

    /// A machine the user has described themselves.
    public static func custom(name: String, width: Double, height: Double,
                              watts: Int) -> LaserMachine {
        LaserMachine(id: "custom", name: name,
                     bedWidthInches: width, bedHeightInches: height, watts: watts)
    }
}

/// A remembered set of power and speed values for a material.
///
/// The single most valuable thing a laser operator owns is a table of settings
/// that are known to work, because arriving at one costs scrap and time.
public struct MaterialPreset: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String

    /// Nominal thickness in inches, for the operator's reference and to pick
    /// between two entries for the same material.
    public var thicknessInches: Double

    /// Machine wattage these numbers were established on.
    public var referenceWatts: Int

    public var cutPower: Int
    public var cutSpeed: Int
    public var cutFrequency: Int
    public var cutPasses: Int

    public var engravePower: Int
    public var engraveSpeed: Int
    public var engraveDither: DitherMode

    public var scorePower: Int
    public var scoreSpeed: Int

    public var notes: String

    public init(id: UUID = UUID(), name: String, thicknessInches: Double,
                referenceWatts: Int = 40,
                cutPower: Int, cutSpeed: Int, cutFrequency: Int = 500, cutPasses: Int = 1,
                engravePower: Int, engraveSpeed: Int, engraveDither: DitherMode = .none,
                scorePower: Int = 20, scoreSpeed: Int = 60,
                notes: String = "") {
        self.id = id
        self.name = name
        self.thicknessInches = thicknessInches
        self.referenceWatts = referenceWatts
        self.cutPower = cutPower
        self.cutSpeed = cutSpeed
        self.cutFrequency = cutFrequency
        self.cutPasses = cutPasses
        self.engravePower = engravePower
        self.engraveSpeed = engraveSpeed
        self.engraveDither = engraveDither
        self.scorePower = scorePower
        self.scoreSpeed = scoreSpeed
        self.notes = notes
    }

    /// Rough rescale when the machine is not the one the numbers came from.
    ///
    /// Cutting depth tracks energy per unit length, so half the wattage needs
    /// roughly twice the dwell. This only ever adjusts speed, never power past
    /// 100, and it is a starting point for a test cut - not a promise.
    public func adjusted(forWatts watts: Int) -> MaterialPreset {
        guard watts > 0, referenceWatts > 0, watts != referenceWatts else { return self }
        let ratio = Double(watts) / Double(referenceWatts)
        var copy = self
        copy.cutSpeed = max(1, min(100, Int((Double(cutSpeed) * ratio).rounded())))
        copy.engraveSpeed = max(1, min(100, Int((Double(engraveSpeed) * ratio).rounded())))
        copy.scoreSpeed = max(1, min(100, Int((Double(scoreSpeed) * ratio).rounded())))
        copy.referenceWatts = watts
        return copy
    }

    /// Starting points, not gospel. Every one of these wants a test cut on
    /// scrap before it goes near work that matters - tube age, lens condition,
    /// focus and the material's own variation all move these numbers.
    public static let builtIn: [MaterialPreset] = [
        MaterialPreset(name: "Plywood", thicknessInches: 0.125, referenceWatts: 40,
                       cutPower: 100, cutSpeed: 12, cutFrequency: 500,
                       engravePower: 60, engraveSpeed: 100, engraveDither: .floydSteinberg,
                       scorePower: 25, scoreSpeed: 60,
                       notes: "Baltic birch. Grain and glue lines vary; test on an offcut."),
        MaterialPreset(name: "Plywood", thicknessInches: 0.25, referenceWatts: 40,
                       cutPower: 100, cutSpeed: 6, cutFrequency: 500, cutPasses: 2,
                       engravePower: 60, engraveSpeed: 100, engraveDither: .floydSteinberg,
                       scorePower: 25, scoreSpeed: 60,
                       notes: "Two passes cut cleaner than one slow pass."),
        MaterialPreset(name: "Acrylic (cast)", thicknessInches: 0.125, referenceWatts: 40,
                       cutPower: 100, cutSpeed: 10, cutFrequency: 5000,
                       engravePower: 40, engraveSpeed: 100, engraveDither: .none,
                       scorePower: 20, scoreSpeed: 70,
                       notes: "High frequency for a polished edge. Cast frosts white when "
                            + "engraved; extruded stays clear and cuts faster."),
        MaterialPreset(name: "Acrylic (cast)", thicknessInches: 0.25, referenceWatts: 40,
                       cutPower: 100, cutSpeed: 5, cutFrequency: 5000,
                       engravePower: 40, engraveSpeed: 100, engraveDither: .none,
                       scorePower: 20, scoreSpeed: 70, notes: ""),
        MaterialPreset(name: "Hardwood", thicknessInches: 0.25, referenceWatts: 40,
                       cutPower: 100, cutSpeed: 5, cutFrequency: 500, cutPasses: 2,
                       engravePower: 70, engraveSpeed: 100, engraveDither: .floydSteinberg,
                       scorePower: 30, scoreSpeed: 55,
                       notes: "Dense species (maple, oak) need the slower end."),
        MaterialPreset(name: "Leather", thicknessInches: 0.09, referenceWatts: 40,
                       cutPower: 70, cutSpeed: 20, cutFrequency: 500,
                       engravePower: 35, engraveSpeed: 100, engraveDither: .stucki,
                       scorePower: 15, scoreSpeed: 70,
                       notes: "Veg-tan only. Chrome-tanned leather releases chlorine gas."),
        MaterialPreset(name: "Cardstock", thicknessInches: 0.012, referenceWatts: 40,
                       cutPower: 35, cutSpeed: 40, cutFrequency: 500,
                       engravePower: 20, engraveSpeed: 100, engraveDither: .ordered,
                       scorePower: 8, scoreSpeed: 80,
                       notes: "Scores well for folding. Watch for flare-ups."),
        MaterialPreset(name: "Anodised aluminium", thicknessInches: 0.06, referenceWatts: 40,
                       cutPower: 0, cutSpeed: 100, cutFrequency: 500, cutPasses: 1,
                       engravePower: 100, engraveSpeed: 30, engraveDither: .none,
                       scorePower: 0, scoreSpeed: 100,
                       notes: "Marks the anodising white. A CO2 laser cannot cut metal - "
                            + "cut power is 0 deliberately."),
        MaterialPreset(name: "Slate", thicknessInches: 0.3, referenceWatts: 40,
                       cutPower: 0, cutSpeed: 100, cutFrequency: 500,
                       engravePower: 100, engraveSpeed: 40, engraveDither: .jarvis,
                       scorePower: 0, scoreSpeed: 100,
                       notes: "Engrave only. Wipe with a damp cloth afterwards."),
        MaterialPreset(name: "Glass", thicknessInches: 0.125, referenceWatts: 40,
                       cutPower: 0, cutSpeed: 100, cutFrequency: 500,
                       engravePower: 60, engraveSpeed: 45, engraveDither: .jarvis,
                       scorePower: 0, scoreSpeed: 100,
                       notes: "Engrave only, and dither: solid areas chip. A wet paper "
                            + "towel over the surface gives a smoother frost."),
    ]
}
