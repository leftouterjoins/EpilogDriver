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

        /// What the pass will actually mark, rendered small. Covers the whole
        /// bed, so it can be drawn straight over it without any arithmetic.
        public let image: CGImage?
    }

    public let moves: [Move]
    public let engraveRegions: [EngraveRegion]
    public let resolution: Int
    public let bedSizePoints: CGSize

    /// The head sweeps from the bottom of the artwork upward. Worth showing:
    /// somebody who turned it on did so for a reason, and a preview that
    /// always ran the other way would look like the setting had not taken.
    public let engraveBottomUp: Bool

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

    /// Longest edge of the engraving preview, in pixels.
    ///
    /// A target size rather than a fraction of the job's resolution, which
    /// varies from 100 to 1000 DPI - a fixed fraction would give a useful
    /// picture at one end of that range and a postage stamp or a waste of
    /// memory at the other.
    public static var previewRasterPixels: CGFloat = 1200

    /// Work out what the job will do, without building it.
    ///
    /// The vector side is exactly what the real build produces - the same
    /// function, so the order shown is the order the machine will follow. The
    /// engraving side is composed by the same code too, just rendered small,
    /// which is what makes it show the artwork that will be marked rather than
    /// a box around where the head will travel.
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
        var passLayers: [Key: Set<UUID>] = [:]
        var passBackground: [Key: Bool] = [:]
        var order: [Key] = []

        for layer in project.layers where layer.operation == .engrave && layer.contributes {
            let key = Key(power: layer.power, speed: layer.speed)
            if byKey[key] == nil {
                byKey[key] = (.null, [])
                passLayers[key] = []
                passBackground[key] = false
                order.append(key)
            }
            byKey[key]!.names.append(layer.name)
            passLayers[key]!.insert(layer.id)
            if layer.target == .background { passBackground[key] = true }

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

        let rasterizer = BedRasterizer()
        let longestEdge = CGFloat(max(prepared.widthPx, prepared.heightPx))
        let previewScale = longestEdge > 0
            ? min(1, previewRasterPixels / longestEdge) : 1

        for key in order {
            guard let entry = byKey[key], !entry.box.isNull, !entry.box.isInfinite else { continue }
            let pass = BedRasterizer.Pass(layerIDs: passLayers[key] ?? [],
                                          includesBackground: passBackground[key] ?? false,
                                          power: key.power, speed: key.speed,
                                          dither: .none, passes: 1)
            regions.append(.init(bounds: entry.box, power: key.power,
                                 speed: key.speed, layerNames: entry.names,
                                 image: rasterizer.previewImage(prepared, pass: pass,
                                                                scale: previewScale)))
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
                          engraveBottomUp: project.engraveBottomUp,
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
