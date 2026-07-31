/*
 * LaserProject.swift - Everything on the bed, and what to do with it
 *
 * Working units are PostScript points with the origin at the bed's top-left
 * corner and y increasing downward, which is where the Epilog's own origin is.
 * Inches are used only where a person reads them.
 */

import Foundation
import CoreGraphics

/// One imported document, positioned on the bed.
public struct PlacedArtwork: Identifiable {
    public var id: UUID
    public var artwork: Artwork

    /// Where it came from, so it can be reloaded when the file changes.
    public var sourceURL: URL?
    public var pageIndex: Int

    /// Top-left of the placed artwork, in bed points, before rotation.
    public var origin: CGPoint

    /// Uniform scale applied to the artwork's natural size.
    public var scale: CGFloat

    /// Rotation about the placed artwork's centre, in radians.
    public var rotation: CGFloat

    /// Drawn in the preview and included in the job.
    public var visible: Bool

    public init(artwork: Artwork, sourceURL: URL? = nil, pageIndex: Int = 1,
                origin: CGPoint = .zero, scale: CGFloat = 1,
                rotation: CGFloat = 0, visible: Bool = true) {
        self.id = UUID()
        self.artwork = artwork
        self.sourceURL = sourceURL
        self.pageIndex = pageIndex
        self.origin = origin
        self.scale = scale
        self.rotation = rotation
        self.visible = visible
    }

    /// Size on the bed, in points, ignoring rotation.
    public var placedSize: CGSize {
        CGSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
    }

    /// Axis-aligned frame before rotation.
    public var frame: CGRect {
        CGRect(origin: origin, size: placedSize)
    }

    /// Transform from document points to bed points.
    public var transform: CGAffineTransform {
        let size = placedSize
        let cx = size.width / 2, cy = size.height / 2
        var t = CGAffineTransform(scaleX: scale, y: scale)
        if rotation != 0 {
            // Turn about the artwork's own centre, which is what a rotation
            // handle in the canvas means, rather than about the bed origin.
            t = t.concatenating(CGAffineTransform(translationX: -cx, y: -cy))
                 .concatenating(CGAffineTransform(rotationAngle: rotation))
                 .concatenating(CGAffineTransform(translationX: cx, y: cy))
        }
        return t.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// Bounding box on the bed, rotation included.
    public var boundsOnBed: CGRect {
        let t = transform
        let s = artwork.size
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: s.width, y: 0),
                       CGPoint(x: s.width, y: s.height), CGPoint(x: 0, y: s.height)]
            .map { $0.applying(t) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Tight bounding box of what will actually be burned, rotation included.
    ///
    /// Differs from `boundsOnBed` for a page-shaped source with a wide margin:
    /// the page is 8.5x11 but the drawing on it is two inches across, and it is
    /// the drawing the operator is trying to line up with their material.
    public var inkBoundsOnBed: CGRect {
        let content = artwork.contentBounds
        guard !content.isEmpty else { return boundsOnBed }
        let t = transform
        let corners = [CGPoint(x: content.minX, y: content.minY),
                       CGPoint(x: content.maxX, y: content.minY),
                       CGPoint(x: content.maxX, y: content.maxY),
                       CGPoint(x: content.minX, y: content.maxY)].map { $0.applying(t) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// A bed, some artwork on it, and the instructions for burning it.
public struct LaserProject {
    public var machine: LaserMachine
    public var items: [PlacedArtwork]
    public var layers: [LaserLayer]

    /// Engraving resolution in DPI. Higher is slower and finer; 500 is the
    /// usual working value on a Zing.
    public var resolution: Int

    /// Measure the material's height before starting.
    public var autofocus: Bool

    /// Manual focus offset in Epilog units (1 unit = 0.0252 mm).
    public var focusOffset: Int

    /// Reorder cuts so holes are cut before the outline that frees the part.
    public var vectorSorting: Bool

    /// Mirror the whole job, for engraving the back of clear material.
    public var mirror: JobOptions.MirrorMode

    /// Encode the engraving as 8-bit power per pixel rather than on/off dots.
    public var rasterMode: RasterMode

    /// Sweep the raster from the bottom of the artwork upward.
    public var engraveBottomUp: Bool

    /// The material these settings were chosen for.
    public var material: MaterialPreset?

    /// Declared stock size in points, for the material outline in the canvas
    /// and for warning when artwork runs off the edge. Zero means unstated.
    public var pieceSize: CGSize

    public var jobName: String

    public init(machine: LaserMachine = .zing24,
                items: [PlacedArtwork] = [],
                layers: [LaserLayer] = [],
                resolution: Int = 500,
                autofocus: Bool = false,
                focusOffset: Int = 0,
                vectorSorting: Bool = true,
                mirror: JobOptions.MirrorMode = .off,
                rasterMode: RasterMode = .bitmap,
                engraveBottomUp: Bool = false,
                material: MaterialPreset? = nil,
                pieceSize: CGSize = .zero,
                jobName: String = "Untitled") {
        self.machine = machine
        self.items = items
        self.layers = layers
        self.resolution = resolution
        self.autofocus = autofocus
        self.focusOffset = focusOffset
        self.vectorSorting = vectorSorting
        self.mirror = mirror
        self.rasterMode = rasterMode
        self.engraveBottomUp = engraveBottomUp
        self.material = material
        self.pieceSize = pieceSize
        self.jobName = jobName
    }

    public var bedSize: CGSize { machine.bedSizePoints }

    /// Whether two projects differ in any way a person could have caused.
    ///
    /// Used to keep no-op entries out of the undo stack. Artwork geometry is
    /// deliberately not compared: it only changes by reloading a file, and that
    /// replaces the item wholesale, which the identity check below already
    /// catches. Comparing thousands of paths on every keystroke to find that
    /// out would cost far more than the entry it saves.
    public func differs(from other: LaserProject) -> Bool {
        if machine != other.machine
            || layers != other.layers
            || resolution != other.resolution
            || autofocus != other.autofocus
            || focusOffset != other.focusOffset
            || vectorSorting != other.vectorSorting
            || mirror != other.mirror
            || rasterMode != other.rasterMode
            || engraveBottomUp != other.engraveBottomUp
            || material != other.material
            || pieceSize != other.pieceSize
            || jobName != other.jobName {
            return true
        }

        guard items.count == other.items.count else { return true }
        for (a, b) in zip(items, other.items) {
            if a.id != b.id || a.origin != b.origin || a.scale != b.scale
                || a.rotation != b.rotation || a.visible != b.visible
                || a.pageIndex != b.pageIndex || a.sourceURL != b.sourceURL {
                return true
            }
        }
        return false
    }

    // MARK: - Layer bookkeeping

    /// The layer governing a given path, or nil if the document has no layer
    /// for that colour yet.
    public func layer(for path: ArtworkPath) -> LaserLayer? {
        layers.first { $0.target == .color(path.keyColor) }
    }

    public func layer(for target: LayerTarget) -> LaserLayer? {
        layers.first { $0.target == target }
    }

    /// Whether any item has content that only the source can draw.
    public var needsBackgroundLayer: Bool {
        items.contains { !$0.artwork.source.isEmpty }
    }

    /// Bring the layer list in line with what the artwork actually contains:
    /// add a layer for each new colour, drop layers whose colour has gone, and
    /// leave every existing layer's settings alone.
    public mutating func synchronizeLayers() {
        var wanted: [LayerTarget] = []
        for item in items {
            for color in item.artwork.distinctColors {
                let target = LayerTarget.color(color)
                if !wanted.contains(target) { wanted.append(target) }
            }
        }
        if needsBackgroundLayer { wanted.append(.background) }

        // Keep what we have, in the order the artwork presents it.
        var updated: [LaserLayer] = []
        for (index, target) in wanted.enumerated() {
            if let existing = layers.first(where: { $0.target == target }) {
                updated.append(existing)
            } else {
                updated.append(LaserLayer.makeDefault(for: target,
                                                      material: material,
                                                      index: index))
            }
        }
        layers = updated
    }

    /// Apply a material's settings to every layer, keeping each layer's role.
    public mutating func applyMaterial(_ preset: MaterialPreset) {
        let adjusted = preset.adjusted(forWatts: machine.watts)
        material = adjusted
        for i in layers.indices {
            switch layers[i].operation {
            case .cut:
                layers[i].power = adjusted.cutPower
                layers[i].speed = adjusted.cutSpeed
                layers[i].frequency = adjusted.cutFrequency
                layers[i].passes = adjusted.cutPasses
            case .score:
                layers[i].power = adjusted.scorePower
                layers[i].speed = adjusted.scoreSpeed
                layers[i].frequency = adjusted.cutFrequency
            case .engrave:
                layers[i].power = adjusted.engravePower
                layers[i].speed = adjusted.engraveSpeed
                layers[i].dither = adjusted.engraveDither
            case .skip:
                break
            }
        }
    }

    /// Hash of everything that changes how the project *looks*.
    ///
    /// Previews are cached against this, so what it leaves out matters more
    /// than what it includes. Power, speed, frequency, passes, dithering and a
    /// layer's name change the job but not the picture. If they were folded in
    /// here, every keystroke in a power field would discard every rendered page
    /// and re-render it - which is exactly as slow as re-rendering a PDF per
    /// character sounds, and is how this got noticed.
    public var appearanceHash: Int {
        var hasher = Hasher()
        for layer in layers {
            hasher.combine(layer.id)
            hasher.combine(layer.target)
            hasher.combine(layer.operation)
            hasher.combine(layer.rendering)
            hasher.combine(layer.visible)
            hasher.combine(layer.enabled)
        }
        return hasher.finalize()
    }

    // MARK: - Extents

    /// Everything that will be burned, in bed points.
    public var contentBounds: CGRect {
        var box = CGRect.null
        for item in items where item.visible {
            box = box.union(item.inkBoundsOnBed)
        }
        return box.isNull ? .zero : box
    }

    /// Whether any visible item runs off the bed.
    public var hasContentOffBed: Bool {
        let bed = CGRect(origin: .zero, size: bedSize)
        for item in items where item.visible {
            let b = item.inkBoundsOnBed
            if b.minX < -0.5 || b.minY < -0.5
                || b.maxX > bed.width + 0.5 || b.maxY > bed.height + 0.5 {
                return true
            }
        }
        return false
    }

    /// Whether any visible item runs off the declared stock.
    public var hasContentOffMaterial: Bool {
        guard pieceSize.width > 0, pieceSize.height > 0 else { return false }
        let b = contentBounds
        guard !b.isEmpty else { return false }
        return b.minX < -0.5 || b.minY < -0.5
            || b.maxX > pieceSize.width + 0.5 || b.maxY > pieceSize.height + 0.5
    }

    // MARK: - Placement helpers

    public mutating func centerOnBed(itemID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        let b = items[i].boundsOnBed
        let dx = (bedSize.width - b.width) / 2 - b.minX
        let dy = (bedSize.height - b.height) / 2 - b.minY
        items[i].origin.x += dx
        items[i].origin.y += dy
    }

    public mutating func moveToOrigin(itemID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        let b = items[i].boundsOnBed
        items[i].origin.x -= b.minX
        items[i].origin.y -= b.minY
    }

    /// Scale an item down so it fits the bed. Never scales up: a small part
    /// blown up to fill the bed is nobody's intention.
    public mutating func fitToBed(itemID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        let natural = items[i].artwork.size
        guard natural.width > 0, natural.height > 0 else { return }
        let fit = min(bedSize.width / natural.width, bedSize.height / natural.height)
        if fit < items[i].scale { items[i].scale = fit }
        moveToOrigin(itemID: itemID)
    }
}
