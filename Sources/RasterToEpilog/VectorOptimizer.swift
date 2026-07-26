/*
 * VectorOptimizer.swift - Order vector paths before cutting
 *
 * Two problems, both of which show up on real jobs:
 *
 *   - Paths come out of the PDF in drawing order, so the head can criss-cross
 *     the bed repeatedly. Pen-up travel is pure wasted time.
 *
 *   - If an outline is cut before the holes inside it, the part drops or shifts
 *     the moment the outline closes, and everything cut afterwards lands in the
 *     wrong place. Interior geometry has to be cut first.
 */

import Foundation

struct VectorOptimizer {

    /// Axis-aligned bounds of a path, in device pixels.
    private struct Bounds {
        var minX = Int.max, minY = Int.max
        var maxX = Int.min, maxY = Int.min

        var isEmpty: Bool { minX > maxX }

        /// True when `other` lies wholly inside this box. Used to decide which
        /// path is the hole and which is the outline.
        func strictlyContains(_ other: Bounds) -> Bool {
            guard !isEmpty && !other.isEmpty else { return false }
            guard minX <= other.minX && maxX >= other.maxX
                    && minY <= other.minY && maxY >= other.maxY else { return false }
            // Reject equality, or two identical paths would each "contain" the
            // other and the nesting order would be arbitrary.
            return (maxX - minX) > (other.maxX - other.minX)
                || (maxY - minY) > (other.maxY - other.minY)
        }
    }

    private struct Info {
        let path: VectorPath
        let bounds: Bounds
        let start: (x: Int, y: Int)
        let end: (x: Int, y: Int)
        // (nesting is now expressed by the parent forest, not a scalar depth)
    }

    /// Reorder paths: each part's interior geometry before its outline, and
    /// nearest-first between parts.
    ///
    /// Deterministic: ties resolve to the earlier path, so re-running a job
    /// produces the same sequence.
    static func optimize(_ paths: [VectorPath]) -> [VectorPath] {
        guard paths.count > 1 else { return paths }

        let infos: [Info] = paths.map { path in
            var b = Bounds()
            var first: (x: Int, y: Int)?
            var last = (x: 0, y: 0)
            for cmd in path.commands {
                switch cmd {
                case .moveTo(let x, let y), .lineTo(let x, let y):
                    b.minX = min(b.minX, x); b.maxX = max(b.maxX, x)
                    b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
                    if first == nil { first = (x, y) }
                    last = (x, y)
                case .setProperty:
                    break
                }
            }
            return Info(path: path, bounds: b,
                        start: first ?? (0, 0), end: last)
        }

        // Build a containment forest: each path's parent is the smallest path
        // that strictly encloses it.
        //
        // Ordering purely by nesting depth - every hole in the job, then every
        // outline - is safe but slow, because it drags the head across the bed
        // once per level. Grouping by family instead keeps each part's holes
        // next to the outline they belong to, which is both safe and short.
        var parent = [Int?](repeating: nil, count: infos.count)
        for i in infos.indices {
            var best: Int?
            for j in infos.indices where i != j {
                guard infos[j].bounds.strictlyContains(infos[i].bounds) else { continue }
                if let b = best {
                    if infos[b].bounds.strictlyContains(infos[j].bounds) { best = j }
                } else {
                    best = j
                }
            }
            parent[i] = best
        }

        var children = [[Int]](repeating: [], count: infos.count)
        var roots: [Int] = []
        for i in infos.indices {
            if let p = parent[i] { children[p].append(i) } else { roots.append(i) }
        }

        var result: [VectorPath] = []
        result.reserveCapacity(paths.count)
        var head = (x: 0, y: 0)

        /// Emit a subtree: everything inside first, then the enclosing path.
        func emit(_ idx: Int) {
            var pending = children[idx]
            while !pending.isEmpty {
                let k = nearest(in: pending, from: head, infos: infos)
                let chosen = pending.remove(at: k)
                emit(chosen)
            }
            result.append(infos[idx].path)
            head = infos[idx].end
        }

        var pendingRoots = roots
        while !pendingRoots.isEmpty {
            let k = nearest(in: pendingRoots, from: head, infos: infos)
            emit(pendingRoots.remove(at: k))
        }

        return result
    }

    /// Index within `candidates` whose path starts closest to `from`.
    private static func nearest(in candidates: [Int], from head: (x: Int, y: Int),
                                infos: [Info]) -> Int {
        var bestK = 0
        var bestDist = Int.max
        for (k, idx) in candidates.enumerated() {
            let dx = infos[idx].start.x - head.x
            let dy = infos[idx].start.y - head.y
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; bestK = k }
        }
        return bestK
    }

    /// Total pen-up distance for a path ordering, for reporting the improvement.
    static func travelDistance(_ paths: [VectorPath]) -> Double {
        var total = 0.0
        var head = (x: 0, y: 0)
        for path in paths {
            var first: (x: Int, y: Int)?
            var last = head
            for cmd in path.commands {
                switch cmd {
                case .moveTo(let x, let y), .lineTo(let x, let y):
                    if first == nil {
                        first = (x, y)
                        let dx = Double(x - head.x), dy = Double(y - head.y)
                        total += (dx * dx + dy * dy).squareRoot()
                    }
                    last = (x, y)
                case .setProperty:
                    break
                }
            }
            head = last
        }
        return total
    }
}
