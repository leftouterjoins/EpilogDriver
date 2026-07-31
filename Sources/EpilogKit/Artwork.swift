/*
 * Artwork.swift - What a document actually contains
 *
 * The CUPS filter never had a document model. It rendered the whole page to a
 * bitmap, separately scanned it for paths that looked like cuts, and hoped the
 * two agreed. That works when the rule is fixed ("cyan hairlines are cuts") and
 * falls apart the moment a person wants to decide for themselves.
 *
 * So: an Artwork is a list of vector paths, each carrying the colour it was
 * painted in, plus the source needed to reproduce everything a path cannot
 * describe - text, photographs, gradients. Layer assignment keys off the path
 * colours; the raster pass renders the source and subtracts whatever the
 * cutter is going to handle.
 *
 * Coordinates are in points with the origin at the TOP-LEFT and y increasing
 * downward, matching both the laser bed and screen space. PDF's bottom-left
 * origin is flipped away at import so nothing downstream has to think about it.
 */

import Foundation
import CoreGraphics

// MARK: - Colour

/// A colour as the source document declared it.
public struct ArtworkColor: Hashable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = min(1, max(0, r))
        self.g = min(1, max(0, g))
        self.b = min(1, max(0, b))
    }

    public init(r8: UInt8, g8: UInt8, b8: UInt8) {
        self.init(r: Double(r8) / 255, g: Double(g8) / 255, b: Double(b8) / 255)
    }

    public var bytes: (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8((r * 255).rounded()), UInt8((g * 255).rounded()), UInt8((b * 255).rounded()))
    }

    /// Rec. 601 luma, 0 (black) to 1 (white).
    public var luma: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    /// How far this colour is from grey, 0 to 1.
    public var saturation: Double {
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        return mx - mn
    }

    /// `#RRGGBB`, for display and for keying layers in saved projects.
    public var hex: String {
        let (r8, g8, b8) = bytes
        return String(format: "#%02X%02X%02X", Int(r8), Int(g8), Int(b8))
    }

    public init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(r8: UInt8((v >> 16) & 0xFF), g8: UInt8((v >> 8) & 0xFF), b8: UInt8(v & 0xFF))
    }

    /// Snap to the nominal cut colour when this is recognisably one of them.
    ///
    /// Documents rarely contain exactly (0,255,255): an application writes
    /// cyan as (0.0, 0.68, 0.94), or antialiasing and colour management shift
    /// it. Without snapping, three drawings of "the same" cyan would become
    /// three separate layers, each needing its own settings.
    public var snappedToCutColor: ArtworkColor {
        let (r8, g8, b8) = bytes
        guard let cc = CutColor(r: r8, g: g8, b: b8) else { return self }
        let rgb = cc.rgb
        return ArtworkColor(r8: rgb.r, g8: rgb.g, b8: rgb.b)
    }

    /// Close enough to white that it is a backdrop rather than a colour.
    ///
    /// Applications are careless about this: a canvas set to white is written
    /// as #FFFFFF by one program and #FEFEFE by the next, and a colour-managed
    /// export can shift it further. Anything this pale is not something anyone
    /// meant to burn.
    public var isNearWhite: Bool { luma > 0.93 && saturation < 0.08 }

    public static let black = ArtworkColor(r: 0, g: 0, b: 0)
    public static let white = ArtworkColor(r: 1, g: 1, b: 1)
}

// MARK: - Primitives

/// One painted path lifted out of a document.
public struct ArtworkPath {
    /// Geometry in document points, origin top-left, y down.
    public var path: CGPath

    /// Colour of the stroke, if the path was stroked.
    public var stroke: ArtworkColor?

    /// Stroke width in document points, after the document's own transforms.
    public var strokeWidth: CGFloat

    /// Colour of the fill, if the path was filled.
    public var fill: ArtworkColor?

    /// Whether the fill used the even-odd rule rather than nonzero winding.
    public var usesEvenOdd: Bool

    public init(path: CGPath, stroke: ArtworkColor? = nil, strokeWidth: CGFloat = 1,
                fill: ArtworkColor? = nil, usesEvenOdd: Bool = false) {
        self.path = path
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.fill = fill
        self.usesEvenOdd = usesEvenOdd
    }

    /// The colour this path is filed under.
    ///
    /// A stroke wins over a fill, because the stroke is the outline a cutter
    /// would follow and it is how people mark up artwork for cutting.
    public var keyColor: ArtworkColor {
        (stroke ?? fill ?? .black).snappedToCutColor
    }

    /// True when the path only exists as an outline. Filled shapes handed to
    /// the cutter still cut only their boundary, but they should be subtracted
    /// from the engraving as solid areas rather than as thin lines.
    public var isStrokeOnly: Bool { fill == nil && stroke != nil }
}

/// Where the parts of a document that are not paths come from.
///
/// Text, photographs and gradients cannot be represented as coloured outlines,
/// and trying would mean reimplementing a PDF renderer. Instead the original is
/// kept and drawn whenever a raster is needed.
public enum ArtworkSource {
    /// A PDF page, together with the transform taking PDF user space into
    /// document space. The importer works that out once - it has to, in order
    /// to place the extracted paths - so the renderer reuses it rather than
    /// deriving the media box and page rotation a second time and risking a
    /// half-pixel disagreement between what is cut and what is engraved.
    case pdfPage(CGPDFPage, transform: CGAffineTransform)
    /// A bitmap.
    case image(CGImage)
    /// The paths are the whole document - nothing else to draw.
    case pathsOnly

    /// Draw the source into `ctx`, which is already set up so that document
    /// points map to the right place.
    public func draw(in ctx: CGContext, documentSize: CGSize) {
        switch self {
        case .pdfPage(let page, let transform):
            ctx.saveGState()
            ctx.concatenate(transform)
            ctx.drawPDFPage(page)
            ctx.restoreGState()

        case .image(let image):
            ctx.saveGState()
            // CGContext.draw flips images into y-up space; undo that so the
            // bitmap lands the right way round in y-down document space.
            ctx.translateBy(x: 0, y: documentSize.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: documentSize))
            ctx.restoreGState()

        case .pathsOnly:
            break
        }
    }

    /// Whether drawing this source produces anything at all.
    public var isEmpty: Bool {
        if case .pathsOnly = self { return true }
        return false
    }
}

// MARK: - Artwork

/// A document ready to be placed on the bed.
public struct Artwork {
    /// Display name, usually the file name.
    public var name: String

    /// Natural size in points.
    public var size: CGSize

    /// Vector geometry, in document points, origin top-left, y down.
    public var paths: [ArtworkPath]

    /// Everything the paths do not cover.
    public var source: ArtworkSource

    /// Applied to the source before it is drawn, in this artwork's own space.
    ///
    /// Only ever anything other than the identity for a piece split out of a
    /// larger document: the piece's coordinates start at its own corner, but
    /// the page it came from still draws from the page's corner, so the page
    /// has to be shifted to line up.
    public var sourceTransform: CGAffineTransform = .identity

    /// The region of this artwork the source may paint into.
    ///
    /// Without it, every piece split out of one page would draw the whole page,
    /// and each piece would carry every other piece's text and photographs on
    /// top of its own.
    public var sourceClip: CGRect?

    /// How many painting operators the importer saw. Zero paths but a nonzero
    /// count means the document draws only text or images - worth telling the
    /// user, because no amount of layer configuration will produce a cut.
    public var paintedOperatorCount: Int

    /// How many images the document drew.
    public var imageCount: Int

    public init(name: String, size: CGSize, paths: [ArtworkPath],
                source: ArtworkSource, paintedOperatorCount: Int = 0,
                imageCount: Int = 0,
                sourceTransform: CGAffineTransform = .identity,
                sourceClip: CGRect? = nil) {
        self.name = name
        self.size = size
        self.paths = paths
        self.source = source
        self.paintedOperatorCount = paintedOperatorCount
        self.imageCount = imageCount
        self.sourceTransform = sourceTransform
        self.sourceClip = sourceClip
    }

    /// Draw whatever the paths cannot describe, into a context already in this
    /// artwork's coordinates.
    public func drawSource(in ctx: CGContext) {
        guard !source.isEmpty else { return }
        ctx.saveGState()
        if let clip = sourceClip { ctx.clip(to: clip) }
        ctx.concatenate(sourceTransform)
        source.draw(in: ctx, documentSize: size)
        ctx.restoreGState()
    }

    /// Distinct colours across all paths, in the order first encountered.
    ///
    /// Order matters: it decides how layers are listed, and drawing order is
    /// far more meaningful to the person who made the file than sorting by hue
    /// would be.
    public var distinctColors: [ArtworkColor] {
        var seen = Set<ArtworkColor>()
        var result: [ArtworkColor] = []
        for path in paths {
            let key = path.keyColor
            if seen.insert(key).inserted { result.append(key) }
        }
        return result
    }

    /// Bounding box of the vector geometry, in document points.
    /// Empty when there are no paths.
    public var pathBounds: CGRect {
        var box = CGRect.null
        for p in paths {
            let b = p.stroke != nil
                ? p.path.boundingBox.insetBy(dx: -p.strokeWidth / 2, dy: -p.strokeWidth / 2)
                : p.path.boundingBox
            if !b.isNull && !b.isInfinite { box = box.union(b) }
        }
        return box.isNull ? .zero : box
    }

    /// Bounding box of everything, which for a page-shaped source is the page.
    public var contentBounds: CGRect {
        source.isEmpty ? pathBounds : CGRect(origin: .zero, size: size)
    }

    /// Remove the white rectangle behind the artwork, if there is one.
    ///
    /// Drawing programs put one there whenever a canvas has a background
    /// colour, and it is not artwork. Left in, it becomes a layer like any
    /// other - and since it is a pale colour, the sensible default for a pale
    /// colour is to burn it solid so it does not come out faint. The result is
    /// a bed-sized black rectangle, an hour of machine time and a ruined
    /// sheet. So it goes, and the log says it went.
    ///
    /// Only filled shapes qualify. A white *outline* around the page is
    /// somebody marking a cut, which is the opposite of a backdrop.
    ///
    /// - Returns: how many shapes were removed.
    @discardableResult
    public mutating func removeBackdropShapes() -> Int {
        let area = size.width * size.height
        guard area > 0 else { return 0 }

        let before = paths.count
        paths.removeAll { path in
            guard let fill = path.fill, path.stroke == nil, fill.isNearWhite else {
                return false
            }
            let box = path.path.boundingBox
            guard !box.isNull, !box.isInfinite else { return false }
            // Most of the page. A small white shape is a highlight or a
            // cut-out and belongs to the drawing.
            return (box.width * box.height) / area >= 0.8
        }
        return before - paths.count
    }
}

// MARK: - Errors

public enum ArtworkImportError: LocalizedError {
    case unreadableFile(URL)
    case unsupportedFormat(String)
    case emptyDocument
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let url):
            return "Could not read \(url.lastPathComponent)."
        case .unsupportedFormat(let ext):
            return "\(ext.uppercased()) files are not supported. "
                 + "Open a PDF, SVG, PNG, JPEG or TIFF."
        case .emptyDocument:
            return "That file has no pages or artwork in it."
        case .malformed(let detail):
            return "That file could not be understood: \(detail)"
        }
    }
}
