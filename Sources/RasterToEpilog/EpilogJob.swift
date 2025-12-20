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

    // MARK: - PDF Processing (Vector + Raster Combined)

    /// Process PDF input - extract vectors for cutting and rasterize for engraving
    func processPDF(data: Data) throws {
        fputs("DEBUG: Processing PDF for combined vector/raster output\n", stderr)

        // Determine if we're in 3D greyscale mode
        let is3DMode = options.jobType != .vector  // Check RasterMode option would be better

        // 1. Extract vector paths from thin strokes in the PDF
        let vectorExtractor = PDFVectorExtractor(resolution: options.resolution)
        let extractedPaths = vectorExtractor.extractFromPDFData(data)

        // Apply color mappings and job options to extracted vectors
        vectorPaths = applyColorMappings(to: extractedPaths)

        let vectorPathCount = vectorPaths.count
        let vectorCommandCount = vectorPaths.reduce(0) { $0 + $1.commands.count }
        fputs("DEBUG: Extracted \(vectorPathCount) vector paths with \(vectorCommandCount) commands\n", stderr)

        // 2. Rasterize the PDF for engraving content
        let rasterizer = PDFRasterizer(resolution: options.resolution, greyscaleMode: is3DMode)
        let rasterPages = rasterizer.rasterize(pdfData: data)

        fputs("DEBUG: Rasterized \(rasterPages.count) pages for engraving\n", stderr)

        // 3. Check what content we have
        let hasVectorContent = !vectorPaths.isEmpty && options.jobType != .raster
        let hasRasterContent = rasterPages.contains { PDFRasterizer.hasContent($0) } && options.jobType != .vector

        fputs("DEBUG: Has vector content: \(hasVectorContent), Has raster content: \(hasRasterContent)\n", stderr)
        fputs("DEBUG: Job type: \(options.jobType)\n", stderr)

        // 4. Generate PJL header
        let resolution = options.resolution
        let header = PJLGenerator.generateHeader(
            title: title,
            resolution: resolution,
            autofocus: options.autofocus
        )
        try writeToStdout(header)

        // 5. Generate raster data (if any content to engrave)
        if hasRasterContent {
            for page in rasterPages {
                if PDFRasterizer.hasContent(page) {
                    fputs("DEBUG: Encoding raster page: \(page.width)x\(page.height)\n", stderr)

                    let rasterData: Data
                    if is3DMode {
                        rasterData = RasterEncoder.encodePageGreyscale(
                            pageData: page.data,
                            width: page.width,
                            height: page.height,
                            bytesPerLine: page.bytesPerLine,
                            options: options
                        )
                    } else {
                        rasterData = RasterEncoder.encodePage(
                            pageData: page.data,
                            width: page.width,
                            height: page.height,
                            bytesPerLine: page.bytesPerLine,
                            options: options
                        )
                    }
                    try writeToStdout(rasterData)
                }
            }
        } else {
            // No raster content - generate dummy raster (required by Epilog)
            fputs("DEBUG: No raster content, generating dummy raster\n", stderr)
            let dummyRaster = RasterEncoder.generateDummyRaster(
                resolution: resolution,
                power: options.rasterPower,
                speed: options.rasterSpeed,
                focus: options.focus
            )
            try writeToStdout(dummyRaster)
        }

        // 6. Generate vector HPGL (if any paths to cut)
        if hasVectorContent {
            fputs("DEBUG: Generating HPGL for \(vectorPaths.count) vector paths\n", stderr)
            for path in vectorPaths {
                let vectorData = VectorEncoder.generateVectorHPGL(path: path)
                try writeToStdout(vectorData)
            }
        } else {
            // Need dummy vector at end of raster jobs
            fputs("DEBUG: No vector content, generating dummy vector\n", stderr)
            let dummyVector = VectorEncoder.generateDummyVector()
            try writeToStdout(dummyVector)
        }

        // 7. Generate PJL footer
        let footer = PJLGenerator.generateFooter()
        try writeToStdout(footer)

        fputs("DEBUG: PDF job generation complete\n", stderr)
    }

    /// Apply color mappings from job options to extracted vector paths
    private func applyColorMappings(to paths: [VectorPath]) -> [VectorPath] {
        // For now, apply default vector settings to all paths
        // The PDFVectorExtractor stores color info in paths, which we'll use
        // to look up per-color settings
        var result: [VectorPath] = []

        for var path in paths {
            // Get the color from the path (stored during extraction)
            let color = path.strokeColor ?? (r: 0, g: 0, b: 0)
            let colorR = UInt8(min(255, max(0, Int(color.r * 255))))
            let colorG = UInt8(min(255, max(0, Int(color.g * 255))))
            let colorB = UInt8(min(255, max(0, Int(color.b * 255))))

            // Look up settings for this color
            let settings = options.vectorSettings(for: colorR, g: colorG, b: colorB)

            // Skip this path if power is 0
            if settings.skip {
                fputs("DEBUG: Skipping vector path with color RGB(\(colorR),\(colorG),\(colorB)) - power 0\n", stderr)
                continue
            }

            // Insert property command at the beginning of the path
            var newCommands: [VectorCommand] = []
            newCommands.append(.setProperty(
                power: settings.power,
                speed: settings.speed,
                frequency: settings.frequency,
                focus: options.focus
            ))
            newCommands.append(contentsOf: path.commands)
            path.commands = newCommands

            result.append(path)
        }

        return result
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
