/*
 * PDFRasterizer.swift - Render PDF to raster bitmap for laser engraving
 *
 * Uses CoreGraphics to render PDF pages to bitmaps that can be
 * processed by the RasterEncoder for laser engraving.
 */

import Foundation
import CoreGraphics
import ImageIO

/// Rasterizes PDF documents to bitmaps for laser engraving
class PDFRasterizer {
    /// Resolution for rasterization (DPI)
    let resolution: Int

    /// Whether to use greyscale (8-bit) or bitmap (1-bit) mode
    let greyscaleMode: Bool

    /// Page dimensions in pixels after rasterization
    struct RasterPage {
        let width: Int
        let height: Int
        let bytesPerLine: Int
        let bitsPerPixel: Int
        let data: Data
    }

    init(resolution: Int, greyscaleMode: Bool = false) {
        self.resolution = resolution
        self.greyscaleMode = greyscaleMode
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

        for pageNum in 1...pageCount {
            guard let page = document.page(at: pageNum) else { continue }
            if let rasterPage = rasterizePage(page) {
                pages.append(rasterPage)
            }
        }

        return pages
    }

    /// Rasterize a single PDF page
    private func rasterizePage(_ page: CGPDFPage) -> RasterPage? {
        // Get page dimensions in points
        let mediaBox = page.getBoxRect(.mediaBox)
        let rotation = page.rotationAngle

        // Calculate dimensions in pixels at target resolution
        let scale = CGFloat(resolution) / 72.0

        var widthPoints = mediaBox.width
        var heightPoints = mediaBox.height

        // Handle rotation
        if rotation == 90 || rotation == 270 {
            swap(&widthPoints, &heightPoints)
        }

        let widthPixels = Int(ceil(widthPoints * scale))
        let heightPixels = Int(ceil(heightPoints * scale))

        fputs("DEBUG: Rasterizing page: \(widthPixels)x\(heightPixels) @ \(resolution)dpi\n", stderr)

        // Create bitmap context
        let bitsPerComponent: Int
        let bytesPerPixel: Int
        let colorSpace: CGColorSpace

        if greyscaleMode {
            // 8-bit greyscale for 3D engraving
            bitsPerComponent = 8
            bytesPerPixel = 1
            colorSpace = CGColorSpaceCreateDeviceGray()
        } else {
            // Render to 8-bit grey, then convert to 1-bit later
            bitsPerComponent = 8
            bytesPerPixel = 1
            colorSpace = CGColorSpaceCreateDeviceGray()
        }

        let bytesPerRow = widthPixels * bytesPerPixel

        guard let context = CGContext(
            data: nil,
            width: widthPixels,
            height: heightPixels,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            fputs("ERROR: Cannot create bitmap context\n", stderr)
            return nil
        }

        // Fill with white background (white = no engraving)
        context.setFillColor(gray: 1.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: widthPixels, height: heightPixels))

        // Apply transformations for rendering
        // PDF coordinate system: origin at bottom-left
        // Scale to resolution
        context.scaleBy(x: scale, y: scale)

        // Handle page rotation
        switch rotation {
        case 90:
            context.translateBy(x: heightPoints, y: 0)
            context.rotate(by: .pi / 2)
        case 180:
            context.translateBy(x: widthPoints, y: heightPoints)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: 0, y: widthPoints)
            context.rotate(by: -.pi / 2)
        default:
            break
        }

        // Translate to account for media box origin
        context.translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)

        // Render the PDF page
        context.drawPDFPage(page)

        // Get the rendered data
        guard let dataPtr = context.data else {
            fputs("ERROR: Cannot get bitmap data\n", stderr)
            return nil
        }

        let dataSize = bytesPerRow * heightPixels
        var rasterData = Data(bytes: dataPtr, count: dataSize)

        // For bitmap mode, convert 8-bit greyscale to 1-bit
        // Also invert: PDF white (255) -> Epilog white (no fire)
        //              PDF black (0) -> Epilog black (fire)
        if !greyscaleMode {
            // For standard bitmap mode, invert the data
            // (In greyscale, darker = more power, which is what we want)
            rasterData = Data(rasterData.map { 255 - $0 })
        } else {
            // For 3D greyscale mode, invert so darker = more power
            rasterData = Data(rasterData.map { 255 - $0 })
        }

        return RasterPage(
            width: widthPixels,
            height: heightPixels,
            bytesPerLine: bytesPerRow,
            bitsPerPixel: bitsPerComponent,
            data: rasterData
        )
    }
}

/// Extension to check if PDF page has content worth rasterizing
extension PDFRasterizer {
    /// Check if a rasterized page has any non-white content
    static func hasContent(_ page: RasterPage) -> Bool {
        // Check if any byte is non-zero (has black/grey content)
        // After inversion, 0 = white (no engraving)
        return page.data.contains { $0 != 0 }
    }
}
