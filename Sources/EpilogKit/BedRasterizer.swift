/*
 * BedRasterizer.swift - Turn one engraving pass into pixels
 *
 * Rendered in horizontal bands so a full 24x12" bed at 1000 DPI stays inside a
 * few tens of megabytes rather than the gigabyte a single RGBA buffer would
 * need.
 *
 * The composition rule matters more than the mechanics. For a given pass:
 *
 *   - Draw the source (the PDF page, the photograph) only if this pass owns
 *     the background layer. That is what carries text and images.
 *   - Paint white over every path the source drew that this pass does not own,
 *     and over the ones it does own but wants burned solid. Whatever the
 *     cutter is going to follow must not also be engraved, and a shape marked
 *     "solid" must not show its original light colour underneath.
 *   - Draw this pass's own paths: solid black, or in their own tone.
 *
 * Which is the whole reason for keeping paths and source separate: a driver
 * that only has the rendered page can subtract cuts by guessing at their
 * colour, and a driver that only has paths loses every word of text.
 */

import Foundation
import CoreGraphics

public struct BedRasterizer {

    /// One engraving pass: the layers that share power, speed and dithering.
    public struct Pass {
        public let layerIDs: Set<UUID>
        public let includesBackground: Bool
        public let power: Int
        public let speed: Int
        public let dither: DitherMode
        public let passes: Int

        public init(layerIDs: Set<UUID>, includesBackground: Bool,
                    power: Int, speed: Int, dither: DitherMode, passes: Int) {
            self.layerIDs = layerIDs
            self.includesBackground = includesBackground
            self.power = power
            self.speed = speed
            self.dither = dither
            self.passes = passes
        }
    }

    /// A rendered pass, ready for the RasterEncoder.
    public struct Bitmap {
        public let width: Int
        public let height: Int
        public let bytesPerLine: Int
        public let bitsPerPixel: Int
        public let data: Data

        /// Bounding box of engravable ink, in absolute bed pixels.
        public let inkMinX: Int
        public let inkMinY: Int
        public let inkMaxX: Int
        public let inkMaxY: Int

        public var hasInk: Bool { inkMinX <= inkMaxX && inkMinY <= inkMaxY }
    }

    /// Rows rendered at a time. 256 rows of a 24000px-wide bed is ~24 MB.
    private static let bandRows = 256

    /// Ink threshold for 1-bit conversion: a pixel fires when its darkness
    /// reaches this.
    public var threshold: UInt8 = 128

    /// Floor on stroke width, in device pixels. Zero for a real job, where the
    /// artwork's own widths are the whole point.
    ///
    /// Raised only for previews, which are drawn at a fraction of the job's
    /// resolution: a hairline is a third of a pixel wide there and disappears
    /// completely, so a page of fine line art previews as an empty rectangle.
    /// Better to show it a pixel wide than not at all.
    public var minimumStrokeWidthPx: CGFloat = 0

    public init(threshold: UInt8 = 128, minimumStrokeWidthPx: CGFloat = 0) {
        self.threshold = threshold
        self.minimumStrokeWidthPx = minimumStrokeWidthPx
    }

    // MARK: - Rendering

    public func render(_ prepared: PreparedProject, pass: Pass,
                       mode: RasterMode,
                       shouldCancel: () -> Bool = { false }) -> Bitmap? {

        let width = prepared.widthPx
        let height = prepared.heightPx
        guard width > 0, height > 0 else { return nil }

        let bitsPerPixel = (mode == .bitmap) ? 1 : 8
        let bytesPerLine = (mode == .bitmap) ? (width + 7) / 8 : width

        // Only rows that could contain something are worth rendering. A stamp
        // in the corner of a two-foot bed should not cost a full-bed render.
        let interesting = interestingRows(prepared, pass: pass, height: height)
        guard let rowRange = interesting else {
            EpilogLog.debug("Engraving pass has no content on the bed")
            return Bitmap(width: width, height: height, bytesPerLine: bytesPerLine,
                          bitsPerPixel: bitsPerPixel,
                          data: Data(count: bytesPerLine * height),
                          inkMinX: 1, inkMinY: 1, inkMaxX: 0, inkMaxY: 0)
        }

        var output = Data(count: bytesPerLine * height)

        var inkMinX = Int.max, inkMinY = Int.max
        var inkMaxX = Int.min, inkMaxY = Int.min

        // Error-diffusion state. Rows run strictly top to bottom but arrive in
        // bands, so accumulated error has to outlive a band or every boundary
        // shows as a seam. A manually managed ring of (rowsAhead + 1) rows.
        let diffusing = (mode == .bitmap) && !pass.dither.kernel.taps.isEmpty
        let errRowCount = pass.dither.rowsAhead + 1
        let errStride = width + 4          // slack so dx of -2..+2 needs no bounds test
        let errOrigin = 2
        let errCapacity = diffusing ? errRowCount * errStride : 1
        let errBuf = UnsafeMutablePointer<Int32>.allocate(capacity: errCapacity)
        errBuf.initialize(repeating: 0, count: errCapacity)
        defer { errBuf.deallocate() }
        var errBase = 0
        let taps = pass.dither.kernel.taps
        let divisor = Int32(pass.dither.kernel.divisor)

        let srcBytesPerRow = width * 4
        var band = [UInt8](repeating: 0, count: srcBytesPerRow * Self.bandRows)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue

        var bandStart = rowRange.lowerBound
        while bandStart < rowRange.upperBound {
            if shouldCancel() { return nil }
            let rows = min(Self.bandRows, rowRange.upperBound - bandStart)

            let drawn: Bool = band.withUnsafeMutableBytes { raw -> Bool in
                guard let ptr = raw.baseAddress else { return false }
                // White background: nothing to engrave where the bed is empty.
                memset(ptr, 0xFF, srcBytesPerRow * rows)

                guard let ctx = CGContext(data: ptr, width: width, height: rows,
                                          bitsPerComponent: 8, bytesPerRow: srcBytesPerRow,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else {
                    return false
                }

                // Put the context into device space: pixels, y down, origin at
                // the bed's top-left, with this band's rows in view.
                ctx.translateBy(x: 0, y: CGFloat(rows))
                ctx.scaleBy(x: 1, y: -1)
                ctx.translateBy(x: 0, y: -CGFloat(bandStart))

                ctx.setShouldAntialias(true)
                ctx.interpolationQuality = .high

                compose(into: ctx, prepared: prepared, pass: pass)
                ctx.flush()
                return true
            }

            guard drawn else {
                EpilogLog.error("Cannot create a bitmap context for the row at \(bandStart)")
                return nil
            }

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
                        let cur = errBuf + errBase + errOrigin

                        for x in 0..<width {
                            let p = srcRow + x * 4
                            let ink = inkValue(r: p[0], g: p[1], b: p[2])

                            var fires = false

                            if mode == .bitmap {
                                if diffusing {
                                    // Accumulated error can push a white pixel
                                    // over the line or hold a grey one back, so
                                    // every pixel is evaluated, not just inked ones.
                                    let v = Int32(ink) + cur[x]
                                    fires = v >= 128
                                    let err = v - (fires ? 255 : 0)
                                    if err != 0 {
                                        for tap in taps {
                                            let slot = (errBase + tap.dy * errStride)
                                                % (errRowCount * errStride)
                                            (errBuf + slot + errOrigin + x + tap.dx).pointee
                                                += err * Int32(tap.w) / divisor
                                        }
                                    }
                                } else if pass.dither == .ordered {
                                    guard ink > 0 else { continue }
                                    let m = DitherMode.bayer8[(pageRow & 7) * 8 + (x & 7)]
                                    fires = ink > m
                                } else {
                                    guard ink > 0 else { continue }
                                    fires = ink >= threshold
                                }

                                guard fires else { continue }
                                let byte = dstRow.advanced(by: x >> 3)
                                    .assumingMemoryBound(to: UInt8.self)
                                byte.pointee |= UInt8(0x80 >> (x & 7))
                            } else {
                                // 8-bit mode carries tone directly; dithering it
                                // would throw away the information it encodes.
                                guard ink > 0 else { continue }
                                dstRow.advanced(by: x)
                                    .assumingMemoryBound(to: UInt8.self).pointee = ink
                            }

                            if x < rowMinX { rowMinX = x }
                            if x > rowMaxX { rowMaxX = x }
                        }

                        if diffusing {
                            (errBuf + errBase).update(repeating: 0, count: errStride)
                            errBase = (errBase + errStride) % (errRowCount * errStride)
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

        let empty = inkMinX > inkMaxX
        if empty {
            EpilogLog.debug("Engraving pass rendered nothing")
        } else {
            EpilogLog.debug("Engraving pass ink box: x \(inkMinX)..\(inkMaxX), "
                            + "y \(inkMinY)..\(inkMaxY)")
        }

        return Bitmap(width: width, height: height, bytesPerLine: bytesPerLine,
                      bitsPerPixel: bitsPerPixel, data: output,
                      inkMinX: empty ? 1 : inkMinX,
                      inkMinY: empty ? 1 : inkMinY,
                      inkMaxX: empty ? 0 : inkMaxX,
                      inkMaxY: empty ? 0 : inkMaxY)
    }

    /// Render a pass small, for showing someone what it is going to do.
    ///
    /// Composed by the same code that builds the real thing, so what it shows
    /// is what will burn - the alternative, drawing a box round the extent, was
    /// only ever telling you where the head would travel, not which parts of
    /// the material it would mark on the way.
    ///
    /// `scale` is relative to the job's own resolution: 0.1 of a 500 DPI job is
    /// 50 DPI, which is plenty to recognise artwork by and a hundredth of the
    /// pixels.
    public func previewImage(_ prepared: PreparedProject, pass: Pass,
                             scale: CGFloat) -> CGImage? {
        // Keep thin strokes at least a pixel wide once scaled down.
        var scaled = self
        scaled.minimumStrokeWidthPx = 1 / max(scale, 0.0001)

        let width = max(1, Int((CGFloat(prepared.widthPx) * scale).rounded()))
        let height = max(1, Int((CGFloat(prepared.heightPx) * scale).rounded()))

        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Into device space: pixels at the job resolution, y down, origin at
        // the bed's top-left - the same space compose() expects.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        scaled.compose(into: ctx, prepared: prepared, pass: pass)
        return ctx.makeImage()
    }

    // MARK: - Composition

    private func compose(into ctx: CGContext, prepared: PreparedProject, pass: Pass) {
        for item in prepared.items {

            if pass.includesBackground && !item.source.isEmpty {
                ctx.saveGState()
                ctx.concatenate(item.sourceTransform)
                item.artwork.drawSource(in: ctx)
                ctx.restoreGState()

                // Everything the source drew that this pass does not own has to
                // go, plus anything this pass wants burned solid rather than in
                // its own colour.
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.setStrokeColor(gray: 1, alpha: 1)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                for p in item.paths where shouldEraseFromSource(p, pass: pass, prepared: prepared) {
                    paint(p, in: ctx, erase: true)
                }
            }

            // This pass's own artwork.
            for p in item.paths {
                guard let id = p.layerID, pass.layerIDs.contains(id) else { continue }
                guard let layer = prepared.project.layers.first(where: { $0.id == id }) else { continue }
                // Already present from the source, in its own tone: leave it.
                if pass.includesBackground && !item.source.isEmpty && layer.rendering == .shaded {
                    continue
                }
                let color: ArtworkColor? = layer.rendering == .solid ? .black : nil
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                paint(p, in: ctx, erase: false, forcedColor: color)
            }
        }
    }

    /// Whether a path the source already drew must be painted over.
    private func shouldEraseFromSource(_ p: PreparedProject.Path, pass: Pass,
                                       prepared: PreparedProject) -> Bool {
        guard let id = p.layerID else {
            // No layer owns it, so nothing will burn it deliberately. Leave it
            // to the source rather than silently deleting artwork.
            return false
        }
        guard let layer = prepared.project.layers.first(where: { $0.id == id }) else { return false }
        if !pass.layerIDs.contains(id) { return true }
        return layer.rendering == .solid
    }

    /// Draw one prepared path, either as artwork or as an eraser.
    private func paint(_ p: PreparedProject.Path, in ctx: CGContext,
                       erase: Bool, forcedColor: ArtworkColor? = nil) {
        guard !p.path.isEmpty else { return }

        if p.fill != nil {
            let c = erase ? ArtworkColor.white : (forcedColor ?? p.fill!)
            ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            ctx.addPath(p.path)
            if p.usesEvenOdd { ctx.fillPath(using: .evenOdd) } else { ctx.fillPath() }
        }

        if p.stroke != nil {
            let c = erase ? ArtworkColor.white : (forcedColor ?? p.stroke!)
            ctx.setStrokeColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            ctx.addPath(p.path)
            // Erasing widens slightly: the cut has kerf and the rendered
            // artwork is antialiased, so covering exactly the nominal width
            // leaves a fringe of half-lit pixels that would engrave alongside
            // the cut and show as a shadow beside every edge.
            let width = max(p.strokeWidthPx, minimumStrokeWidthPx)
            ctx.setLineWidth(erase ? width + 2 : width)
            ctx.strokePath()
        }
    }

    // MARK: - Extent

    /// Rows that could possibly hold something for this pass.
    private func interestingRows(_ prepared: PreparedProject, pass: Pass,
                                 height: Int) -> Range<Int>? {
        var box = CGRect.null

        for item in prepared.items {
            if pass.includesBackground && !item.source.isEmpty {
                let size = item.documentSize
                let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                               CGPoint(x: size.width, y: size.height),
                               CGPoint(x: 0, y: size.height)]
                    .map { $0.applying(item.sourceTransform) }
                let xs = corners.map(\.x), ys = corners.map(\.y)
                box = box.union(CGRect(x: xs.min()!, y: ys.min()!,
                                       width: xs.max()! - xs.min()!,
                                       height: ys.max()! - ys.min()!))
            }
            for p in item.paths {
                guard let id = p.layerID, pass.layerIDs.contains(id) else { continue }
                let b = p.path.boundingBox.insetBy(dx: -p.strokeWidthPx, dy: -p.strokeWidthPx)
                if !b.isNull && !b.isInfinite { box = box.union(b) }
            }
        }

        guard !box.isNull, !box.isInfinite else { return nil }

        let lower = max(0, Int(floor(box.minY)) - 1)
        let upper = min(height, Int(ceil(box.maxY)) + 1)
        return lower < upper ? lower..<upper : nil
    }

    /// Darkness of a rendered pixel: 0 leaves the material alone, 255 is full power.
    private func inkValue(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        // Rec. 601 luma, then inverted so dark artwork means high power.
        let luma = (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000
        return UInt8(255 - min(255, luma))
    }
}
