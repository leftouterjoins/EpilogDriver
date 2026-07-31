/*
 * ToolpathPreviewView.swift - Watch the job before running it
 *
 * The question this answers is "what order does it do things in", which the
 * artwork cannot tell you and which is what scraps parts: cut the outline
 * before the holes inside it and the piece drops, shifts, and everything after
 * that lands somewhere else.
 */

import SwiftUI
import EpilogKit

struct ToolpathPreviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentation

    @State private var preview: JobPreview?
    @State private var progress: Double = 1
    @State private var playing = false

    /// Fraction of the job added per tick while playing. Chosen so a job takes
    /// about eight seconds to watch however long it really is - the point is
    /// the order of operations, not a real-time simulation.
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
        .frame(width: 760, height: 620)
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
                    Text(String(format: "%.1f\" cutting, %.1f\" travelling, %d moves",
                                preview.cutLengthInches, preview.travelLengthInches,
                                preview.moves.count))
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

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geometry in
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

                // The bed
                let bedRect = CGRect(origin: offset,
                                     size: CGSize(width: bedPixels.width * fit,
                                                  height: bedPixels.height * fit))
                context.fill(Path(bedRect), with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(Path(bedRect), with: .color(.secondary.opacity(0.5)),
                               lineWidth: 1)

                // Engraving sweeps, behind the cuts
                for region in preview.engraveRegions {
                    let r = CGRect(x: offset.x + region.bounds.minX * fit,
                                   y: offset.y + region.bounds.minY * fit,
                                   width: region.bounds.width * fit,
                                   height: region.bounds.height * fit)
                    context.fill(Path(r), with: .color(.accentColor.opacity(0.10)))
                    context.stroke(Path(r), with: .color(.accentColor.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }

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
            .padding(12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if progress >= 1 { progress = 0 }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .disabled(preview == nil)

                Slider(value: $progress, in: 0...1) { editing in
                    if editing { playing = false }
                }

                Text(positionText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 116, alignment: .trailing)
            }

            if let preview, !preview.engraveRegions.isEmpty {
                HStack(spacing: 14) {
                    ForEach(Array(preview.engraveRegions.enumerated()), id: \.offset) { _, region in
                        Label(region.layerNames.joined(separator: ", ")
                              + " · \(region.power)% / \(region.speed)%",
                              systemImage: "square.grid.3x3.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Text("Dashed grey is the head moving with the beam off. Cuts appear in "
                 + "their layer colour, in the order the machine will make them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private var positionText: String {
        guard let preview, !preview.moves.isEmpty else { return "—" }
        let shown = preview.moveCount(upTo: progress)
        return "\(shown) / \(preview.moves.count)"
    }
}
