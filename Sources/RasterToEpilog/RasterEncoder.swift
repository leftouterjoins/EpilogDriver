/*
 * RasterEncoder.swift - PCL raster encoding with TIFF Packbits compression
 *
 * Ported from VisiCut's EpilogCutter.java generateRasterPCL() and generateRaster3dPCL()
 *
 * Supports two modes:
 * - Bitmap (1-bit): Standard engraving, uses *b2M compression
 * - Greyscale3D (8-bit): 3D engraving with power modulation, uses *b7MLT compression
 */

import Foundation

/// Raster encoding mode
enum RasterMode {
    /// 1-bit bitmap mode: each bit = on/off (standard engraving)
    /// Uses compression mode 2M
    case bitmap

    /// 8-bit greyscale mode: each byte = power level 0-255 (3D engraving)
    /// Uses compression mode 7MLT
    case greyscale3D
}

/// Encodes raster image data to Epilog PCL format with TIFF Packbits compression
struct RasterEncoder {
    /// ASCII escape character
    static let ESC: UInt8 = 0x1B

    /// Encode a line using TIFF Packbits (Run-Length Encoding)
    /// Ported from EpilogCutter.java:443-478
    static func packbitsEncode(_ line: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var idx = 0
        let r = line.count

        while idx < r {
            var p = idx + 1

            // Look for run of identical bytes (max 128)
            while p < r && p < idx + 128 && line[p] == line[idx] {
                p += 1
            }

            if p - idx >= 2 {
                // Run-length encode: (1 - count) followed by the byte
                // For count=2: 1-2 = -1 = 0xFF
                // For count=3: 1-3 = -2 = 0xFE, etc.
                result.append(UInt8(bitPattern: Int8(1 - (p - idx))))
                result.append(line[idx])
                idx = p
            } else {
                // Literal run: find non-repeating bytes (max 128)
                p = idx
                while p < r && p < idx + 127 &&
                      (p + 1 == r || line[p] != line[p + 1]) {
                    p += 1
                }
                // Literal count - 1
                result.append(UInt8(p - idx - 1))
                while idx < p {
                    result.append(line[idx])
                    idx += 1
                }
            }
        }

        return result
    }

    /// Generate PCL raster header for an engrave job
    /// Ported from EpilogCutter.java:615-646 (bitmap) and 488-513 (3D)
    static func generateRasterHeader(
        resolution: Int,
        power: Int,
        speed: Int,
        focus: Int,
        width: Int,
        height: Int,
        engraveBottomUp: Bool,
        mode: RasterMode = .bitmap
    ) -> Data {
        var data = Data()

        // PCL/RasterGraphics resolution
        // \033*t<DPI>R
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*t\(resolution)R".utf8)

        // Raster Orientation: Printed in current direction
        // \033*r0F
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*r0F".utf8)

        // Raster power (0-100)
        // \033&y<power>P
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&y\(power)P".utf8)

        // Raster speed (0-100)
        // \033&z<speed>S
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&z\(speed)S".utf8)

        // Focus
        // \033&y<focus>A
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&y\(focus)A".utf8)

        // Height in pixels
        // \033*r<height>T
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*r\(height)T".utf8)

        // Width in pixels
        // \033*r<width>S
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*r\(width)S".utf8)

        // Raster compression mode
        // 2M = TIFF encoding (bitmap: 1=dot, 0=no dot)
        // 7MLT = TIFF encoding, 3d-mode (0=no power, 255=full power)
        data.append(contentsOf: [ESC])
        switch mode {
        case .bitmap:
            data.append(contentsOf: "*b2M".utf8)
        case .greyscale3D:
            data.append(contentsOf: "*b7MLT".utf8)
        }

        // Raster direction (1=up, 0=down)
        // \033&y<dir>O
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "&y\(engraveBottomUp ? 1 : 0)O".utf8)

        // Start raster at current position
        // \033*r1A
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*r1A".utf8)

        return data
    }

    /// Generate PCL commands for a single raster scanline
    /// Ported from EpilogCutter.java:669-704
    static func generateRasterLine(
        lineData: [UInt8],
        xPosition: Int,
        yPosition: Int,
        leftToRight: Bool
    ) -> Data? {
        var line = lineData

        // Remove leading zeros, track offset
        var jump = 0
        while !line.isEmpty && line[0] == 0 {
            line.removeFirst()
            jump += 1
        }

        // Remove trailing zeros
        while !line.isEmpty && line[line.count - 1] == 0 {
            line.removeLast()
        }

        // Skip empty lines
        guard !line.isEmpty else {
            return nil
        }

        var data = Data()

        // X position (jump is in bytes, each byte = 8 pixels for bitmap mode)
        // \033*p<x>X
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*p\(xPosition + jump * 8)X".utf8)

        // Y position
        // \033*p<y>Y
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*p\(yPosition)Y".utf8)

        // Line size (negative for right-to-left)
        // \033*b<size>A
        var lineToEncode = line
        if leftToRight {
            data.append(contentsOf: [ESC])
            data.append(contentsOf: "*b\(line.count)A".utf8)
        } else {
            data.append(contentsOf: [ESC])
            data.append(contentsOf: "*b\(-line.count)A".utf8)
            lineToEncode = line.reversed()
        }

        // Encode line with TIFF Packbits
        let encoded = packbitsEncode(lineToEncode)

        // Pad to 8-byte boundary
        let len = encoded.count
        let paddedLen = ((len + 7) / 8) * 8

        // Transfer byte count
        // \033*b<bytes>W
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*b\(paddedLen)W".utf8)

        // Encoded data
        data.append(contentsOf: encoded)

        // Padding bytes (0x80 = 128 = NOP in Packbits)
        for _ in 0..<(paddedLen - len) {
            data.append(128)
        }

        return data
    }

    /// Generate PCL commands for a single 3D (greyscale) raster scanline
    /// Ported from EpilogCutter.java:518-572
    ///
    /// In 3D mode, each byte represents one pixel's power level (0-255).
    /// The power level is scaled by the raster power setting.
    static func generateRasterLine3D(
        lineData: [UInt8],
        xPosition: Int,
        yPosition: Int,
        leftToRight: Bool,
        power: Int
    ) -> Data? {
        var line = lineData

        // Scale each pixel by power setting
        // From Java: x * prop.getPower() / 100
        for i in 0..<line.count {
            let pixelValue = Int(line[i])
            let scaledValue = pixelValue * power / 100
            line[i] = UInt8(min(255, scaledValue))
        }

        // Remove leading zeros, track offset (per-pixel in 3D mode)
        var jump = 0
        while !line.isEmpty && line[0] == 0 {
            line.removeFirst()
            jump += 1
        }

        // Remove trailing zeros
        while !line.isEmpty && line[line.count - 1] == 0 {
            line.removeLast()
        }

        // Skip empty lines
        guard !line.isEmpty else {
            return nil
        }

        var data = Data()

        // X position (per-pixel offset in 3D mode, not per-byte like bitmap)
        // \033*p<x>X
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*p\(xPosition + jump)X".utf8)

        // Y position
        // \033*p<y>Y
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*p\(yPosition)Y".utf8)

        // Line size (negative for right-to-left)
        // \033*b<size>A
        var lineToEncode = line
        if leftToRight {
            data.append(contentsOf: [ESC])
            data.append(contentsOf: "*b\(line.count)A".utf8)
        } else {
            data.append(contentsOf: [ESC])
            data.append(contentsOf: "*b\(-line.count)A".utf8)
            lineToEncode = line.reversed()
        }

        // Encode line with TIFF Packbits
        let encoded = packbitsEncode(lineToEncode)

        // Pad to 8-byte boundary
        let len = encoded.count
        let paddedLen = ((len + 7) / 8) * 8

        // Transfer byte count
        // \033*b<bytes>W
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*b\(paddedLen)W".utf8)

        // Encoded data
        data.append(contentsOf: encoded)

        // Padding bytes (0x80 = 128 = NOP in Packbits)
        for _ in 0..<(paddedLen - len) {
            data.append(128)
        }

        return data
    }

    /// Generate PCL raster footer
    static func generateRasterFooter() -> Data {
        var data = Data()

        // End raster
        // \033*rC
        data.append(contentsOf: [ESC])
        data.append(contentsOf: "*rC".utf8)

        return data
    }

    /// Generate a dummy raster section (required at start of combined jobs)
    /// Ported from EpilogCutter.java:579-612
    static func generateDummyRaster(
        resolution: Int,
        power: Int = 0,
        speed: Int = 100,
        focus: Int = 0,
        width: Int = 10,
        height: Int = 10,
        engraveBottomUp: Bool = false
    ) -> Data {
        var data = Data()

        // Header with minimal dimensions
        data.append(generateRasterHeader(
            resolution: resolution,
            power: power,
            speed: speed,
            focus: focus,
            width: width,
            height: height,
            engraveBottomUp: engraveBottomUp
        ))

        // Immediately end raster (no actual content)
        data.append(generateRasterFooter())

        return data
    }
}

/// Extension for encoding a full raster page from CUPS data
extension RasterEncoder {
    /// Encode a complete raster page
    /// - Parameters:
    ///   - pageData: Full page pixel data (1 bit per pixel, packed into bytes)
    ///   - width: Width in pixels
    ///   - height: Height in pixels
    ///   - bytesPerLine: Bytes per scanline
    ///   - options: Job options with power/speed/etc.
    /// - Returns: PCL raster data
    static func encodePage(
        pageData: Data,
        width: Int,
        height: Int,
        bytesPerLine: Int,
        options: JobOptions
    ) -> Data {
        var result = Data()

        // Generate raster header
        result.append(generateRasterHeader(
            resolution: options.resolution,
            power: options.rasterPower,
            speed: options.rasterSpeed,
            focus: options.focus,
            width: width,
            height: height,
            engraveBottomUp: options.engraveBottomUp
        ))

        // Process each scanline
        let startY = options.engraveBottomUp ? height - 1 : 0
        let endY = options.engraveBottomUp ? -1 : height
        let stepY = options.engraveBottomUp ? -1 : 1

        var leftToRight = true
        var y = startY

        while y != endY {
            // Extract line data
            let lineStart = y * bytesPerLine
            let lineEnd = lineStart + bytesPerLine

            guard lineStart >= 0 && lineEnd <= pageData.count else {
                y += stepY
                continue
            }

            let lineData = Array(pageData[lineStart..<lineEnd])

            // Generate PCL for this line
            if let lineOutput = generateRasterLine(
                lineData: lineData,
                xPosition: 0,
                yPosition: y,
                leftToRight: leftToRight
            ) {
                result.append(lineOutput)
                leftToRight = !leftToRight  // Bidirectional rastering
            }

            y += stepY
        }

        // Generate raster footer
        result.append(generateRasterFooter())

        return result
    }

    /// Encode a complete 8-bit greyscale raster page (3D engraving mode)
    /// Ported from EpilogCutter.java:480-577
    ///
    /// In 3D mode, each byte represents one pixel's power level.
    /// The greyscale value is scaled by the raster power setting.
    ///
    /// - Parameters:
    ///   - pageData: Full page pixel data (8 bits per pixel, 1 byte per pixel)
    ///   - width: Width in pixels
    ///   - height: Height in pixels
    ///   - bytesPerLine: Bytes per scanline (should equal width for 8-bit)
    ///   - options: Job options with power/speed/etc.
    /// - Returns: PCL raster data in 3D mode
    static func encodePageGreyscale(
        pageData: Data,
        width: Int,
        height: Int,
        bytesPerLine: Int,
        options: JobOptions
    ) -> Data {
        var result = Data()

        // Generate raster header with 3D mode
        result.append(generateRasterHeader(
            resolution: options.resolution,
            power: options.rasterPower,
            speed: options.rasterSpeed,
            focus: options.focus,
            width: width,
            height: height,
            engraveBottomUp: options.engraveBottomUp,
            mode: .greyscale3D
        ))

        // Process each scanline
        let startY = options.engraveBottomUp ? height - 1 : 0
        let endY = options.engraveBottomUp ? -1 : height
        let stepY = options.engraveBottomUp ? -1 : 1

        var leftToRight = true
        var y = startY

        while y != endY {
            // Extract line data
            let lineStart = y * bytesPerLine
            let lineEnd = lineStart + bytesPerLine

            guard lineStart >= 0 && lineEnd <= pageData.count else {
                y += stepY
                continue
            }

            let lineData = Array(pageData[lineStart..<lineEnd])

            // Generate PCL for this line using 3D mode
            if let lineOutput = generateRasterLine3D(
                lineData: lineData,
                xPosition: 0,
                yPosition: y,
                leftToRight: leftToRight,
                power: options.rasterPower
            ) {
                result.append(lineOutput)
                leftToRight = !leftToRight  // Bidirectional rastering
            }

            y += stepY
        }

        // Generate raster footer
        result.append(generateRasterFooter())

        return result
    }
}
