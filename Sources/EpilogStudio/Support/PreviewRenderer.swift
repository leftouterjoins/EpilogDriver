/*
 * PreviewRenderer.swift - Draw what the laser is going to do
 *
 * Not what the document looks like. The two differ in exactly the places that
 * matter: a shape routed to the cutter shows as an outline rather than as the
 * filled red blob it is in the file, a layer switched off vanishes, and a layer
 * set to burn solid goes black even if it was drawn in pale yellow. Somebody
 * about to spend a sheet of walnut should be looking at the second picture.
 */

import Foundation
import CoreGraphics
import EpilogKit

enum PreviewRenderer {

    /// Longest edge of a cached preview. Beyond this the extra detail is
    /// invisible at any sane zoom and only costs memory.
    private static let maxPixels: CGFloat = 3000

    /// Render one placed artwork in its own document space.
    ///
    /// - Parameter pixelsPerPoint: rendering density; the caller scales the
    ///   result to wherever the artwork sits on screen.
    static func image(for item: PlacedArtwork, project: LaserProject,
                      pixelsPerPoint: CGFloat) -> CGImage? {
        let size = item.artwork.size
        guard size.width > 0, size.height > 0 else { return nil }

        let density = min(pixelsPerPoint,
                          maxPixels / max(size.width, size.height))
        let width = max(1, Int((size.width * density).rounded()))
        let height = max(1, Int((size.height * density).rounded()))

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        // Document space: points, origin top-left, y down.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: density, y: -density)

        func layer(for path: ArtworkPath) -> LaserLayer? {
            project.layers.first { $0.target == .color(path.keyColor) }
        }
        let background = project.layers.first { $0.target == .background }

        let showBackground = !item.artwork.source.isEmpty
            && (background?.visible ?? true)
            && (background?.operation ?? .engrave) != .skip

        if showBackground {
            // A part split out of a page still carries the whole page as its
            // source. Redrawing that page for each of thirty parts is what made
            // dragging them around unusable, so the page is rendered once and
            // every part takes its own rectangle out of the result.
            if item.artwork.sourceClip != nil,
               let page = SourceRasterCache.shared.pageImage(for: item.artwork,
                                                             density: density) {
                ctx.saveGState()
                if let clip = item.artwork.sourceClip { ctx.clip(to: clip) }
                ctx.concatenate(item.artwork.sourceTransform)
                draw(page, in: ctx, size: item.artwork.sourcePageSize)
                ctx.restoreGState()
            } else {
                item.artwork.drawSource(in: ctx)
            }
        }

        // Anything the source drew that will not burn as drawn has to go: cuts
        // become outlines, hidden layers disappear, solid layers get repainted.
        if showBackground {
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for path in item.artwork.paths {
                guard let l = layer(for: path) else { continue }
                let handledElsewhere = l.operation.isVector
                    || l.operation == .skip
                    || !l.visible
                    || l.rendering == .solid
                guard handledElsewhere else { continue }
                erase(path, in: ctx)
            }
        }

        // Now draw each layer's own representation.
        for path in item.artwork.paths {
            guard let l = layer(for: path), l.visible, l.operation != .skip else { continue }

            switch l.operation {
            case .cut, .score:
                // Cuts read as lines in the layer's colour, whatever the shape
                // was filled with. Kept thin and constant so a hairline cut is
                // as visible as a heavy one.
                let c = l.swatch
                ctx.setStrokeColor(red: c.r, green: c.g, blue: c.b,
                                   alpha: l.enabled ? 1 : 0.3)
                ctx.setLineWidth(max(0.4, 1.1 / density))
                ctx.setLineDash(phase: 0, lengths: l.operation == .score
                                ? [4 / density, 3 / density] : [])
                ctx.addPath(path.path)
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])

            case .engrave:
                if showBackground && l.rendering == .shaded { continue }
                let alpha = l.enabled ? 1.0 : 0.25
                if l.rendering == .solid {
                    if path.fill != nil {
                        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: alpha)
                        ctx.addPath(path.path)
                        if path.usesEvenOdd { ctx.fillPath(using: .evenOdd) } else { ctx.fillPath() }
                    }
                    if path.stroke != nil {
                        ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: alpha)
                        ctx.setLineWidth(path.strokeWidth)
                        ctx.addPath(path.path)
                        ctx.strokePath()
                    }
                } else {
                    if let f = path.fill {
                        ctx.setFillColor(red: f.r, green: f.g, blue: f.b, alpha: alpha)
                        ctx.addPath(path.path)
                        if path.usesEvenOdd { ctx.fillPath(using: .evenOdd) } else { ctx.fillPath() }
                    }
                    if let s = path.stroke {
                        ctx.setStrokeColor(red: s.r, green: s.g, blue: s.b, alpha: alpha)
                        ctx.setLineWidth(path.strokeWidth)
                        ctx.addPath(path.path)
                        ctx.strokePath()
                    }
                }

            case .skip:
                break
            }
        }

        return ctx.makeImage()
    }

    /// Draw a bitmap into a y-down context the right way up.
    static func draw(_ image: CGImage, in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }

    private static func erase(_ path: ArtworkPath, in ctx: CGContext) {
        if path.fill != nil {
            ctx.addPath(path.path)
            if path.usesEvenOdd { ctx.fillPath(using: .evenOdd) } else { ctx.fillPath() }
        }
        if path.stroke != nil {
            ctx.addPath(path.path)
            ctx.setLineWidth(path.strokeWidth + 1)
            ctx.strokePath()
        }
    }
}

/// Whole pages, rendered once and shared by every part split out of them.
final class SourceRasterCache {
    static let shared = SourceRasterCache()

    private struct Key: Hashable {
        let source: ObjectIdentifier
        let density: Int
    }

    private let cache = ImageCache<Key>(budgetBytes: 192 << 20)

    /// Longest edge of a cached page. A page is shared by every part of it, so
    /// it can afford to be larger than any one preview.
    private static let maxPixels: CGFloat = 4000

    func pageImage(for artwork: Artwork, density: CGFloat) -> CGImage? {
        guard let identity = identity(of: artwork.source) else { return nil }
        let page = artwork.sourcePageSize
        guard page.width > 0, page.height > 0 else { return nil }

        let capped = min(density, Self.maxPixels / max(page.width, page.height))
        let bucket = Int((log2(max(capped, 0.02)) * 2).rounded())
        let effective = pow(2, CGFloat(bucket) / 2)

        return cache.image(for: Key(source: identity, density: bucket)) {
            render(artwork.source, pageSize: page, density: effective)
        }
    }

    func removeAll() { cache.removeAll() }

    private func render(_ source: ArtworkSource, pageSize: CGSize,
                        density: CGFloat) -> CGImage? {
        let width = max(1, Int((pageSize.width * density).rounded()))
        let height = max(1, Int((pageSize.height * density).rounded()))

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: density, y: -density)
        source.draw(in: ctx, documentSize: pageSize)
        return ctx.makeImage()
    }

    private func identity(of source: ArtworkSource) -> ObjectIdentifier? {
        switch source {
        case .pdfPage(let page, _): return ObjectIdentifier(page)
        case .image(let image):     return ObjectIdentifier(image)
        case .pathsOnly:            return nil
        }
    }
}

/// Keeps rendered previews around so panning the canvas does not re-render
/// every document on every frame.
final class PreviewCache {
    private struct Key: Hashable {
        let item: UUID
        let signature: Int
        let density: Int
        let generation: Int
    }

    /// Budgeted by memory rather than by count. The old fixed limit of 24 was
    /// fine until Split into Parts turned one document into fifty: every frame
    /// then evicted images it was about to need, and re-rendered them.
    private let cache = ImageCache<Key>(budgetBytes: 320 << 20)

    /// Bumped when artwork is reloaded from disk. Everything else that changes
    /// a preview is covered by the key, but a file edited on disk can come back
    /// with the same name and the same number of paths and different contents.
    var generation = 0

    func image(for item: PlacedArtwork, project: LaserProject,
               pixelsPerPoint: CGFloat) -> CGImage? {
        // Density is bucketed so a smooth zoom does not invalidate the cache on
        // every frame; the image is scaled to fit in between buckets.
        let bucket = Int((log2(max(pixelsPerPoint, 0.05)) * 2).rounded())
        let key = Key(item: item.id,
                      signature: signature(of: item, project: project),
                      density: bucket,
                      generation: generation)

        let density = pow(2, CGFloat(bucket) / 2)
        return cache.image(for: key) {
            PreviewRenderer.image(for: item, project: project, pixelsPerPoint: density)
        }
    }

    func invalidate() {
        cache.removeAll()
        SourceRasterCache.shared.removeAll()
    }

    /// Everything a preview depends on, other than where the artwork sits.
    ///
    /// `LaserProject.appearanceHash` is the authority on which layer settings
    /// change a picture; this adds the parts that belong to the item.
    private func signature(of item: PlacedArtwork, project: LaserProject) -> Int {
        var hasher = Hasher()
        hasher.combine(item.artwork.name)
        hasher.combine(item.artwork.paths.count)
        hasher.combine(item.pageIndex)
        hasher.combine(project.appearanceHash)
        return hasher.finalize()
    }

}
