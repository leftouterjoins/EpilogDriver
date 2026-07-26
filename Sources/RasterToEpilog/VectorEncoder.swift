/*
 * VectorEncoder.swift - HPGL vector command generation for Epilog
 *
 * Ported from VisiCut's EpilogCutter.java generateVectorPCL()
 */

import Foundation
import CoreGraphics

/// Represents a vector command for laser cutting
enum VectorCommand {
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
enum VectorMaskStyle {
    case stroke(widthPx: CGFloat)
    case fill
}

/// A collection of vector paths for cutting
struct VectorPath {
    var commands: [VectorCommand] = []

    /// Stroke color from PDF (for color mapping)
    var strokeColor: (r: CGFloat, g: CGFloat, b: CGFloat)?

    /// Which pixels this path covers, for excluding it from the raster
    var maskStyle: VectorMaskStyle = .stroke(widthPx: 1)

    /// Add a move command (pen up)
    mutating func moveTo(x: Int, y: Int) {
        commands.append(.moveTo(x: x, y: y))
    }

    /// Add a line command (pen down, cutting)
    mutating func lineTo(x: Int, y: Int) {
        commands.append(.lineTo(x: x, y: y))
    }

    /// Set cutting properties
    mutating func setProperty(colorIndex: Int = 0, power: Int, speed: Int,
                              frequency: Int, focus: Int = 0) {
        commands.append(.setProperty(colorIndex: colorIndex, power: power, speed: speed,
                                     frequency: frequency, focus: focus))
    }
}

/// Encodes vector paths to HPGL format for Epilog laser cutters
struct VectorEncoder {
    /// ASCII escape character
    static let ESC: UInt8 = 0x1B

    /// Generate a single HPGL vector section containing every path.
    /// Ported from EpilogCutter.java:723-796
    ///
    /// All paths must live inside one `ESC %1B ... IN;` block. Emitting a fresh
    /// block per path re-issues HPGL's Initialize between paths, which resets
    /// plotter state mid-job and makes the Epilog skip the vector pass entirely.
    static func generateVectorHPGL(paths: [VectorPath]) -> Data {
        var data = Data()

        // Enter HPGL mode
        // \033%1B
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "%1B".utf8)

        // Plotter initialisation, matching the sequence Epilog's own Windows
        // driver carries in its printer description: Begin Plot, Initialize,
        // Select Pen 0. LibLaserCut sends only IN;.
        data.append(contentsOf: "BP;IN;SP0;".utf8)

        // Power/speed/frequency state persists across paths so repeated
        // property commands are suppressed, exactly as the reference does.
        var currentColorIndex: Int?
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

                // Field order follows Epilog's own driver, whose format string
                // is "YC#d;YP#d;ZS#d;XR#d;WF#d;" - colour, power, speed,
                // frequency, focus.

                // Colour/pen selector: YC<index>;
                if currentColorIndex != colorIndex {
                    data.append(contentsOf: "YC\(colorIndex);".utf8)
                    currentColorIndex = colorIndex
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

                // Frequency: XR<4-digit freq>;
                if currentFrequency != frequency {
                    data.append(contentsOf: String(format: "XR%04d;", frequency).utf8)
                    currentFrequency = frequency
                }

                // Focus: WF<focus>;
                if currentFocus != focus {
                    data.append(contentsOf: "WF\(focus);".utf8)
                    currentFocus = focus
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

        // Leave HPGL and return to PCL. Epilog's driver pairs \033%1B with
        // \033%0B; LibLaserCut never exits, and drops straight into the PCL
        // reset in the footer.
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "%0B".utf8)

        return data
    }

    /// Generate a dummy vector section (required at end of raster-only jobs)
    /// Ported from EpilogCutter.java:712-720
    static func generateDummyVector() -> Data {
        var data = Data()

        // Enter HPGL mode
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "%1B".utf8)

        // Same initialisation as a real vector section
        data.append(contentsOf: "BP;IN;SP0;".utf8)

        // Reset focus
        data.append(contentsOf: "WF0;".utf8)

        // Return to PCL
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "%0B".utf8)

        return data
    }

    /// Generate vector commands for a simple rectangle (for testing)
    static func generateRectangle(
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
func mmToFocus(_ mm: Float) -> Int {
    // From EpilogCutter.java mm2focus()
    // 1 unit = 1/39.7 mm = 0.0252mm
    return Int(mm * 39.7)
}

/// Convert Epilog focus units to millimeters
func focusToMM(_ focus: Int) -> Float {
    return Float(focus) / 39.7
}
