/*
 * JobPreview.swift - The job as a sequence of movements
 *
 * A finished job is a few hundred kilobytes of PCL and HPGL, which tells you
 * nothing about whether it will work. What an operator actually wants to see is
 * the order: does the small hole get cut before the outline that frees the part
 * it is in, or after, when the part has already dropped and moved? That is the
 * mistake that scraps work, and it is invisible in the artwork.
 *
 * So the same code that builds the job also produces this: every movement in
 * order, marked as cutting or travelling.
 */

import Foundation
import CoreGraphics

public struct JobPreview {

    /// One straight movement of the head.
    public struct Move {
        public let from: CGPoint
        public let to: CGPoint
        /// False when the beam is off and the head is only repositioning.
        public let cutting: Bool
        /// The layer this belongs to, for colouring and for the legend.
        public let layerID: UUID?
        public let color: ArtworkColor

        public var length: CGFloat {
            hypot(to.x - from.x, to.y - from.y)
        }
    }

    /// Where each engraving pass will sweep, in device pixels.
    public struct EngraveRegion {
        public let bounds: CGRect
        public let power: Int
        public let speed: Int
        public let layerNames: [String]
    }

    public let moves: [Move]
    public let engraveRegions: [EngraveRegion]
    public let resolution: Int
    public let bedSizePoints: CGSize

    /// Cumulative distance after each move, for scrubbing through the job at a
    /// constant speed rather than a constant number of segments - otherwise a
    /// curve flattened into two hundred tiny segments takes as long to scrub
    /// through as a two-foot straight line.
    public let cumulativeLength: [CGFloat]

    public var totalLength: CGFloat { cumulativeLength.last ?? 0 }

    public var cutLengthInches: Double {
        Double(moves.filter(\.cutting).reduce(0) { $0 + $1.length }) / Double(resolution)
    }

    public var travelLengthInches: Double {
        Double(moves.filter { !$0.cutting }.reduce(0) { $0 + $1.length }) / Double(resolution)
    }

    /// How many moves fall within `fraction` of the way through.
    public func moveCount(upTo fraction: Double) -> Int {
        guard totalLength > 0 else { return moves.count }
        let target = CGFloat(min(max(fraction, 0), 1)) * totalLength
        // Binary search: this is called on every frame of a scrub.
        var low = 0, high = cumulativeLength.count
        while low < high {
            let mid = (low + high) / 2
            if cumulativeLength[mid] < target { low = mid + 1 } else { high = mid }
        }
        return min(low + 1, moves.count)
    }
}

extension JobBuilder {

    /// Work out what the head will do, without building the job.
    ///
    /// Cheap on purpose: the vector side is exactly what the real build
    /// produces, and the engraving side is reported as the region each pass
    /// will sweep rather than as pixels. Rendering the raster to show a preview
    /// would cost as much as the job itself, for a picture of the artwork the
    /// canvas is already showing.
    public static func preview(project: LaserProject) -> JobPreview {
        let prepared = PreparedProject(project: project)
        var moves: [JobPreview.Move] = []
        var head = CGPoint.zero

        for layer in project.layers where layer.operation.isVector && layer.contributes {
            var scratch = JobSummary()
            var paths = buildVectorPaths(prepared: prepared, layer: layer,
                                         focus: project.focusOffset, summary: &scratch)
            if project.vectorSorting && paths.count > 1 {
                paths = VectorOptimizer.optimize(paths)
            }

            for path in paths {
                var pen = head
                for command in path.commands {
                    switch command {
                    case .setProperty:
                        continue
                    case .moveTo(let x, let y):
                        let to = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        moves.append(.init(from: pen, to: to, cutting: false,
                                           layerID: layer.id, color: layer.swatch))
                        pen = to
                    case .lineTo(let x, let y):
                        let to = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        moves.append(.init(from: pen, to: to, cutting: true,
                                           layerID: layer.id, color: layer.swatch))
                        pen = to
                    }
                }
                head = pen
            }
        }

        // Engraving: the extent each pass will sweep.
        var regions: [JobPreview.EngraveRegion] = []
        struct Key: Hashable { let power: Int, speed: Int }
        var byKey: [Key: (box: CGRect, names: [String])] = [:]
        var order: [Key] = []

        for layer in project.layers where layer.operation == .engrave && layer.contributes {
            let key = Key(power: layer.power, speed: layer.speed)
            if byKey[key] == nil { byKey[key] = (.null, []); order.append(key) }
            byKey[key]!.names.append(layer.name)

            var box = byKey[key]!.box
            if layer.target == .background {
                for item in prepared.items where !item.source.isEmpty {
                    box = box.union(bounds(of: item))
                }
            }
            for item in prepared.items {
                for path in item.paths where path.layerID == layer.id {
                    let b = path.path.boundingBox
                        .insetBy(dx: -path.strokeWidthPx, dy: -path.strokeWidthPx)
                    if !b.isNull && !b.isInfinite { box = box.union(b) }
                }
            }
            byKey[key]!.box = box
        }

        for key in order {
            guard let entry = byKey[key], !entry.box.isNull, !entry.box.isInfinite else { continue }
            regions.append(.init(bounds: entry.box, power: key.power,
                                 speed: key.speed, layerNames: entry.names))
        }

        var cumulative: [CGFloat] = []
        cumulative.reserveCapacity(moves.count)
        var running: CGFloat = 0
        for move in moves {
            running += move.length
            cumulative.append(running)
        }

        return JobPreview(moves: moves, engraveRegions: regions,
                          resolution: project.resolution,
                          bedSizePoints: project.bedSize,
                          cumulativeLength: cumulative)
    }

    private static func bounds(of item: PreparedProject.Item) -> CGRect {
        let s = item.documentSize
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: s.width, y: 0),
                       CGPoint(x: s.width, y: s.height), CGPoint(x: 0, y: s.height)]
            .map { $0.applying(item.sourceTransform) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
