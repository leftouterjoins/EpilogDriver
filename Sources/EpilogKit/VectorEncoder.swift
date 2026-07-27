/*
 * VectorEncoder.swift - HPGL vector command generation for Epilog
 *
 * Ported from VisiCut's EpilogCutter.java generateVectorPCL()
 */

import Foundation
import CoreGraphics

/// Represents a vector command for laser cutting
public enum VectorCommand {
    case moveTo(x: Int, y: Int)
    case lineTo(x: Int, y: Int)
    /// `colorIndex` is Epilog's pen/colour selector, emitted as YC. Their driver
    /// leads every property change with it; LibLaserCut omits it entirely.
    case setProperty(colorIndex: Int, power: Int, speed: Int, frequency: Int, focus: Int)
}

/// How a cut path should be excluded from the engraving.
///
/// Whatever the cutter is going to burn must not also be engraved. Which pixels
/// that covers depends on how the shape was painted: a stroked outline occupies
/// only its stroke, while a filled shape routed to the cutter by its colour is
/// wanted as a cut and not as a filled-in engraving.
public enum VectorMaskStyle {
    case stroke(widthPx: CGFloat)
    case fill
}

/// A collection of vector paths for cutting
public struct VectorPath {
    public init() {}

    public var commands: [VectorCommand] = []

    /// Stroke color from PDF (for color mapping)
    public var strokeColor: (r: CGFloat, g: CGFloat, b: CGFloat)?

    /// Which pixels this path covers, for excluding it from the raster
    public var maskStyle: VectorMaskStyle = .stroke(widthPx: 1)

    /// Add a move command (pen up)
    public mutating func moveTo(x: Int, y: Int) {
        commands.append(.moveTo(x: x, y: y))
    }

    /// Add a line command (pen down, cutting)
    public mutating func lineTo(x: Int, y: Int) {
        commands.append(.lineTo(x: x, y: y))
    }

    /// Set cutting properties
    public mutating func setProperty(colorIndex: Int = 0, power: Int, speed: Int,
                              frequency: Int, focus: Int = 0) {
        commands.append(.setProperty(colorIndex: colorIndex, power: power, speed: speed,
                                     frequency: frequency, focus: focus))
    }
}

/// Encodes vector paths to HPGL format for Epilog laser cutters
public struct VectorEncoder {
    /// ASCII escape character
    public static let ESC: UInt8 = 0x1B

    /// Generate a single HPGL vector section containing every path.
    /// Ported from EpilogCutter.java:723-796
    ///
    /// All paths must live inside one `ESC %1B ... IN;` block. Emitting a fresh
    /// block per path re-issues HPGL's Initialize between paths, which resets
    /// plotter state mid-job and makes the Epilog skip the vector pass entirely.
    public static func generateVectorHPGL(paths: [VectorPath]) -> Data {
        var data = Data()

        // Enter HPGL mode
        // \033%1B
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "%1B".utf8)

        // Initialize - once, for the whole vector section.
        //
        // Deliberately just IN;. Epilog's printer description carries
        // ";BP;IN;SP0;", which was tried and stopped the machine cutting: SP0 is
        // HPGL for "deselect the pen", so pen-down moves have no pen and nothing
        // fires. That string is a plotter reset sequence, not an init.
        data.append(contentsOf: "IN;".utf8)

        // Power/speed/frequency state persists across paths so repeated
        // property commands are suppressed, exactly as the reference does.
        var currentPower: Int?
        var currentSpeed: Int?
        var currentFrequency: Int?
        var currentFocus: Int?
        var lastWasLineTo = false

        for cmd in paths.flatMap({ $0.commands }) {
            switch cmd {
            case .setProperty(let colorIndex, let power, let speed, let frequency, let focus):
                // Terminate any ongoing PD command
                if lastWasLineTo {
                    data.append(contentsOf: ";".utf8)
                    lastWasLineTo = false
                }

                // Order is WF, XR, YP, ZS. Epilog's driver uses
                // "YC#d;YP#d;ZS#d;XR#d;WF#d;" instead - leading with a YC pen
                // selector - and emitting that stopped the machine cutting. This
                // order is the one observed working on hardware; do not "correct"
                // it to match their driver without testing on a real machine.
                _ = colorIndex

                // Focus: WF<focus>;
                if currentFocus != focus {
                    data.append(contentsOf: "WF\(focus);".utf8)
                    currentFocus = focus
                }

                // Frequency: XR<4-digit freq>;
                if currentFrequency != frequency {
                    data.append(contentsOf: String(format: "XR%04d;", frequency).utf8)
                    currentFrequency = frequency
                }

                // Power: YP<3-digit power>;
                if currentPower != power {
                    data.append(contentsOf: String(format: "YP%03d;", power).utf8)
                    currentPower = power
                }

                // Speed: ZS<3-digit speed>;
                if currentSpeed != speed {
                    data.append(contentsOf: String(format: "ZS%03d;", speed).utf8)
                    currentSpeed = speed
                }

            case .moveTo(let x, let y):
                // Terminate any ongoing PD command
                if lastWasLineTo {
                    data.append(contentsOf: ";".utf8)
                    lastWasLineTo = false
                }

                // Pen up and move: PU<x>,<y>;
                data.append(contentsOf: "PU\(x),\(y);".utf8)

            case .lineTo(let x, let y):
                if lastWasLineTo {
                    // Continue existing PD command: ,<x>,<y>
                    data.append(contentsOf: ",\(x),\(y)".utf8)
                } else {
                    // Start new PD command: PD<x>,<y>
                    data.append(contentsOf: "PD\(x),\(y)".utf8)
                    lastWasLineTo = true
                }
            }
        }

        // Terminate final PD command if needed
        if lastWasLineTo {
            data.append(contentsOf: ";".utf8)
        }

        // Reset focus to 0
        data.append(contentsOf: "WF0;".utf8)

        return data
    }

    /// Generate a dummy vector section (required at end of raster-only jobs)
    /// Ported from EpilogCutter.java:712-720
    public static func generateDummyVector() -> Data {
        var data = Data()

        // Enter HPGL mode
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "%1B".utf8)

        // Initialize
        data.append(contentsOf: "IN;".utf8)

        // Reset focus
        data.append(contentsOf: "WF0;".utf8)

        return data
    }

    /// Generate vector commands for a simple rectangle (for testing)
    public static func generateRectangle(
        x: Int, y: Int,
        width: Int, height: Int,
        power: Int, speed: Int, frequency: Int
    ) -> VectorPath {
        var path = VectorPath()

        // Set cutting properties
        path.setProperty(power: power, speed: speed, frequency: frequency)

        // Move to starting corner
        path.moveTo(x: x, y: y)

        // Draw rectangle
        path.lineTo(x: x + width, y: y)
        path.lineTo(x: x + width, y: y + height)
        path.lineTo(x: x, y: y + height)
        path.lineTo(x: x, y: y)

        return path
    }
}

/// Convert millimeters to Epilog focus units
/// Each unit = 0.0252mm, range: -500 to +500
public func mmToFocus(_ mm: Float) -> Int {
    // From EpilogCutter.java mm2focus()
    // 1 unit = 1/39.7 mm = 0.0252mm
    return Int(mm * 39.7)
}

/// Convert Epilog focus units to millimeters
public func focusToMM(_ focus: Int) -> Float {
    return Float(focus) / 39.7
}
