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

    /// Copies requested by CUPS
    let copies: Int

    init(title: String, user: String, options: JobOptions, copies: Int = 1) {
        self.title = title
        self.user = user
        self.options = options
        self.copies = max(1, copies)
    }

    // MARK: - PDF Processing (Vector + Raster Combined)

    /// Process PDF input - extract vectors for cutting and rasterize for engraving
    func processPDF(data: Data) throws {
        fputs("DEBUG: Processing PDF for combined vector/raster output\n", stderr)

        // Raster encoding mode comes from the RasterMode option, not the job type.
        let is3DMode = options.rasterMode == .greyscale3D

        // Target page size, so a document exported at one point per pixel gets
        // scaled onto the bed instead of rasterized at its nominal 166 inches.
        let pageSize: CGSize? = options.hasPageSize
            ? CGSize(width: options.pageWidthPoints, height: options.pageHeightPoints)
            : nil

        // 1. Extract vector paths - anything painted in a cut color
        let vectorExtractor = PDFVectorExtractor(resolution: options.resolution,
                                                 outputSizePoints: pageSize)
        let extractedPaths = vectorExtractor.extractFromPDFData(data)

        // Apply color mappings and job options to extracted vectors
        vectorPaths = applyColorMappings(to: extractedPaths)

        let vectorPathCount = vectorPaths.count
        let vectorCommandCount = vectorPaths.reduce(0) { $0 + $1.commands.count }
        fputs("DEBUG: Extracted \(vectorPathCount) vector paths with \(vectorCommandCount) commands\n", stderr)

        // 2. Rasterize the PDF for engraving content. Cut colors are excluded so
        //    a shape is not both engraved and cut - but only when we actually
        //    extracted vectors to cut. Apps that flatten their output on print
        //    (Pixelmator Pro among them) hand us a single bitmap with no paths
        //    in it; dropping those pixels there would silently delete artwork.
        let excludeCutColors = options.jobType != .raster && !vectorPaths.isEmpty

        // Say so loudly when a job that asked for cutting will not cut. WARNING:
        // reaches the print queue window, so this surfaces in the UI rather than
        // only in a debug log nobody thinks to read - the failure otherwise looks
        // identical to the machine simply stopping after the engrave.
        if vectorPaths.isEmpty && options.jobType != .raster {
            if vectorExtractor.paintedPathCount == 0 {
                fputs("WARNING: This document contains no vector artwork at all"
                      + (vectorExtractor.imageCount > 0
                         ? " - it is \(vectorExtractor.imageCount) flattened image(s)." : ".")
                      + " Nothing will be cut. Applications that flatten when printing"
                      + " (Pixelmator Pro among them) discard the paths; export to PDF"
                      + " and print that instead.\n", stderr)
            } else {
                fputs("WARNING: Found \(vectorExtractor.paintedPathCount) vector shape(s)"
                      + " but none qualified as a cut, so nothing will be cut. Cut lines"
                      + " must be a hairline stroke (<= 0.25pt) or painted in red, green,"
                      + " blue, cyan, yellow or magenta.\n", stderr)
            }
            fputs("DEBUG: No vector paths extracted - cut colors will be engraved "
                  + "rather than dropped\n", stderr)
        }
        let rasterizer = PDFRasterizer(
            resolution: options.resolution,
            mode: options.rasterMode,
            cutColors: excludeCutColors ? CutColor.all : [],
            outputSizePoints: pageSize
        )
        let rasterPages = rasterizer.rasterize(pdfData: data)

        fputs("DEBUG: Rasterized \(rasterPages.count) pages for engraving\n", stderr)

        // 2a. Test frame short-circuits the real job: trace where the work will
        //     land so the operator can position material, then run for real.
        if options.testFrame != .off {
            try emitTestFrame(rasterPages: rasterPages)
            return
        }

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
            autofocus: options.autofocus,
            copies: copies
        )
        try writeToStdout(header)

        // 5. Generate raster data (if any content to engrave)
        if hasRasterContent {
            for page in rasterPages {
                if PDFRasterizer.hasContent(page) {
                    // Declare only the content's extent to the laser, so the head
                    // does not sweep the full bed on every scanline.
                    let maxX = page.inkMaxX + 1
                    let maxY = page.inkMaxY + 1
                    let rows = page.inkMinY..<maxY

                    fputs("DEBUG: Encoding raster page \(page.width)x\(page.height), "
                          + "content extent \(maxX)x\(maxY), rows \(rows.lowerBound)..<\(rows.upperBound)\n", stderr)

                    let rasterData: Data
                    if is3DMode {
                        rasterData = RasterEncoder.encodePageGreyscale(
                            pageData: page.data,
                            width: page.width,
                            height: page.height,
                            bytesPerLine: page.bytesPerLine,
                            options: options,
                            maxX: maxX,
                            maxY: maxY,
                            rowRange: rows
                        )
                    } else {
                        rasterData = RasterEncoder.encodePage(
                            pageData: page.data,
                            width: page.width,
                            height: page.height,
                            bytesPerLine: page.bytesPerLine,
                            options: options,
                            maxX: maxX,
                            maxY: maxY,
                            rowRange: rows
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
            try writeToStdout(VectorEncoder.generateVectorHPGL(paths: vectorPaths))
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

    /// Emit a single rectangle around everything the real job would touch.
    ///
    /// Used to position material: run this, watch where the head goes, move the
    /// stock, then print again with the test frame off. Raster ink and vector
    /// paths share the same coordinate space (pixels at the job resolution,
    /// origin top-left), so their extents can simply be unioned.
    private func emitTestFrame(rasterPages: [PDFRasterizer.RasterPage]) throws {
        var minX = Int.max, minY = Int.max
        var maxX = Int.min, maxY = Int.min

        // Raster contribution - engraved artwork
        for page in rasterPages where page.hasInk {
            minX = min(minX, page.inkMinX)
            minY = min(minY, page.inkMinY)
            maxX = max(maxX, page.inkMaxX)
            maxY = max(maxY, page.inkMaxY)
        }

        // Vector contribution - anything that would be cut
        for path in vectorPaths {
            for cmd in path.commands {
                switch cmd {
                case .moveTo(let x, let y), .lineTo(let x, let y):
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                case .setProperty:
                    break
                }
            }
        }

        guard minX <= maxX && minY <= maxY else {
            fputs("WARNING: Test frame requested but the job has no content to "
                  + "frame; nothing will be sent\n", stderr)
            // Still emit a well-formed empty job so the queue does not error.
            try writeToStdout(PJLGenerator.generateHeader(
                title: title, resolution: options.resolution, autofocus: false,
                copies: copies))
            try writeToStdout(RasterEncoder.generateDummyRaster(resolution: options.resolution))
            try writeToStdout(VectorEncoder.generateDummyVector())
            try writeToStdout(PJLGenerator.generateFooter())
            return
        }

        let (power, speed) = options.testFrame.vectorSettings
        let res = Double(options.resolution)
        fputs(String(format:
            "INFO: Test frame (%@): %.2f\" x %.2f\" at (%.2f\", %.2f\") - power %d%%, speed %d%%\n",
            options.testFrame.rawValue,
            Double(maxX - minX) / res, Double(maxY - minY) / res,
            Double(minX) / res, Double(minY) / res,
            power, speed), stderr)

        var frame = VectorPath()
        frame.setProperty(colorIndex: 0, power: power, speed: speed,
                          frequency: options.vectorFrequency, focus: options.focus)
        frame.moveTo(x: minX, y: minY)
        frame.lineTo(x: maxX, y: minY)
        frame.lineTo(x: maxX, y: maxY)
        frame.lineTo(x: minX, y: maxY)
        frame.lineTo(x: minX, y: minY)

        // Autofocus off: the head is only being positioned, and focusing against
        // material that is not yet placed correctly is pointless.
        try writeToStdout(PJLGenerator.generateHeader(
            title: "\(title) [test frame]", resolution: options.resolution,
            autofocus: false, copies: 1))
        try writeToStdout(RasterEncoder.generateDummyRaster(resolution: options.resolution))
        try writeToStdout(VectorEncoder.generateVectorHPGL(paths: [frame]))
        try writeToStdout(PJLGenerator.generateFooter())

        fputs("DEBUG: Test frame job complete\n", stderr)
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
            let rawR = UInt8(min(255, max(0, Int(color.r * 255))))
            let rawG = UInt8(min(255, max(0, Int(color.g * 255))))
            let rawB = UInt8(min(255, max(0, Int(color.b * 255))))

            // Snap to the nominal cut color so a design's "red" still matches the
            // per-color settings even when the app writes it as (0.93, 0.11, 0.14).
            let cutColor = CutColor(r: rawR, g: rawG, b: rawB)
            let (colorR, colorG, colorB) = cutColor?.rgb ?? (rawR, rawG, rawB)

            // Pen selector for YC. Epilog's driver leads each property change
            // with it; index 0 is the default pen, used for anything routed by
            // hairline width rather than by color.
            let colorIndex = cutColor?.penIndex ?? 0

            // Look up settings for this color
            let settings = options.vectorSettings(for: colorR, g: colorG, b: colorB)

            // Skip this path if power is 0
            if settings.skip {
                fputs("WARNING: Skipping vector path RGB(\(colorR),\(colorG),\(colorB)) - "
                      + "its per-color power is set to 0, which means 'do not cut'\n", stderr)
                continue
            }

            fputs("DEBUG: Vector path RGB(\(colorR),\(colorG),\(colorB)) -> "
                  + "power=\(settings.power)% speed=\(settings.speed)% "
                  + "freq=\(settings.frequency)Hz focus=\(options.focus)\n", stderr)

            // Insert property command at the beginning of the path
            var newCommands: [VectorCommand] = []
            newCommands.append(.setProperty(
                colorIndex: colorIndex,
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
            autofocus: options.autofocus,
            copies: copies
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
            try writeToStdout(VectorEncoder.generateVectorHPGL(paths: vectorPaths))
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
            autofocus: options.autofocus,
            copies: copies
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
            try writeToStdout(VectorEncoder.generateVectorHPGL(paths: vectorPaths))
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
