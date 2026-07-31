/*
 * PreparedProject.swift - Resolve a project into device pixels, once
 *
 * Both halves of a job need the same geometry in the same place: the raster
 * pass has to know which pixels a cut will cover so it does not engrave them
 * too, and the vector pass has to emit those same outlines as motion. Deriving
 * that twice is how a driver ends up cutting half a millimetre away from what
 * it engraved, so it is derived once, here.
 *
 * Device space is pixels at the job resolution, origin at the bed's top-left,
 * y increasing downward - which is exactly the coordinate system the Epilog's
 * PCL and HPGL both use.
 */

import Foundation
import CoreGraphics

public struct PreparedProject {

    /// One path, already in device pixels and already matched to its layer.
    public struct Path {
        public let path: CGPath
        public let strokeWidthPx: CGFloat
        public let fill: ArtworkColor?
        public let stroke: ArtworkColor?
        public let usesEvenOdd: Bool
        /// The layer governing this path, or nil if the project has no layer
        /// for its colour (which should not happen after synchronizeLayers).
        public let layerID: UUID?
        /// Outline with no fill: subtracted from the engraving as a line
        /// rather than as a solid area.
        public let isStrokeOnly: Bool
    }

    public struct Item {
        public let artwork: Artwork
        /// Document points to device pixels.
        public let sourceTransform: CGAffineTransform
        public let paths: [Path]

        public var documentSize: CGSize { artwork.size }
        public var source: ArtworkSource { artwork.source }
    }

    public let widthPx: Int
    public let heightPx: Int
    public let resolution: Int
    public let items: [Item]
    public let project: LaserProject

    /// Bed points to device pixels, mirroring included.
    public let bedTransform: CGAffineTransform

    public init(project: LaserProject) {
        self.project = project
        self.resolution = project.resolution

        let scale = CGFloat(project.resolution) / 72.0
        let bed = project.bedSize
        let w = Int(ceil(bed.width * scale))
        let h = Int(ceil(bed.height * scale))
        self.widthPx = max(1, w)
        self.heightPx = max(1, h)

        // Mirroring happens here, in bed space, so the raster and the cuts flip
        // together and stay registered. Flipping the finished bitmap instead
        // would leave the vectors behind.
        var t = CGAffineTransform(scaleX: scale, y: scale)
        if project.mirror.flipX {
            t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
                 .concatenating(CGAffineTransform(translationX: CGFloat(widthPx), y: 0))
        }
        if project.mirror.flipY {
            t = t.concatenating(CGAffineTransform(scaleX: 1, y: -1))
                 .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(heightPx)))
        }
        self.bedTransform = t

        var prepared: [Item] = []
        for item in project.items where item.visible {
            var toDevice = item.transform.concatenating(t)
            let pathScale = sqrt(abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c))

            var paths: [Path] = []
            paths.reserveCapacity(item.artwork.paths.count)
            for artPath in item.artwork.paths {
                guard let moved = artPath.path.copy(using: &toDevice) else { continue }
                let layer = project.layer(for: artPath)
                paths.append(Path(path: moved,
                                  strokeWidthPx: max(1, artPath.strokeWidth * pathScale),
                                  fill: artPath.fill,
                                  stroke: artPath.stroke,
                                  usesEvenOdd: artPath.usesEvenOdd,
                                  layerID: layer?.id,
                                  isStrokeOnly: artPath.isStrokeOnly))
            }

            prepared.append(Item(artwork: item.artwork,
                                 sourceTransform: toDevice,
                                 paths: paths))
        }
        self.items = prepared
    }

    /// Every prepared path across every item, with its layer resolved.
    public func paths(matching predicate: (LaserLayer) -> Bool) -> [(Path, LaserLayer)] {
        var result: [(Path, LaserLayer)] = []
        let byID = Dictionary(uniqueKeysWithValues: project.layers.map { ($0.id, $0) })
        for item in items {
            for p in item.paths {
                guard let id = p.layerID, let layer = byID[id], predicate(layer) else { continue }
                result.append((p, layer))
            }
        }
        return result
    }
}

// MARK: - Flattening

extension CGPath {
    /// Approximate every curve with line segments, which is all the laser can
    /// follow: HPGL has no curve primitive.
    ///
    /// `tolerancePx` is the largest deviation allowed between the curve and its
    /// approximation. Segment count is derived from the control polygon's
    /// length so a long sweeping curve gets more segments than a tight one,
    /// instead of every curve getting the same fixed ten the old extractor used.
    public func flattenedPolylines(tolerancePx: CGFloat = 0.4) -> [[CGPoint]] {
        var polylines: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        var here = CGPoint.zero

        func segmentCount(_ controlLength: CGFloat) -> Int {
            guard controlLength > 0 else { return 1 }
            // For a cubic, error falls roughly as 1/n^2, so n ~ sqrt(L / (8*tol)).
            let n = Int(ceil((controlLength / max(tolerancePx, 0.01) / 8).squareRoot()))
            return min(max(n, 1), 256)
        }

        applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                if current.count > 1 { polylines.append(current) }
                here = element.points[0]
                start = here
                current = [here]

            case .addLineToPoint:
                here = element.points[0]
                current.append(here)

            case .addCurveToPoint:
                let c1 = element.points[0], c2 = element.points[1], end = element.points[2]
                let len = distance(here, c1) + distance(c1, c2) + distance(c2, end)
                let n = segmentCount(len)
                for i in 1...n {
                    let t = CGFloat(i) / CGFloat(n)
                    current.append(cubicPoint(t, here, c1, c2, end))
                }
                here = end

            case .addQuadCurveToPoint:
                let c = element.points[0], end = element.points[1]
                let len = distance(here, c) + distance(c, end)
                let n = segmentCount(len)
                for i in 1...n {
                    let t = CGFloat(i) / CGFloat(n)
                    current.append(quadPoint(t, here, c, end))
                }
                here = end

            case .closeSubpath:
                if let first = current.first, first != here { current.append(start) }
                if current.count > 1 { polylines.append(current) }
                current = [start]
                here = start

            @unknown default:
                break
            }
        }

        if current.count > 1 { polylines.append(current) }
        return polylines
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = a.x - b.x, dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

private func cubicPoint(_ t: CGFloat, _ p0: CGPoint, _ p1: CGPoint,
                        _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
    let mt = 1 - t
    let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
    return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                   y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
}

private func quadPoint(_ t: CGFloat, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint) -> CGPoint {
    let mt = 1 - t
    let a = mt * mt, b = 2 * mt * t, c = t * t
    return CGPoint(x: a * p0.x + b * p1.x + c * p2.x,
                   y: a * p0.y + b * p1.y + c * p2.y)
}
