/*
 * ArtworkImporter.swift - One door for every kind of file we accept
 */

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ArtworkImporter {

    /// File extensions the application will open.
    public static let supportedExtensions = ["pdf", "svg", "png", "jpg", "jpeg",
                                             "tif", "tiff", "gif", "bmp", "heic", "webp"]

    /// Uniform type identifiers, for the open panel and drag-and-drop.
    public static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .svg, .png, .jpeg, .tiff, .gif, .bmp, .image]
        if let heic = UTType("public.heic") { types.append(heic) }
        return types
    }

    /// Read any supported file.
    ///
    /// - Parameter pageIndex: which page to take from a multi-page PDF, 1-based.
    public static func importArtwork(from url: URL, pageIndex: Int = 1) throws -> Artwork {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try PDFArtworkImporter.importArtwork(from: url, pageIndex: pageIndex)
        case "svg":
            return try SVGArtworkImporter.importArtwork(from: url)
        case "png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "webp":
            return try BitmapArtworkImporter.importArtwork(from: url)
        default:
            // Trust the file's contents over its name: a screenshot saved
            // without an extension is still a screenshot.
            if let artwork = try? BitmapArtworkImporter.importArtwork(from: url) {
                return artwork
            }
            throw ArtworkImportError.unsupportedFormat(ext.isEmpty ? "unnamed" : ext)
        }
    }

    /// How many pages this file offers. One for anything that is not a PDF.
    public static func pageCount(of url: URL) -> Int {
        url.pathExtension.lowercased() == "pdf"
            ? max(1, PDFArtworkImporter.pageCount(of: url))
            : 1
    }
}

/// Photographs and screenshots: no geometry, all tone.
public enum BitmapArtworkImporter {

    public static func importArtwork(from url: URL) throws -> Artwork {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ArtworkImportError.unreadableFile(url)
        }
        return artwork(from: image,
                       name: url.deletingPathExtension().lastPathComponent,
                       source: source)
    }

    public static func importArtwork(from data: Data, name: String) throws -> Artwork {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ArtworkImportError.malformed("not a readable image")
        }
        return artwork(from: image, name: name, source: source)
    }

    private static func artwork(from image: CGImage, name: String,
                                source: CGImageSource?) -> Artwork {
        // Size the artwork by the image's own DPI when it declares one, so a
        // 300dpi scan arrives at its physical size rather than as a wall-sized
        // page of pixels. Screenshots and web images rarely say, and 72 is the
        // right assumption for those.
        var dpiX = 72.0, dpiY = 72.0
        if let source,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let x = props[kCGImagePropertyDPIWidth] as? Double, x > 1 { dpiX = x }
            if let y = props[kCGImagePropertyDPIHeight] as? Double, y > 1 { dpiY = y }
        }

        let size = CGSize(width: Double(image.width) * 72.0 / dpiX,
                          height: Double(image.height) * 72.0 / dpiY)

        EpilogLog.debug("Imported \(name): \(image.width)x\(image.height) bitmap at "
                        + String(format: "%.0f dpi, %.1f x %.1f pt", dpiX, size.width, size.height))

        return Artwork(name: name,
                       size: size,
                       paths: [],
                       source: .image(image),
                       paintedOperatorCount: 0,
                       imageCount: 1)
    }
}
