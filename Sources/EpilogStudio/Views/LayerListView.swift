/*
 * LayerListView.swift - One row per colour, and what happens to it
 *
 * This is the control panel of the whole application. Everything else places
 * artwork; this decides what the laser does with it.
 */

import SwiftUI
import EpilogKit

struct LayerListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.project.layers.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.project.layers) { layer in
                            if let binding = model.binding(forLayer: layer.id) {
                                LayerRow(layer: binding,
                                         isSelected: model.selectedLayerID == layer.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectedLayerID = layer.id }
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("").frame(width: 24)
            Text("Layer").frame(width: 130, alignment: .leading)
            Text("Operation").frame(width: 104, alignment: .leading)
            Text("Power").frame(width: 66, alignment: .trailing)
            Text("Speed").frame(width: 66, alignment: .trailing)
            Text("Freq").frame(width: 66, alignment: .trailing)
            Text("Passes").frame(width: 58, alignment: .trailing)
            Text("Style").frame(width: 104, alignment: .leading)
            Spacer(minLength: 8)
            Text("Show").frame(width: 34)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("No artwork yet")
                .font(.callout.weight(.medium))
            Text("Drop a PDF, SVG or image onto the bed, and a layer will appear "
                 + "for every colour in it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct LayerRow: View {
    @Binding var layer: LaserLayer
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Included in the job at all.
            Toggle("", isOn: $layer.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 24)
                .help("Include this layer in the job")

            HStack(spacing: 7) {
                swatch
                TextField("", text: $layer.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .frame(width: 130, alignment: .leading)

            Picker("", selection: $layer.operation) {
                ForEach(LayerOperation.allCases) { op in
                    Label(op.rawValue, systemImage: op.symbolName).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 104)

            NumberCell(value: $layer.power, range: 0...100, suffix: "%")
                .frame(width: 66)
                .help(layer.power == 0
                      ? "Zero power means this layer does nothing"
                      : "Laser power, as a percentage")

            NumberCell(value: $layer.speed, range: 1...100, suffix: "%")
                .frame(width: 66)

            Group {
                if layer.operation.isVector {
                    NumberCell(value: $layer.frequency, range: 1...5000, suffix: "")
                        .help("Pulses per second. Low for wood, high for a polished "
                              + "edge on acrylic.")
                } else {
                    Text("—").foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 66)

            NumberCell(value: $layer.passes, range: 1...20, suffix: "")
                .frame(width: 58)
                .help("Repeat this layer. Two light passes cut cleaner than one heavy one.")

            Group {
                if layer.operation == .engrave {
                    HStack(spacing: 4) {
                        Picker("", selection: $layer.rendering) {
                            ForEach(EngraveRendering.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 74)
                        .help(layer.rendering == .solid
                              ? "Burn this shape at full darkness whatever colour it is"
                              : "Keep the artwork's own tone")
                        DitherMenu(dither: $layer.dither)
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 104, alignment: .leading)

            Spacer(minLength: 8)

            Button {
                layer.visible.toggle()
            } label: {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.visible ? Color.primary : Color.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 34)
            .help("Show this layer in the preview. Does not change the job.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .opacity(layer.enabled ? 1 : 0.45)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var swatch: some View {
        let c = layer.swatch
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color(red: c.r, green: c.g, blue: c.b))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
            .frame(width: 15, height: 15)
    }
}

/// A small right-aligned numeric field that also takes the arrow keys.
private struct NumberCell: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var suffix: String

    var body: some View {
        HStack(spacing: 1) {
            TextField("", value: Binding(
                get: { value },
                set: { value = min(max($0, range.lowerBound), range.upperBound) }
            ), formatter: NumberFormatter())
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
            if !suffix.isEmpty {
                Text(suffix).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Stepper("", value: Binding(
                get: { value },
                set: { value = min(max($0, range.lowerBound), range.upperBound) }
            ), in: range)
                .labelsHidden()
                .controlSize(.mini)
        }
    }
}

private struct DitherMenu: View {
    @Binding var dither: DitherMode

    var body: some View {
        Menu {
            ForEach(DitherMode.allCases) { mode in
                Button {
                    dither = mode
                } label: {
                    HStack {
                        Text(mode.displayName)
                        if mode == dither { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Image(systemName: dither == .none ? "circle.grid.2x2" : "circle.grid.3x3.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help("Dithering: \(dither.displayName). Photographs need it; line art does not.")
    }
}

extension DitherMode {
    var displayName: String {
        switch self {
        case .none:           return "None (line art)"
        case .ordered:        return "Ordered"
        case .floydSteinberg: return "Floyd-Steinberg"
        case .jarvis:         return "Jarvis"
        case .stucki:         return "Stucki"
        }
    }
}
