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

    /// Capture the settings a project is currently using.
    ///
    /// This is how a material entry should come into existence: you work out
    /// numbers that cut cleanly on a scrap, and then you save them. Anything
    /// else is somebody's guess about your machine, your tube's age and your
    /// supplier's plywood.
    public init(capturing project: LaserProject, name: String, thicknessInches: Double) {
        let cut = project.layers.first { $0.operation == .cut }
        let engrave = project.layers.first { $0.operation == .engrave }
        let score = project.layers.first { $0.operation == .score }

        self.init(name: name,
                  thicknessInches: thicknessInches,
                  referenceWatts: project.machine.watts,
                  cutPower: cut?.power ?? 100,
                  cutSpeed: cut?.speed ?? 15,
                  cutFrequency: cut?.frequency ?? 500,
                  cutPasses: cut?.passes ?? 1,
                  engravePower: engrave?.power ?? 60,
                  engraveSpeed: engrave?.speed ?? 100,
                  engraveDither: engrave?.dither ?? .none,
                  scorePower: score?.power ?? 20,
                  scoreSpeed: score?.speed ?? 60)
    }

}
