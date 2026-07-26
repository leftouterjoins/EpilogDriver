/*
 * PJLGenerator.swift - Generate PJL/PCL headers and footers
 *
 * Ported from VisiCut's EpilogCutter.java generatePjlHeader() and generatePjlFooter()
 */

import Foundation

/// Generates PJL (Printer Job Language) headers and footers for Epilog lasers
struct PJLGenerator {
    /// ASCII escape character
    static let ESC: UInt8 = 0x1B

    /// Generate the PJL/PCL header for an Epilog job
    /// Ported from EpilogCutter.java:165-200
    static func generateHeader(
        title: String,
        resolution: Int,
        autofocus: Bool,
        copies: Int = 1
    ) -> Data {
        var data = Data()

        // Universal Exit Language (UEL) + PJL job start
        // \033%-12345X@PJL JOB NAME=<title>\r\n
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "%-12345X@PJL JOB NAME=\(title)\r\n".utf8)

        // Enter PCL mode
        // \033E@PJL ENTER LANGUAGE=PCL\r\n
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "E@PJL ENTER LANGUAGE=PCL\r\n".utf8)

        // Number of copies
        // \033&l<copies>X
        // Standard PCL, and present in Epilog's own driver. Previously the
        // copies argument CUPS passes was parsed and then discarded, so asking
        // for more than one produced exactly one.
        if copies > 1 {
            data.append(contentsOf: [ESC])
            data.append(contentsOf: "&l\(copies)X".utf8)
        }

        // Autofocus setting
        // \033&y1A (on) or \033&y0A (off)
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&y\(autofocus ? 1 : 0)A".utf8)

        // Focus = 0
        // \033&y0C
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&y0C".utf8)

        // Unknown but required
        // \033&y0Z
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&y0Z".utf8)

        // Left offset = 0
        // \033&l0U
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&l0U".utf8)

        // Top offset = 0
        // \033&l0Z
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&l0Z".utf8)

        // Resolution (units per inch)
        // \033&u<DPI>D
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&u\(resolution)D".utf8)

        // X position = 0
        // \033*p0X
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*p0X".utf8)

        // Y position = 0
        // \033*p0Y
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*p0Y".utf8)

        return data
    }

    /// Per-colour power/speed table.
    ///
    /// Decoded from Epilog's own driver, which emits, for each mapped colour:
    ///
    ///     ESC &z<rgb>C   select colour, 24-bit packed R<<16 | G<<8 | B
    ///     ESC &y<n>P     power for that colour
    ///     ESC &z<n>S     speed for that colour
    ///
    /// and closes the table with `ESC &z0C` to revert to the job defaults.
    ///
    /// This drives per-colour *engraving*; per-colour cutting is already handled
    /// by the HPGL properties on each vector path. Left off by default: the
    /// commands themselves are read directly out of their driver, but nothing
    /// here has been confirmed against hardware.
    static func generateColorTable(_ mappings: [ColorMapping]) -> Data {
        var data = Data()
        guard !mappings.isEmpty else { return data }

        for m in mappings {
            let rgb = (Int(m.red) << 16) | (Int(m.green) << 8) | Int(m.blue)

            data.append(contentsOf: [ESC])
            data.append(contentsOf: "&z\(rgb)C".utf8)

            data.append(contentsOf: [ESC])
            data.append(contentsOf: "&y\(m.power)P".utf8)

            data.append(contentsOf: [ESC])
            data.append(contentsOf: "&z\(m.speed)S".utf8)
        }

        // End the table; subsequent power/speed apply to everything else.
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&z0C".utf8)

        return data
    }

    /// Generate the PJL/PCL footer for an Epilog job
    /// Ported from EpilogCutter.java:203-216
    static func generateFooter() -> Data {
        var data = Data()

        // PCL Reset
        // \033E
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "E".utf8)

        // Universal Exit Language
        // \033%-12345X
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "%-12345X".utf8)

        // End job
        // @PJL EOJ \r\n
        data.append(contentsOf: "@PJL EOJ \r\n".utf8)

        // Pad with 4096 null bytes (required by Epilog)
        data.append(contentsOf: [UInt8](repeating: 0, count: 4096))

        return data
    }
}
