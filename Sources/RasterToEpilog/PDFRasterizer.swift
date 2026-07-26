/*
 * PDFRasterizer.swift - Render PDF to raster bitmap for laser engraving
 *
 * Uses CoreGraphics to render PDF pages to bitmaps that can be
 * processed by the RasterEncoder for laser engraving.
 *
 * The page is rendered in horizontal bands so that memory stays bounded
 * even at 1000 DPI over a full 24" x 12" bed (which would otherwise be
 * a ~1.1 GB RGBA buffer).
 *
 * Pixels painted in one of the Epilog "cut colors" are excluded from the
 * engrave: those shapes are handled by the vector pipeline instead, so
 * engraving them too would burn the outline twice.
 */

import Foundation
import CoreGraphics
import ImageIO

/// Rasterizes PDF documents to bitmaps for laser engraving
class PDFRasterizer {
    /// Resolution for rasterization (DPI)
    let resolution: Int

    /// Output encoding mode: 1-bit bitmap or 8-bit greyscale (3D)
    let mode: RasterMode

    /// Colors routed to the vector cutter, which must not be engraved
    let cutColors: Set<CutColor>

    /// Ink threshold for 1-bit conversion (0-255). A pixel engraves when its
    /// darkness reaches this value.
    let threshold: UInt8

    /// Rows rendered per band. 256 rows of 24000px RGBA is ~24 MB.
    private static let bandRows = 256

    /// A rasterized page, ready for the RasterEncoder
    struct RasterPage {
        /// Full page dimensions in pixels
        let width: Int
        let height: Int
        let bytesPerLine: Int
        let bitsPerPixel: Int
        let data: Data

        /// Bounding box of engravable ink, in absolute page pixels.
        /// Empty (minX > maxX) when the page has nothing to engrave.
        let inkMinX: Int
        let inkMinY: Int
        let inkMaxX: Int
        let inkMaxY: Int

        var hasInk: Bool { inkMinX <= inkMaxX && inkMinY <= inkMaxY }
    }

    /// Target page size in points. A document larger than this is scaled down
    /// to fit; nil, or a document that already fits, is left alone.
    let outputSizePoints: CGSize?

    init(resolution: Int, mode: RasterMode = .bitmap, cutColors: Set<CutColor> = [],
         threshold: UInt8 = 128, outputSizePoints: CGSize? = nil) {
        self.resolution = resolution
        self.mode = mode
        self.cutColors = cutColors
        self.threshold = threshold
        self.outputSizePoints = outputSizePoints
    }

    /// Rasterize a PDF document from data
    func rasterize(pdfData: Data) -> [RasterPage] {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider) else {
            fputs("ERROR: Cannot parse PDF data for rasterization\n", stderr)
            return []
        }

        return rasterize(document: document)
    }

    /// Rasterize a PDF document
    func rasterize(document: CGPDFDocument) -> [RasterPage] {
        var pages: [RasterPage] = []
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { return [] }

        for pageNum in 1...pageCount {
            guard let page = document.page(at: pageNum) else { continue }
            if let rasterPage = rasterizePage(page) {
                pages.append(rasterPage)
            }
        }

        return pages
    }

    /// Build the point-space -> device-pixel transform for a page,
    /// accounting for the media box origin and page rotation.
    private func pageTransform(_ page: CGPDFPage) -> (transform: CGAffineTransform, width: Int, height: Int) {
        let mediaBox = page.getBoxRect(.mediaBox)
        let rotation = page.rotationAngle
        let scale = CGFloat(resolution) / 72.0

        var widthPoints = mediaBox.width
        var heightPoints = mediaBox.height
        if rotation == 90 || rotation == 270 {
            swap(&widthPoints, &heightPoints)
        }

        // Move the media box to the origin, then apply page rotation, then scale.
        var t = CGAffineTransform(translationX: -mediaBox.origin.x, y: -mediaBox.origin.y)

        switch rotation {
        case 90:
            t = t.concatenating(CGAffineTransform(rotationAngle: .pi / 2))
                 .concatenating(CGAffineTransform(translationX: heightPoints, y: 0))
        case 180:
            t = t.concatenating(CGAffineTransform(rotationAngle: .pi))
                 .concatenating(CGAffineTransform(translationX: widthPoints, y: heightPoints))
        case 270:
            t = t.concatenating(CGAffineTransform(rotationAngle: -.pi / 2))
                 .concatenating(CGAffineTransform(translationX: 0, y: widthPoints))
        default:
            break
        }

        // Shrink an oversized page onto the bed. Applications that export at one
        // point per pixel produce enormous pages - a 24"x12" canvas at 500dpi
        // becomes a 12000x6000pt, 166-inch-wide page - which would otherwise be
        // rasterized at its nominal size and never finish. Only ever shrinks, so
        // a page that already fits is untouched.
        var outWidth = widthPoints
        var outHeight = heightPoints
        if let target = outputSizePoints, target.width > 0, target.height > 0,
           widthPoints > 0, heightPoints > 0 {
            let fit = min(target.width / widthPoints, target.height / heightPoints)
            if fit < 0.999 {
                outWidth = target.width
                outHeight = target.height
                t = t.concatenating(CGAffineTransform(scaleX: fit, y: fit))
                // PDF space has its origin bottom-left, so align the scaled
                // content to the top of the bed rather than leaving it floating
                // at the bottom.
                t = t.concatenating(CGAffineTransform(
                    translationX: 0, y: outHeight - heightPoints * fit))
                fputs(String(format:
                    "INFO: Page is %.0fx%.0fpt, larger than the %.0fx%.0fpt page size;"
                    + " scaling to fit (%.4f)\n",
                    Double(widthPoints), Double(heightPoints),
                    Double(target.width), Double(target.height), Double(fit)), stderr)
            }
        }

        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        return (t, Int(ceil(outWidth * scale)), Int(ceil(outHeight * scale)))
    }

    /// Rasterize a single PDF page in horizontal bands
    private func rasterizePage(_ page: CGPDFPage) -> RasterPage? {
        let (base, widthPixels, heightPixels) = pageTransform(page)

        guard widthPixels > 0 && heightPixels > 0 else {
            fputs("ERROR: Page has zero size\n", stderr)
            return nil
        }

        let bitsPerPixel = (mode == .bitmap) ? 1 : 8
        let bytesPerLine = (mode == .bitmap) ? (widthPixels + 7) / 8 : widthPixels

        fputs("DEBUG: Rasterizing page: \(widthPixels)x\(heightPixels) @ \(resolution)dpi, "
              + "\(bitsPerPixel)bpp, \(bytesPerLine) bytes/line\n", stderr)

        var output = Data(count: bytesPerLine * heightPixels)

        var inkMinX = Int.max, inkMinY = Int.max
        var inkMaxX = Int.min, inkMaxY = Int.min

        // Scratch RGBA buffer reused for every band
        let srcBytesPerRow = widthPixels * 4
        var band = [UInt8](repeating: 0, count: srcBytesPerRow * Self.bandRows)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue

        var bandStart = 0
        while bandStart < heightPixels {
            let rows = min(Self.bandRows, heightPixels - bandStart)

            let drawn: Bool = band.withUnsafeMutableBytes { raw -> Bool in
                guard let ptr = raw.baseAddress else { return false }
                // White background: nothing to engrave where the page is blank
                memset(ptr, 0xFF, srcBytesPerRow * rows)

                guard let ctx = CGContext(
                    data: ptr,
                    width: widthPixels,
                    height: rows,
                    bitsPerComponent: 8,
                    bytesPerRow: srcBytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                ) else {
                    return false
                }

                // Shift the page so this band's rows land in the buffer.
                // Quartz bitmap row 0 is the top of the image, while user space
                // has y increasing upward, hence the height-relative offset.
                ctx.translateBy(x: 0, y: CGFloat(bandStart + rows - heightPixels))
                ctx.concatenate(base)
                ctx.drawPDFPage(page)
                ctx.flush()
                return true
            }

            guard drawn else {
                fputs("ERROR: Cannot create bitmap context for band at row \(bandStart)\n", stderr)
                return nil
            }

            // Convert this band into the output buffer
            output.withUnsafeMutableBytes { outRaw in
                guard let outBase = outRaw.baseAddress else { return }
                band.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }

                    for r in 0..<rows {
                        let pageRow = bandStart + r
                        let srcRow = srcBase + r * srcBytesPerRow
                        let dstRow = outBase + pageRow * bytesPerLine

                        var rowMinX = Int.max
                        var rowMaxX = Int.min

                        for x in 0..<widthPixels {
                            let p = srcRow + x * 4
                            let ink = self.inkValue(r: p[0], g: p[1], b: p[2])
                            guard ink > 0 else { continue }

                            if self.mode == .bitmap {
                                guard ink >= self.threshold else { continue }
                                let byte = dstRow.advanced(by: x >> 3)
                                    .assumingMemoryBound(to: UInt8.self)
                                byte.pointee |= UInt8(0x80 >> (x & 7))
                            } else {
                                dstRow.advanced(by: x)
                                    .assumingMemoryBound(to: UInt8.self)
                                    .pointee = ink
                            }

                            if x < rowMinX { rowMinX = x }
                            if x > rowMaxX { rowMaxX = x }
                        }

                        if rowMinX <= rowMaxX {
                            if rowMinX < inkMinX { inkMinX = rowMinX }
                            if rowMaxX > inkMaxX { inkMaxX = rowMaxX }
                            if pageRow < inkMinY { inkMinY = pageRow }
                            if pageRow > inkMaxY { inkMaxY = pageRow }
                        }
                    }
                }
            }

            bandStart += rows
        }

        if inkMinX > inkMaxX {
            fputs("DEBUG: Page has no engravable content\n", stderr)
        } else {
            fputs("DEBUG: Ink bounding box: x \(inkMinX)..\(inkMaxX), y \(inkMinY)..\(inkMaxY)\n", stderr)
        }

        return RasterPage(
            width: widthPixels,
            height: heightPixels,
            bytesPerLine: bytesPerLine,
            bitsPerPixel: bitsPerPixel,
            data: output,
            inkMinX: inkMinX > inkMaxX ? 1 : inkMinX,
            inkMinY: inkMinX > inkMaxX ? 1 : inkMinY,
            inkMaxX: inkMinX > inkMaxX ? 0 : inkMaxX,
            inkMaxY: inkMinX > inkMaxX ? 0 : inkMaxY
        )
    }

    /// Darkness of a rendered pixel, 0 = leave alone, 255 = full power.
    /// Pixels belonging to a vector cut color contribute no ink.
    private func inkValue(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        if !cutColors.isEmpty, let cc = CutColor(r: r, g: g, b: b), cutColors.contains(cc) {
            return 0
        }
        // Rec. 601 luma, then invert so dark artwork means high power
        let luma = (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000
        return UInt8(255 - min(255, luma))
    }
}

/// The six saturated colors Epilog's workflow routes to the vector cutter.
enum CutColor: Hashable {
    case red, green, blue, cyan, yellow, magenta

    /// Minimum channel spread for a pixel to count as chromatic rather than
    /// a grey that should simply be engraved.
    static let chromaThreshold = 40

    /// Classify a rendered pixel. Returns nil for greys and near-greys.
    ///
    /// Comparing against the midpoint between the pixel's own min and max
    /// channel means an antialiased pixel still classifies as its source
    /// color: pure red (255,0,0) and red blended halfway to white
    /// (255,128,128) both resolve to `.red`.
    init?(r: UInt8, g: UInt8, b: UInt8) {
        let ri = Int(r), gi = Int(g), bi = Int(b)
        let mx = max(ri, max(gi, bi))
        let mn = min(ri, min(gi, bi))
        guard mx - mn >= Self.chromaThreshold else { return nil }

        let mid = (mx + mn) / 2
        switch (ri > mid, gi > mid, bi > mid) {
        case (true, false, false):  self = .red
        case (false, true, false):  self = .green
        case (false, false, true):  self = .blue
        case (false, true, true):   self = .cyan
        case (true, true, false):   self = .yellow
        case (true, false, true):   self = .magenta
        default: return nil
        }
    }

    /// Pen index for HPGL's YC selector. 0 is reserved for the default pen, so
    /// the six cut colors occupy 1-6 in the order Epilog's own UI lists them.
    var penIndex: Int {
        switch self {
        case .red:     return 1
        case .green:   return 2
        case .blue:    return 3
        case .cyan:    return 4
        case .yellow:  return 5
        case .magenta: return 6
        }
    }

    /// Nominal RGB for this cut color, used to look up per-color settings.
    var rgb: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .red:     return (255, 0, 0)
        case .green:   return (0, 255, 0)
        case .blue:    return (0, 0, 255)
        case .cyan:    return (0, 255, 255)
        case .yellow:  return (255, 255, 0)
        case .magenta: return (255, 0, 255)
        }
    }

    static let all: Set<CutColor> = [.red, .green, .blue, .cyan, .yellow, .magenta]
}

/// Extension to check if PDF page has content worth rasterizing
extension PDFRasterizer {
    /// Check if a rasterized page has any engravable content
    static func hasContent(_ page: RasterPage) -> Bool {
        return page.hasInk
    }
}
