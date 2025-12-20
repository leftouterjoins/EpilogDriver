/*
 * CUPSRasterStream.swift - Swift wrapper for CUPS raster API
 *
 * Provides a Swift-friendly interface to read CUPS raster data from stdin.
 */

import Foundation
import CUPSBridge

/// Swift wrapper for CUPS raster stream
class CUPSRasterStream {
    private let handle: CupsRasterHandle

    /// Page header information from CUPS
    struct PageHeader {
        let width: UInt32           // cupsWidth - pixels per line
        let height: UInt32          // cupsHeight - lines per page
        let bytesPerLine: UInt32    // cupsBytesPerLine
        let bitsPerColor: UInt32    // cupsBitsPerColor
        let bitsPerPixel: UInt32    // cupsBitsPerPixel
        let colorSpace: UInt32      // cupsColorSpace
        let numColors: UInt32       // cupsNumColors
        let horizontalDPI: UInt32   // HWResolution[0]
        let verticalDPI: UInt32     // HWResolution[1]

        init(from header: CupsPageHeader) {
            self.width = header.cupsWidth
            self.height = header.cupsHeight
            self.bytesPerLine = header.cupsBytesPerLine
            self.bitsPerColor = UInt32(header.cupsBitsPerColor)
            self.bitsPerPixel = UInt32(header.cupsBitsPerPixel)
            self.colorSpace = UInt32(header.cupsColorSpace.rawValue)
            self.numColors = UInt32(header.cupsNumColors)
            self.horizontalDPI = header.HWResolution.0
            self.verticalDPI = header.HWResolution.1
        }

        /// Is this a grayscale or black-and-white page?
        var isGrayscale: Bool {
            // CUPS_CSPACE_K = 3 (black), CUPS_CSPACE_W = 0 (white/gray)
            return colorSpace == 3 || colorSpace == 0
        }

        /// Resolution in DPI (assumes square pixels)
        var resolution: Int {
            return Int(horizontalDPI)
        }
    }

    /// Initialize raster stream from stdin
    init?() {
        guard let h = cups_raster_open_stdin() else {
            return nil
        }
        self.handle = h
    }

    deinit {
        cups_raster_close(handle)
    }

    /// Read the next page header
    /// Returns nil when there are no more pages
    func readPageHeader() -> PageHeader? {
        var header = CupsPageHeader()
        let result = cups_raster_read_header(handle, &header)
        guard result != 0 else {
            return nil
        }
        return PageHeader(from: header)
    }

    /// Read one line of pixel data
    /// Returns the number of bytes read, or 0 on error
    func readLine(into buffer: UnsafeMutablePointer<UInt8>, length: UInt32) -> UInt32 {
        return UInt32(cups_raster_read_line(handle, buffer, UInt32(length)))
    }

    /// Read one line of pixel data into a Data object
    func readLine(bytesPerLine: UInt32) -> Data? {
        var buffer = Data(count: Int(bytesPerLine))
        let bytesRead = buffer.withUnsafeMutableBytes { ptr -> UInt32 in
            guard let baseAddress = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return readLine(into: baseAddress, length: bytesPerLine)
        }
        guard bytesRead == bytesPerLine else {
            return nil
        }
        return buffer
    }
}
