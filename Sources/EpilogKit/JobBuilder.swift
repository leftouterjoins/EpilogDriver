/*
 * JobBuilder.swift - Assemble a project into the bytes the laser reads
 *
 * The wire format is not negotiable and was expensive to get right: a PJL
 * header, a PCL raster section, an HPGL vector section, a PJL footer, and 4096
 * NUL bytes so LPD knows the job ended. Every one of those pieces is generated
 * by the same code the CUPS filter uses, in the same order, because that exact
 * sequence is the one observed cutting on a real machine. What changes here is
 * only what goes into them.
 */

import Foundation
import CoreGraphics

/// What a build produced, and what the operator should know about it.
public struct JobSummary {
    /// Separate engraving sections, one per distinct power/speed/dither.
    public var engravePassCount = 0
    /// Rows of raster actually sent.
    public var engraveRows = 0
    public var vectorPathCount = 0

    /// Distance the laser travels while firing, in inches.
    public var cutLengthInches: Double = 0
    /// Distance travelled between cuts with the beam off, in inches.
    public var travelInches: Double = 0

    /// Rough run time. An estimate: acceleration, overscan and the machine's
    /// own overheads are not modelled, so treat it as an order of magnitude.
    public var estimatedSeconds: Double = 0

    /// Extent of everything in the job, in inches from the bed's top-left.
    public var bounds: CGRect = .zero

    public var warnings: [String] = []
    public var byteCount = 0

    public var isEmpty: Bool { engraveRows == 0 && vectorPathCount == 0 }

    /// "4 min 12 s", for display.
    public var estimatedDuration: String {
        let total = Int(estimatedSeconds.rounded())
        if total < 60 { return "\(total) s" }
        let m = total / 60, s = total % 60
        if m < 60 { return s == 0 ? "\(m) min" : "\(m) min \(s) s" }
        return "\(m / 60) h \(m % 60) min"
    }
}

public struct LaserJob {
    public let data: Data
    public let summary: JobSummary
    public let name: String
}

public enum JobBuilder {

    // Approximate top speeds, used only for the time estimate. The protocol
    // carries speed as a percentage and never says of what; these are the
    // figures a Zing roughly manages, and they exist so the estimate lands in
    // the right ballpark rather than to be authoritative.
    public static var maxRasterInchesPerSecond: Double = 30
    public static var maxVectorInchesPerSecond: Double = 20

    /// Build the real job.
    public static func build(project: LaserProject,
                             shouldCancel: () -> Bool = { false }) -> LaserJob? {
        var summary = JobSummary()
        let prepared = PreparedProject(project: project)

        guard prepared.widthPx > 0, prepared.heightPx > 0 else {
            EpilogLog.error("The machine has no usable bed size")
            return nil
        }

        // ---- Vectors ------------------------------------------------------
        //
        // Layers run in the order they are listed, because that order is a
        // decision somebody made: score lines before the cut that frees the
        // part, a light pass before a heavy one. Sorting happens inside each
        // layer, never across them, so optimising travel cannot quietly
        // reorder the passes.
        var vectorPaths: [VectorPath] = []
        var travelPx: Double = 0
        var head = (x: 0, y: 0)

        for layer in project.layers where layer.operation.isVector && layer.contributes {
            var paths = buildVectorPaths(prepared: prepared, layer: layer,
                                         focus: project.focusOffset, summary: &summary)
            guard !paths.isEmpty else { continue }

            if project.vectorSorting && paths.count > 1 {
                let before = VectorOptimizer.travelDistance(paths)
                paths = VectorOptimizer.optimize(paths)
                let after = VectorOptimizer.travelDistance(paths)
                let dpi = Double(project.resolution)
                EpilogLog.debug(String(format:
                    "%@: pen-up travel %.1f\" -> %.1f\" over %d paths",
                    layer.name, before / dpi, after / dpi, paths.count))
            }

            travelPx += VectorOptimizer.travelDistance(paths, from: head)
            head = endPoint(of: paths) ?? head
            vectorPaths.append(contentsOf: paths)
        }

        summary.travelInches = travelPx / Double(project.resolution)
        summary.vectorPathCount = vectorPaths.count

        // ---- Engraving ----------------------------------------------------
        let passes = engravePasses(project: project)
        let rasterizer = BedRasterizer()
        var rasterSections: [(Data, BedRasterizer.Pass, BedRasterizer.Bitmap)] = []

        for pass in passes {
            if shouldCancel() { return nil }
            guard let bitmap = rasterizer.render(prepared, pass: pass,
                                                 mode: project.rasterMode,
                                                 shouldCancel: shouldCancel) else {
                if shouldCancel() { return nil }
                continue
            }
            guard bitmap.hasInk else { continue }

            var options = JobOptions()
            options.resolution = project.resolution
            options.rasterPower = pass.power
            options.rasterSpeed = pass.speed
            options.focus = project.focusOffset
            options.engraveBottomUp = project.engraveBottomUp

            // Declare only the content's extent, so the head does not sweep the
            // whole bed on every scanline.
            let maxX = bitmap.inkMaxX + 1
            let maxY = bitmap.inkMaxY + 1
            let rows = bitmap.inkMinY..<maxY

            let encoded: Data
            if project.rasterMode == .greyscale3D {
                encoded = RasterEncoder.encodePageGreyscale(
                    pageData: bitmap.data, width: bitmap.width, height: bitmap.height,
                    bytesPerLine: bitmap.bytesPerLine, options: options,
                    maxX: maxX, maxY: maxY, rowRange: rows)
            } else {
                encoded = RasterEncoder.encodePage(
                    pageData: bitmap.data, width: bitmap.width, height: bitmap.height,
                    bytesPerLine: bitmap.bytesPerLine, options: options,
                    maxX: maxX, maxY: maxY, rowRange: rows)
            }

            for _ in 0..<max(1, pass.passes) {
                rasterSections.append((encoded, pass, bitmap))
            }
            summary.engraveRows += rows.count * max(1, pass.passes)
        }
        summary.engravePassCount = rasterSections.count

        if rasterSections.count > 1 {
            EpilogLog.info("This job has \(rasterSections.count) engraving passes because "
                           + "its engraving layers use different settings. Most jobs have "
                           + "one; if the machine only runs the first, give the engraving "
                           + "layers matching power and speed.")
        }

        // ---- Bounds and warnings -----------------------------------------
        summary.bounds = boundsInInches(prepared: prepared,
                                        vectorPaths: vectorPaths,
                                        rasterSections: rasterSections.map { $0.2 })
        summary.warnings = warnings(project: project, prepared: prepared,
                                    vectorPaths: vectorPaths,
                                    rasterSections: rasterSections.count)
        summary.estimatedSeconds = estimate(rasterSections: rasterSections,
                                            vectorPaths: vectorPaths,
                                            summary: summary,
                                            resolution: project.resolution)

        // ---- Assembly ------------------------------------------------------
        var data = Data()
        data.append(PJLGenerator.generateHeader(title: project.jobName,
                                                resolution: project.resolution,
                                                autofocus: project.autofocus,
                                                copies: 1))

        if rasterSections.isEmpty {
            // An Epilog expects a raster section even when there is nothing to
            // engrave; a vector-only job without one does not run.
            data.append(RasterEncoder.generateDummyRaster(resolution: project.resolution,
                                                          power: 0, speed: 100,
                                                          focus: project.focusOffset))
        } else {
            for (section, _, _) in rasterSections { data.append(section) }
        }

        if vectorPaths.isEmpty {
            data.append(VectorEncoder.generateDummyVector())
        } else {
            data.append(VectorEncoder.generateVectorHPGL(paths: vectorPaths))
        }

        data.append(PJLGenerator.generateFooter())

        summary.byteCount = data.count
        EpilogLog.info("Built \(project.jobName): \(summary.engravePassCount) engraving "
                       + "pass(es), \(summary.vectorPathCount) cut path(s), "
                       + "\(data.count) bytes")

        return LaserJob(data: data, summary: summary, name: project.jobName)
    }

    /// Build a positioning pass: trace where the real job would land, so the
    /// operator can place material against it.
    ///
    /// Power is zero by default, which matters more than it looks. With the
    /// beam off the lid interlock still allows the head to move, so the lid can
    /// stay open and the outline can be watched against the material - which is
    /// the entire point, and how Epilog's own driver behaves.
    public static func buildTestFrame(project: LaserProject,
                                      mode: JobOptions.TestFrameMode = .trace) -> LaserJob? {
        guard mode != .off else { return build(project: project) }

        var summary = JobSummary()
        let prepared = PreparedProject(project: project)

        var scratch = JobSummary()
        let vectorPaths = project.layers
            .filter { $0.operation.isVector && $0.contributes }
            .flatMap { buildVectorPaths(prepared: prepared, layer: $0,
                                        focus: 0, summary: &scratch) }

        // Union of everything: cuts and engraving alike.
        var box = CGRect.null
        for path in vectorPaths {
            for cmd in path.commands {
                if case .moveTo(let x, let y) = cmd {
                    box = box.union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 0, height: 0))
                }
                if case .lineTo(let x, let y) = cmd {
                    box = box.union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 0, height: 0))
                }
            }
        }
        for item in prepared.items {
            let s = item.documentSize
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: s.width, y: 0),
                           CGPoint(x: s.width, y: s.height), CGPoint(x: 0, y: s.height)]
                .map { $0.applying(item.sourceTransform) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            box = box.union(CGRect(x: xs.min()!, y: ys.min()!,
                                   width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
        }

        guard !box.isNull, box.width > 0 || box.height > 0 else {
            EpilogLog.warning("There is nothing on the bed to trace.")
            return nil
        }

        let minX = max(0, Int(box.minX)), minY = max(0, Int(box.minY))
        let maxX = min(prepared.widthPx - 1, Int(box.maxX))
        let maxY = min(prepared.heightPx - 1, Int(box.maxY))

        let (power, speed) = mode.vectorSettings
        let dpi = Double(project.resolution)

        var frame = VectorPath()
        frame.setProperty(colorIndex: 0, power: power, speed: speed,
                          frequency: 500, focus: 0)
        frame.moveTo(x: minX, y: minY)
        frame.lineTo(x: maxX, y: minY)
        frame.lineTo(x: maxX, y: maxY)
        frame.lineTo(x: minX, y: maxY)
        frame.lineTo(x: minX, y: minY)

        var data = Data()
        // Autofocus off: the head is only being positioned, and focusing
        // against material that is not yet where it belongs is pointless.
        data.append(PJLGenerator.generateHeader(title: "\(project.jobName) [frame]",
                                                resolution: project.resolution,
                                                autofocus: false, copies: 1))
        data.append(RasterEncoder.generateDummyRaster(resolution: project.resolution))
        data.append(VectorEncoder.generateVectorHPGL(paths: [frame]))
        data.append(PJLGenerator.generateFooter())

        summary.vectorPathCount = 1
        summary.bounds = CGRect(x: Double(minX) / dpi, y: Double(minY) / dpi,
                                width: Double(maxX - minX) / dpi,
                                height: Double(maxY - minY) / dpi)
        let perimeter = 2 * (summary.bounds.width + summary.bounds.height)
        summary.travelInches = perimeter
        summary.estimatedSeconds = perimeter
            / max(1, maxVectorInchesPerSecond * Double(speed) / 100)
        summary.byteCount = data.count

        EpilogLog.info(String(format:
            "Frame: %.2f\" x %.2f\" at (%.2f\", %.2f\"), power %d%%, speed %d%%",
            summary.bounds.width, summary.bounds.height,
            summary.bounds.minX, summary.bounds.minY, power, speed))

        return LaserJob(data: data, summary: summary, name: "\(project.jobName) [frame]")
    }

    // MARK: - Vectors

    private static func buildVectorPaths(prepared: PreparedProject, layer: LaserLayer,
                                         focus: Int,
                                         summary: inout JobSummary) -> [VectorPath] {
        var result: [VectorPath] = []
        var cutLengthPx: Double = 0

        let maxX = prepared.widthPx - 1
        let maxY = prepared.heightPx - 1
        var clamped = false

        for (path, layer) in prepared.paths(matching: { $0.id == layer.id }) {
            let polylines = path.path.flattenedPolylines()
            guard !polylines.isEmpty else { continue }

            for polyline in polylines where polyline.count > 1 {
                var vp = VectorPath()
                vp.strokeColor = layer.swatch.asTuple
                vp.setProperty(colorIndex: layer.target.color.flatMap(penIndex) ?? 0,
                               power: layer.power, speed: layer.speed,
                               frequency: layer.frequency, focus: focus)

                var previous: CGPoint?
                for (i, point) in polyline.enumerated() {
                    var x = Int(point.x.rounded()), y = Int(point.y.rounded())
                    if x < 0 || y < 0 || x > maxX || y > maxY { clamped = true }
                    x = min(max(0, x), maxX)
                    y = min(max(0, y), maxY)

                    if i == 0 {
                        vp.moveTo(x: x, y: y)
                    } else {
                        vp.lineTo(x: x, y: y)
                        if let p = previous {
                            let dx = Double(x) - Double(p.x), dy = Double(y) - Double(p.y)
                            cutLengthPx += (dx * dx + dy * dy).squareRoot()
                        }
                    }
                    previous = CGPoint(x: CGFloat(x), y: CGFloat(y))
                }

                // Repeat the whole outline before moving on, so multi-pass cuts
                // do not travel back and forth across the bed between passes.
                for _ in 0..<max(1, layer.passes) { result.append(vp) }
                cutLengthPx *= 1
            }
        }

        if clamped {
            summary.warnings.append("Some cut lines run off the bed and were clipped to its "
                                    + "edge. Move or scale the artwork so it fits.")
        }

        summary.cutLengthInches += cutLengthPx / Double(prepared.resolution)
        return result
    }

    /// Where the head is left after a run of paths.
    private static func endPoint(of paths: [VectorPath]) -> (x: Int, y: Int)? {
        for path in paths.reversed() {
            for command in path.commands.reversed() {
                switch command {
                case .lineTo(let x, let y), .moveTo(let x, let y):
                    return (x, y)
                case .setProperty:
                    continue
                }
            }
        }
        return nil
    }

    private static func penIndex(_ color: ArtworkColor) -> Int? {
        let (r, g, b) = color.bytes
        return CutColor(r: r, g: g, b: b)?.penIndex
    }

    // MARK: - Engraving passes

    /// Group engraving layers by the settings that have to be identical inside
    /// one raster section: power, speed, dithering and pass count.
    private static func engravePasses(project: LaserProject) -> [BedRasterizer.Pass] {
        struct Key: Hashable {
            let power: Int, speed: Int, dither: DitherMode, passes: Int
        }

        var order: [Key] = []
        var grouped: [Key: (ids: Set<UUID>, background: Bool)] = [:]

        for layer in project.layers
        where layer.operation == .engrave && layer.contributes {
            let key = Key(power: layer.power, speed: layer.speed,
                          dither: layer.dither, passes: max(1, layer.passes))
            if grouped[key] == nil {
                grouped[key] = (ids: [], background: false)
                order.append(key)
            }
            grouped[key]!.ids.insert(layer.id)
            if layer.target == .background { grouped[key]!.background = true }
        }

        return order.map { key in
            let g = grouped[key]!
            return BedRasterizer.Pass(layerIDs: g.ids, includesBackground: g.background,
                                      power: key.power, speed: key.speed,
                                      dither: key.dither, passes: key.passes)
        }
    }

    // MARK: - Reporting

    private static func boundsInInches(prepared: PreparedProject,
                                       vectorPaths: [VectorPath],
                                       rasterSections: [BedRasterizer.Bitmap]) -> CGRect {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min

        for bitmap in rasterSections where bitmap.hasInk {
            minX = min(minX, bitmap.inkMinX); maxX = max(maxX, bitmap.inkMaxX)
            minY = min(minY, bitmap.inkMinY); maxY = max(maxY, bitmap.inkMaxY)
        }
        for path in vectorPaths {
            for cmd in path.commands {
                switch cmd {
                case .moveTo(let x, let y), .lineTo(let x, let y):
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                case .setProperty:
                    break
                }
            }
        }

        guard minX <= maxX, minY <= maxY else { return .zero }
        let dpi = Double(prepared.resolution)
        return CGRect(x: Double(minX) / dpi, y: Double(minY) / dpi,
                      width: Double(maxX - minX) / dpi,
                      height: Double(maxY - minY) / dpi)
    }

    private static func warnings(project: LaserProject, prepared: PreparedProject,
                                 vectorPaths: [VectorPath],
                                 rasterSections: Int) -> [String] {
        var warnings: [String] = []

        if project.items.isEmpty {
            warnings.append("Nothing has been added to the bed yet.")
            return warnings
        }

        if vectorPaths.isEmpty && rasterSections == 0 {
            warnings.append("Every layer is switched off, set to Skip, or set to zero power, "
                            + "so this job would do nothing.")
        }

        // The failure this whole project exists because of: a document that
        // reached us as one flat image has no outlines to cut, and no amount
        // of layer configuration will conjure them.
        let wantsCuts = project.layers.contains { $0.operation.isVector && $0.contributes }
        if wantsCuts && vectorPaths.isEmpty {
            let flattened = project.items.filter { $0.artwork.paths.isEmpty
                                                   && $0.artwork.imageCount > 0 }
            if !flattened.isEmpty {
                let names = flattened.map(\.artwork.name).joined(separator: ", ")
                warnings.append("\(names) contains no outlines - it is a flat image, so there "
                                + "is nothing to cut. Export it from the original application "
                                + "as PDF or SVG to keep its shapes.")
            } else {
                warnings.append("Cut layers are switched on but no cut outlines were found.")
            }
        }

        if project.hasContentOffBed {
            warnings.append("Some artwork is outside the \(shortSize(project.bedSize)) bed.")
        } else if project.hasContentOffMaterial {
            warnings.append("Some artwork is outside the \(shortSize(project.pieceSize)) "
                            + "material you declared.")
        }

        if project.autofocus && project.focusOffset != 0 {
            warnings.append("Autofocus is on and a manual focus offset is set; the machine "
                            + "will use the measured height.")
        }

        return warnings
    }

    private static func shortSize(_ size: CGSize) -> String {
        String(format: "%.4g\" x %.4g\"", size.width / 72, size.height / 72)
    }

    private static func estimate(rasterSections: [(Data, BedRasterizer.Pass,
                                                   BedRasterizer.Bitmap)],
                                 vectorPaths: [VectorPath],
                                 summary: JobSummary,
                                 resolution: Int) -> Double {
        var seconds = 0.0

        for (_, pass, bitmap) in rasterSections where bitmap.hasInk {
            let rows = Double(bitmap.inkMaxY - bitmap.inkMinY + 1)
            let widthInches = Double(bitmap.inkMaxX - bitmap.inkMinX + 1) / Double(resolution)
            let ips = max(1, maxRasterInchesPerSecond * Double(pass.speed) / 100)
            // Each scanline crosses the content once; the head also has to turn
            // around at each end, which is where a surprising amount of the time
            // on a tall narrow engraving actually goes.
            seconds += rows * (widthInches / ips + 0.02)
        }

        // Vector time: firing distance at each path's own speed, plus travel.
        var cutSeconds = 0.0
        var speed = 100
        for path in vectorPaths {
            var previous: CGPoint?
            for cmd in path.commands {
                switch cmd {
                case .setProperty(_, _, let s, _, _):
                    speed = max(1, s)
                case .moveTo(let x, let y):
                    previous = CGPoint(x: CGFloat(x), y: CGFloat(y))
                case .lineTo(let x, let y):
                    let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
                    if let q = previous {
                        let d = ((p.x - q.x) * (p.x - q.x)
                                 + (p.y - q.y) * (p.y - q.y)).squareRoot()
                        let ips = max(1, maxVectorInchesPerSecond * Double(speed) / 100)
                        cutSeconds += Double(d) / Double(resolution) / ips
                    }
                    previous = p
                }
            }
        }
        seconds += cutSeconds
        seconds += summary.travelInches / maxVectorInchesPerSecond

        return seconds
    }
}

private extension ArtworkColor {
    var asTuple: (r: CGFloat, g: CGFloat, b: CGFloat) {
        (CGFloat(r), CGFloat(g), CGFloat(b))
    }
}
