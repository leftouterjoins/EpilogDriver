/*
 * ArtworkSplitter.swift - Break a document into the things it is made of
 *
 * A file usually contains several separate objects: three bookmarks in a row,
 * a sheet of tags, a logo and the text beside it. Until they are separate
 * objects here, they can only be moved as one lump - so you cannot spread them
 * out to fit an offcut, or drop the one you do not want.
 *
 * Separateness is decided by distance, not by drawing order or grouping, since
 * neither survives export reliably. Shapes closer together than the gap belong
 * to the same part; anything further apart is its own. That one number is what
 * makes the difference between "each letter is a part" and "the whole page is
 * one part", so it is the caller's to choose.
 */

import Foundation
import CoreGraphics

extension Artwork {

    /// Shapes closer than this are treated as one object. A tenth of an inch
    /// merges the letters of a word without merging things a person would call
    /// separate.
    public static let defaultSplitGap: CGFloat = 7.2

    /// How many parts this would produce, without building any of them.
    ///
    /// Cheap enough to run on every frame of a slider, which is what lets the
    /// gap be chosen by looking at the answer rather than by guessing.
    public func partCount(mergingWithin gap: CGFloat) -> Int {
        clusters(mergingWithin: gap).count
    }

    /// Break this artwork into spatially separate pieces.
    ///
    /// Each piece keeps its own geometry and its own share of the page, and
    /// reports where it sat in the original so the caller can place it exactly
    /// where it already appears.
    ///
    /// Returns an empty array when there is nothing to split - one part is not
    /// a split, it is the thing you started with.
    public func splitIntoParts(mergingWithin gap: CGFloat = Artwork.defaultSplitGap)
        -> [(artwork: Artwork, offset: CGPoint)] {

        let groups = clusters(mergingWithin: gap)
        guard groups.count > 1 else { return [] }

        var parts: [(Artwork, CGPoint)] = []
        parts.reserveCapacity(groups.count)

        for (index, group) in groups.enumerated() {
            var box = CGRect.null
            for i in group { box = box.union(bounds(of: paths[i])) }
            guard !box.isNull, !box.isInfinite, box.width > 0, box.height > 0 else { continue }

            // Move the piece's geometry so its own corner is the origin.
            var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            let movedPaths: [ArtworkPath] = group.compactMap { i in
                var path = paths[i]
                guard let moved = path.path.copy(using: &shift) else { return nil }
                path.path = moved
                return path
            }

            let part = Artwork(
                name: "\(name) \(index + 1)",
                size: box.size,
                paths: movedPaths,
                source: source,
                paintedOperatorCount: movedPaths.count,
                imageCount: 0,
                // The page still draws from the page's corner, so shift it to
                // line up with the piece, and clip it to the piece's own area
                // or every part would carry the whole page's text.
                sourceTransform: shift,
                sourceClip: CGRect(origin: .zero, size: box.size))

            parts.append((part, box.origin))
        }

        return parts.count > 1 ? parts : []
    }

    // MARK: - Clustering

    /// Bounding box of a path, stroke width included.
    private func bounds(of path: ArtworkPath) -> CGRect {
        let box = path.path.boundingBox
        guard !box.isNull, !box.isInfinite else { return .null }
        guard path.stroke != nil else { return box }
        return box.insetBy(dx: -path.strokeWidth / 2, dy: -path.strokeWidth / 2)
    }

    /// Group path indices by proximity.
    ///
    /// Union-find over boxes grown by half the gap each, so two boxes touch
    /// exactly when the shapes are within the gap of each other. Quadratic in
    /// the path count, which is fine: documents that reach thousands of paths
    /// are photographs traced to vector, and those are one object anyway.
    private func clusters(mergingWithin gap: CGFloat) -> [[Int]] {
        let boxes: [CGRect] = paths.map { bounds(of: $0) }
        let valid = boxes.indices.filter { !boxes[$0].isNull && !boxes[$0].isInfinite }
        guard valid.count > 1 else { return valid.isEmpty ? [] : [valid] }

        var parent = Array(paths.indices)

        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            // Path compression, so repeated lookups stay cheap.
            var walk = i
            while parent[walk] != root {
                let next = parent[walk]
                parent[walk] = root
                walk = next
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        let grown = boxes.map { $0.insetBy(dx: -gap / 2, dy: -gap / 2) }
        for (offset, i) in valid.enumerated() {
            for j in valid[(offset + 1)...] where grown[i].intersects(grown[j]) {
                union(i, j)
            }
        }

        // Keep the order the document drew things in, so part 1 is the first
        // thing on the page rather than whichever index the algorithm reached.
        var order: [Int] = []
        var members: [Int: [Int]] = [:]
        for i in valid {
            let root = find(i)
            if members[root] == nil { members[root] = []; order.append(root) }
            members[root]!.append(i)
        }
        return order.compactMap { members[$0] }
    }
}
