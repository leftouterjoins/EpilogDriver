/*
 * ToolpathPreviewView.swift - Watch the job before running it
 *
 * The question this answers is "what order does it do things in", which the
 * artwork cannot tell you and which is what scraps parts: cut the outline
 * before the holes inside it and the piece drops, shifts, and everything after
 * that lands somewhere else.
 *
 * Engraving comes first and cutting second, because that is what the machine
 * does - the raster section of a job precedes the vector one. Showing them the
 * other way round would be a prettier animation and a worse answer.
 */

import SwiftUI
import EpilogKit

struct ToolpathPreviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentation

    @State private var preview: JobPreview?
    @State private var progress: Double = 1
    @State private var playing = false

    /// Fraction added per tick while playing. Chosen so a job takes about eight
    /// seconds to watch however long it really is - the point is the order of
    /// operations, not a real-time simulation.
    private let tickRate = 1.0 / (8 * 60)
    private let timer = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            controls
        }
        .frame(width: 780, height: 640)
        .onAppear { preview = JobBuilder.preview(project: model.project) }
        .onReceive(timer) { _ in
            guard playing else { return }
            progress += tickRate
            if progress >= 1 {
                progress = 1
                playing = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Toolpath").font(.headline)
                if let preview {
                    Text(summaryText(preview))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Working it out…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done") { presentation.wrappedValue.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func summaryText(_ preview: JobPreview) -> String {
        var parts: [String] = []
        if !preview.engraveRegions.isEmpty {
            parts.append("\(preview.engraveRegions.count) engraving pass"
                         + (preview.engraveRegions.count == 1 ? "" : "es"))
        }
        if !preview.moves.isEmpty {
            parts.append(String(format: "%.1f\" cutting, %.1f\" travelling",
                                preview.cutLengthInches, preview.travelLengthInches))
        }
        return parts.isEmpty ? "Nothing switched on." : parts.joined(separator: " · ")
    }

    // MARK: - Timeline
    //
    // Engraving takes far longer than cutting in reality, so giving it its true
    // share would leave the cuts flashing past in the last instant. It gets a
    // share big enough to see and small enough to leave room for the cuts.

    private func engraveShare(_ preview: JobPreview) -> Double {
        guard !preview.engraveRegions.isEmpty else { return 0 }
        guard !preview.moves.isEmpty else { return 1 }

        let engraveArea = preview.engraveRegions.reduce(0.0) {
            $0 + Double($1.bounds.width * $1.bounds.height)
        }
        let cutWork = Double(preview.totalLength) * 40   // rough comparable units
        let share = engraveArea / max(engraveArea + cutWork, 1)
        return min(max(share, 0.15), 0.6)
    }

    // MARK: - Canvas

    private var canvas: some View {
        Canvas { context, size in
            guard let preview else { return }

            let bed = preview.bedSizePoints
            let scale = CGFloat(preview.resolution) / 72
            let bedPixels = CGSize(width: bed.width * scale, height: bed.height * scale)
            guard bedPixels.width > 0, bedPixels.height > 0 else { return }

            let fit = min((size.width - 24) / bedPixels.width,
                          (size.height - 24) / bedPixels.height)
            let offset = CGPoint(x: (size.width - bedPixels.width * fit) / 2,
                                 y: (size.height - bedPixels.height * fit) / 2)

            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: offset.x + p.x * fit, y: offset.y + p.y * fit)
            }
            func rect(_ r: CGRect) -> CGRect {
                CGRect(x: offset.x + r.minX * fit, y: offset.y + r.minY * fit,
                       width: r.width * fit, height: r.height * fit)
            }

            // The bed
            let bedRect = CGRect(origin: offset,
                                 size: CGSize(width: bedPixels.width * fit,
                                              height: bedPixels.height * fit))
            context.fill(Path(bedRect), with: .color(Color(nsColor: .textBackgroundColor)))
            context.stroke(Path(bedRect), with: .color(.secondary.opacity(0.5)), lineWidth: 1)

            let share = engraveShare(preview)
            let engraveProgress = share > 0 ? min(progress / share, 1) : 1
            let cutProgress = share < 1 ? max((progress - share) / (1 - share), 0) : 0

            drawEngraving(preview, in: &context, bedRect: bedRect, rect: rect,
                          progress: engraveProgress)
            drawCuts(preview, in: &context, point: point, progress: cutProgress)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// Engraving, revealed a swept band at a time.
    ///
    /// The artwork itself is drawn, not a box around it: the question is which
    /// parts of the material get marked, and an outline of where the head
    /// travels does not answer it. The band moves up the region rather than
    /// down when the job is set to engrave from the bottom, because that is
    /// what the machine will do.
    private func drawEngraving(_ preview: JobPreview, in context: inout GraphicsContext,
                               bedRect: CGRect, rect: (CGRect) -> CGRect,
                               progress: Double) {
        guard !preview.engraveRegions.isEmpty else { return }

        // Regions run one after another, not together.
        let each = 1.0 / Double(preview.engraveRegions.count)
        let bottomUp = preview.engraveBottomUp

        for (index, region) in preview.engraveRegions.enumerated() {
            let box = rect(region.bounds)
            let start = Double(index) * each
            let local = min(max((progress - start) / each, 0), 1)

            // Where the head will go, whether or not it has been there yet.
            context.stroke(Path(box), with: .color(.accentColor.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            guard local > 0 else { continue }

            let sweptHeight = box.height * local
            let swept = bottomUp
                ? CGRect(x: box.minX, y: box.maxY - sweptHeight,
                         width: box.width, height: sweptHeight)
                : CGRect(x: box.minX, y: box.minY, width: box.width, height: sweptHeight)

            context.drawLayer { layer in
                layer.clip(to: Path(swept))
                layer.fill(Path(swept), with: .color(.accentColor.opacity(0.10)))

                if let image = region.image {
                    // The render is black artwork on white and covers the whole
                    // bed; multiplying drops the white and leaves the marks.
                    layer.blendMode = .multiply
                    layer.draw(Image(decorative: image, scale: 1), in: bedRect)
                }
            }

            // The line the head is on.
            if local < 1 {
                let y = bottomUp ? box.maxY - sweptHeight : box.minY + sweptHeight
                var head = Path()
                head.move(to: CGPoint(x: box.minX, y: y))
                head.addLine(to: CGPoint(x: box.maxX, y: y))
                context.stroke(head, with: .color(.orange), lineWidth: 2)
            }
        }
    }

    private func drawCuts(_ preview: JobPreview, in context: inout GraphicsContext,
                          point: (CGPoint) -> CGPoint, progress: Double) {
        guard !preview.moves.isEmpty, progress > 0 else { return }
        let shown = preview.moveCount(upTo: progress)
        guard shown > 0 else { return }

        // Travel first, so cuts draw over it.
        var travel = Path()
        for move in preview.moves[0..<shown] where !move.cutting {
            travel.move(to: point(move.from))
            travel.addLine(to: point(move.to))
        }
        context.stroke(travel, with: .color(.secondary.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 0.75, dash: [2, 3]))

        // Cuts, grouped by colour so each layer is one stroke.
        var byColor: [String: Path] = [:]
        for move in preview.moves[0..<shown] where move.cutting {
            let key = move.color.hex
            byColor[key, default: Path()].move(to: point(move.from))
            byColor[key]!.addLine(to: point(move.to))
        }
        for (hex, path) in byColor {
            let c = ArtworkColor(hex: hex) ?? .black
            context.stroke(path, with: .color(Color(red: c.r, green: c.g, blue: c.b)),
                           lineWidth: 1.6)
        }

        // Where the head is now.
        if progress < 1, let last = preview.moves[safe: shown - 1] {
            let p = point(last.to)
            let dot = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(.orange))
            context.stroke(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)),
                           with: .color(.orange.opacity(0.5)), lineWidth: 1.5)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if progress >= 1 { progress = 0 }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .disabled(preview == nil)

                Slider(value: $progress, in: 0...1) { editing in
                    if editing { playing = false }
                }

                Text(phaseText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 150, alignment: .trailing)
            }

            if let preview, !preview.engraveRegions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(preview.engraveRegions.enumerated()), id: \.offset) { i, region in
                        Text("\(i + 1). Engrave \(region.layerNames.joined(separator: ", "))"
                             + " — \(region.power)% power, \(region.speed)% speed")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(engraveDirectionNote
                 + " Dashed grey is the head moving with the beam off.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private var engraveDirectionNote: String {
        guard let preview, !preview.engraveRegions.isEmpty else {
            return "Engraving runs first and cutting second, the way the machine does it."
        }
        return preview.engraveBottomUp
            ? "Engraving runs first, sweeping upward from the bottom of the artwork, "
              + "then cutting."
            : "Engraving runs first, sweeping down the artwork, then cutting."
    }

    private var phaseText: String {
        guard let preview else { return "—" }
        let share = engraveShare(preview)

        if progress < share, !preview.engraveRegions.isEmpty {
            let which = min(Int(progress / max(share, 0.0001)
                                * Double(preview.engraveRegions.count)) + 1,
                            preview.engraveRegions.count)
            return "engraving \(which)/\(preview.engraveRegions.count)"
        }
        guard !preview.moves.isEmpty else { return "engraving" }
        let cutProgress = share < 1 ? (progress - share) / (1 - share) : 1
        return "cutting \(preview.moveCount(upTo: cutProgress))/\(preview.moves.count)"
    }
}
