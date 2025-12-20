/*
 * EpilogJob.swift - Orchestrates Epilog laser job assembly
 *
 * Combines PJL header, raster PCL, vector HPGL, and PJL footer
 * into a complete job for the Epilog laser.
 *
 * Ported from VisiCut's EpilogCutter.java generatePjlData()
 */

import Foundation

/// Errors that can occur during job processing
enum EpilogJobError: Error {
    case noPages
    case invalidRasterData
    case outputFailed
}

/// Orchestrates the generation of a complete Epilog laser job
class EpilogJob {
    let title: String
    let user: String
    let options: JobOptions

    /// Vector paths to cut (if any)
    var vectorPaths: [VectorPath] = []

    init(title: String, user: String, options: JobOptions) {
        self.title = title
        self.user = user
        self.options = options
    }

    /// Process CUPS raster input and generate Epilog job output to stdout
    /// Ported from EpilogCutter.java:798-836
    func process(raster: CUPSRasterStream) throws {
        var hasRaster = false
        let hasVector = !vectorPaths.isEmpty

        // Read first page header
        guard let pageHeader = raster.readPageHeader() else {
            // No pages - generate minimal job
            throw EpilogJobError.noPages
        }

        fputs("DEBUG: Page: \(pageHeader.width)x\(pageHeader.height) @ \(pageHeader.resolution)dpi\n", stderr)
        fputs("DEBUG: BPP: \(pageHeader.bitsPerPixel), Colors: \(pageHeader.numColors), BytesPerLine: \(pageHeader.bytesPerLine)\n", stderr)

        // Determine raster mode: 8-bit greyscale = 3D mode, 1-bit = bitmap mode
        let is3DMode = pageHeader.bitsPerPixel >= 8 && pageHeader.numColors == 1
        if is3DMode {
            fputs("DEBUG: Using 3D greyscale engraving mode\n", stderr)
        } else {
            fputs("DEBUG: Using standard bitmap engraving mode\n", stderr)
        }

        // Determine actual resolution from page header
        let resolution = pageHeader.resolution

        // Generate PJL header
        let header = PJLGenerator.generateHeader(
            title: title,
            resolution: resolution,
            autofocus: options.autofocus
        )
        try writeToStdout(header)

        // If we have raster data, process it
        // Read all raster lines into memory for processing
        var pageData = Data()
        for _ in 0..<pageHeader.height {
            if let lineData = raster.readLine(bytesPerLine: pageHeader.bytesPerLine) {
                pageData.append(lineData)
            } else {
                // Pad with zeros if read fails
                pageData.append(contentsOf: [UInt8](repeating: 0, count: Int(pageHeader.bytesPerLine)))
            }
        }

        // Check if raster has any content
        let hasContent = pageData.contains { $0 != 0 && $0 != 0xFF }

        if hasContent || options.jobType == .raster || options.jobType == .combined {
            hasRaster = true

            // Invert pixel data if needed (CUPS uses white=0, Epilog uses black=0)
            // For grayscale/black colorspace, we may need to invert
            if pageHeader.colorSpace == 3 { // CUPS_CSPACE_K (black)
                // Already black-based, no inversion needed
            } else if pageHeader.colorSpace == 0 { // CUPS_CSPACE_W (white/gray)
                // Invert the data
                pageData = Data(pageData.map { ~$0 })
            }

            // Generate raster PCL using appropriate mode
            let rasterData: Data
            if is3DMode {
                // 8-bit greyscale: Use 3D mode with power modulation per pixel
                rasterData = RasterEncoder.encodePageGreyscale(
                    pageData: pageData,
                    width: Int(pageHeader.width),
                    height: Int(pageHeader.height),
                    bytesPerLine: Int(pageHeader.bytesPerLine),
                    options: options
                )
            } else {
                // 1-bit bitmap: Use standard raster mode
                rasterData = RasterEncoder.encodePage(
                    pageData: pageData,
                    width: Int(pageHeader.width),
                    height: Int(pageHeader.height),
                    bytesPerLine: Int(pageHeader.bytesPerLine),
                    options: options
                )
            }
            try writeToStdout(rasterData)
        } else {
            // No raster content - generate dummy raster (required by Epilog)
            let dummyRaster = RasterEncoder.generateDummyRaster(
                resolution: resolution,
                power: options.rasterPower,
                speed: options.rasterSpeed,
                focus: options.focus
            )
            try writeToStdout(dummyRaster)
        }

        // Generate vector HPGL if we have paths
        if hasVector {
            for path in vectorPaths {
                let vectorData = VectorEncoder.generateVectorHPGL(path: path)
                try writeToStdout(vectorData)
            }
        } else if hasRaster {
            // Need dummy vector at end of raster-only jobs
            let dummyVector = VectorEncoder.generateDummyVector()
            try writeToStdout(dummyVector)
        }

        // Generate PJL footer
        let footer = PJLGenerator.generateFooter()
        try writeToStdout(footer)

        fputs("DEBUG: Job generation complete\n", stderr)
    }

    /// Write data to stdout
    private func writeToStdout(_ data: Data) throws {
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let ptr = buffer.baseAddress else { return 0 }
            return fwrite(ptr, 1, buffer.count, stdout)
        }

        if written != data.count {
            throw EpilogJobError.outputFailed
        }

        fflush(stdout)
    }
}

/// Extension for multi-page support
extension EpilogJob {
    /// Process multiple pages from CUPS raster stream
    func processMultiPage(raster: CUPSRasterStream) throws {
        var pageNum = 0

        // Generate PJL header
        var resolution = options.resolution
        let header = PJLGenerator.generateHeader(
            title: title,
            resolution: resolution,
            autofocus: options.autofocus
        )
        try writeToStdout(header)

        var hasProcessedRaster = false

        // Process each page
        while let pageHeader = raster.readPageHeader() {
            pageNum += 1
            resolution = pageHeader.resolution

            // Determine raster mode: 8-bit greyscale = 3D mode
            let is3DMode = pageHeader.bitsPerPixel >= 8 && pageHeader.numColors == 1

            fputs("DEBUG: Processing page \(pageNum): \(pageHeader.width)x\(pageHeader.height) @ \(resolution)dpi\n", stderr)
            fputs("DEBUG: Mode: \(is3DMode ? "3D greyscale" : "bitmap")\n", stderr)

            // Read page data
            var pageData = Data()
            for _ in 0..<pageHeader.height {
                if let lineData = raster.readLine(bytesPerLine: pageHeader.bytesPerLine) {
                    pageData.append(lineData)
                } else {
                    pageData.append(contentsOf: [UInt8](repeating: 0, count: Int(pageHeader.bytesPerLine)))
                }
            }

            // Handle color space inversion
            if pageHeader.colorSpace == 0 { // CUPS_CSPACE_W
                pageData = Data(pageData.map { ~$0 })
            }

            // Generate raster for this page using appropriate mode
            let rasterData: Data
            if is3DMode {
                rasterData = RasterEncoder.encodePageGreyscale(
                    pageData: pageData,
                    width: Int(pageHeader.width),
                    height: Int(pageHeader.height),
                    bytesPerLine: Int(pageHeader.bytesPerLine),
                    options: options
                )
            } else {
                rasterData = RasterEncoder.encodePage(
                    pageData: pageData,
                    width: Int(pageHeader.width),
                    height: Int(pageHeader.height),
                    bytesPerLine: Int(pageHeader.bytesPerLine),
                    options: options
                )
            }
            try writeToStdout(rasterData)
            hasProcessedRaster = true
        }

        if !hasProcessedRaster {
            // No pages - generate dummy raster
            let dummyRaster = RasterEncoder.generateDummyRaster(
                resolution: resolution,
                power: options.rasterPower,
                speed: options.rasterSpeed,
                focus: options.focus
            )
            try writeToStdout(dummyRaster)
        }

        // Vector paths
        if !vectorPaths.isEmpty {
            for path in vectorPaths {
                let vectorData = VectorEncoder.generateVectorHPGL(path: path)
                try writeToStdout(vectorData)
            }
        } else {
            let dummyVector = VectorEncoder.generateDummyVector()
            try writeToStdout(dummyVector)
        }

        // Footer
        let footer = PJLGenerator.generateFooter()
        try writeToStdout(footer)

        fputs("INFO: Processed \(pageNum) page(s)\n", stderr)
    }
}
