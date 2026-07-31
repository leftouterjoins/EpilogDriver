/*
 * InspectorView.swift - Everything about the job that is not a layer
 */

import SwiftUI
import CoreGraphics
import EpilogKit

struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    @State private var showJob = true
    @State private var showPlacement = true
    @State private var showMachine = true
    @State private var showMaterial = false
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard

                InspectorSection(title: "Job", isExpanded: $showJob) { jobSection }
                InspectorSection(title: "Placement", isExpanded: $showPlacement) { placementSection }
                InspectorSection(title: "Machine", isExpanded: $showMachine) { machineSection }
                InspectorSection(title: "Material", isExpanded: $showMaterial) { materialSection }
                InspectorSection(title: "Advanced", isExpanded: $showAdvanced) { advancedSection }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Estimate").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.refreshSummary()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Work out how long this job will take")
            }

            if case .building(let what) = model.activity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(what + "…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let summary = model.lastSummary {
                VStack(alignment: .leading, spacing: 3) {
                    SummaryRow("Time", summary.estimatedDuration)
                    SummaryRow("Cutting", String(format: "%.1f\"", summary.cutLengthInches))
                    SummaryRow("Size", String(format: "%.2f\" x %.2f\"",
                                              summary.bounds.width, summary.bounds.height))
                    SummaryRow("Passes", "\(summary.engravePassCount) engrave, "
                                       + "\(summary.vectorPathCount) cut")
                }
                .font(.caption)

                ForEach(summary.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Not calculated yet.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Job

    @ViewBuilder
    private var jobSection: some View {
        Field("Name") {
            TextField("", text: $model.project.jobName)
                .textFieldStyle(.roundedBorder)
        }
        Field("Resolution") {
            Picker("", selection: $model.project.resolution) {
                ForEach(model.project.machine.resolutions, id: \.self) { dpi in
                    Text("\(dpi) DPI").tag(dpi)
                }
            }
            .labelsHidden()
        }
        Text(resolutionAdvice)
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var resolutionAdvice: String {
        switch model.project.resolution {
        case ...200:  return "Fast and coarse. Fine for large solid areas."
        case 201...400: return "A good compromise for most work."
        case 401...600: return "The usual working resolution. Photographs look right here."
        default: return "Very fine and correspondingly slow. Worth it for small detailed "
                      + "engraving, wasted on anything larger."
        }
    }

    // MARK: - Placement

    @ViewBuilder
    private var placementSection: some View {
        if model.selection.isEmpty {
            Text(model.project.items.isEmpty
                 ? "Nothing on the bed yet."
                 : "Select something on the bed to position it.")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.selection.count > 1 {
            Text("\(model.selection.count) items selected.")
                .font(.caption).foregroundStyle(.secondary)
            placementButtons
        } else if let item = model.selectedItems.first,
                  let index = model.project.items.firstIndex(where: { $0.id == item.id }) {
            singleItemPlacement(index: index, item: item)
        }
    }

    @ViewBuilder
    private func singleItemPlacement(index: Int, item: PlacedArtwork) -> some View {
        Text(item.artwork.name).font(.callout.weight(.medium)).lineLimit(1)

        let bounds = item.inkBoundsOnBed
        Text(String(format: "Artwork %.2f\" x %.2f\"", bounds.width / 72, bounds.height / 72))
            .font(.caption2).foregroundStyle(.secondary)

        HStack(spacing: 8) {
            InchField(label: "X", points: Binding(
                get: { model.project.items[safe: index]?.origin.x ?? 0 },
                set: { model.project.items[index].origin.x = $0 }))
            InchField(label: "Y", points: Binding(
                get: { model.project.items[safe: index]?.origin.y ?? 0 },
                set: { model.project.items[index].origin.y = $0 }))
        }

        HStack(spacing: 8) {
            InchField(label: "W", points: Binding(
                get: { model.project.items[safe: index]?.placedSize.width ?? 0 },
                set: { newValue in
                    let natural = model.project.items[index].artwork.size.width
                    guard natural > 0, newValue > 0 else { return }
                    model.project.items[index].scale = newValue / natural
                }))
            InchField(label: "H", points: Binding(
                get: { model.project.items[safe: index]?.placedSize.height ?? 0 },
                set: { newValue in
                    let natural = model.project.items[index].artwork.size.height
                    guard natural > 0, newValue > 0 else { return }
                    model.project.items[index].scale = newValue / natural
                }))
        }
        Text("Width and height stay in proportion.")
            .font(.caption2).foregroundStyle(.tertiary)

        Field("Rotation") {
            HStack(spacing: 4) {
                TextField("", value: Binding(
                    get: { (model.project.items[safe: index]?.rotation ?? 0) * 180 / .pi },
                    set: { model.project.items[index].rotation = CGFloat($0) * .pi / 180 }
                ), formatter: decimalFormatter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 62)
                Text("°").foregroundStyle(.secondary)
                Button { model.rotateSelection(by: -.pi / 2) } label: {
                    Image(systemName: "rotate.left")
                }.buttonStyle(.borderless)
                Button { model.rotateSelection(by: .pi / 2) } label: {
                    Image(systemName: "rotate.right")
                }.buttonStyle(.borderless)
            }
        }

        if let url = item.sourceURL, url.pathExtension.lowercased() == "pdf",
           ArtworkImporter.pageCount(of: url) > 1 {
            let pages = ArtworkImporter.pageCount(of: url)
            Field("Page") {
                Picker("", selection: Binding(
                    get: { model.project.items[safe: index]?.pageIndex ?? 1 },
                    set: { model.setPage($0, forItem: item.id) }
                )) {
                    ForEach(1...pages, id: \.self) { Text("\($0) of \(pages)").tag($0) }
                }
                .labelsHidden()
            }
        }

        placementButtons
    }

    private var placementButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button("Centre") { model.centerSelection() }
                Button("Top left") { model.moveSelectionToOrigin() }
                Button("Fit bed") { model.fitSelectionToBed() }
            }
            HStack(spacing: 6) {
                Button("Duplicate") { model.duplicateSelected() }
                Button(role: .destructive) { model.removeSelected() } label: { Text("Remove") }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Machine

    @ViewBuilder
    private var machineSection: some View {
        Field("Model") {
            Picker("", selection: Binding(
                get: { model.project.machine.id },
                set: { id in
                    if let preset = LaserMachine.presets.first(where: { $0.id == id }) {
                        var machine = preset
                        // Keep the address: it belongs to the workshop, not to
                        // whichever model happens to be selected.
                        machine.host = model.project.machine.host
                        machine.port = model.project.machine.port
                        model.project.machine = machine
                        model.preferences.machine = machine
                    }
                }
            )) {
                ForEach(LaserMachine.presets) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
        }

        Text(String(format: "Bed %.4g\" x %.4g\", %dW",
                    model.project.machine.bedWidthInches,
                    model.project.machine.bedHeightInches,
                    model.project.machine.watts))
            .font(.caption2).foregroundStyle(.secondary)

        Field("Address") {
            TextField("192.168.1.50", text: Binding(
                get: { model.project.machine.host },
                set: {
                    model.project.machine.host = $0
                    model.preferences.machine.host = $0
                }
            ))
            .textFieldStyle(.roundedBorder)
        }

        HStack {
            Button("Test connection") { model.testConnection() }
                .controlSize(.small)
            Spacer()
        }
        Text("The laser shows its address on its own display, under Network.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        Toggle("Measure focus automatically", isOn: $model.project.autofocus)
            .font(.callout)

        if !model.project.autofocus {
            Field("Focus offset") {
                HStack(spacing: 4) {
                    TextField("", value: Binding(
                        get: { Double(model.project.focusOffset) / 39.7 },
                        set: { model.project.focusOffset = Int(($0 * 39.7).rounded()) }
                    ), formatter: decimalFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                    Text("mm").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Material

    @ViewBuilder
    private var materialSection: some View {
        if let material = model.project.material {
            Text("\(material.name), \(formatInches(material.thicknessInches))")
                .font(.callout.weight(.medium))
            if !material.notes.isEmpty {
                Text(material.notes)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if model.preferences.materials.isEmpty {
            Text("No materials saved yet. Work out settings that cut cleanly on a "
                 + "scrap, then save them here and they are one click away next time.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Menu {
                ForEach(model.preferences.sortedMaterials) { preset in
                    Button("\(preset.name) — \(formatInches(preset.thicknessInches))") {
                        model.applyMaterial(preset)
                    }
                }
            } label: {
                Label("Apply saved settings", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
        }

        HStack(spacing: 6) {
            Button("Save current…") { model.showSaveMaterialSheet = true }
                .help("Store what the layers are set to now, under a material name")
            Button("Manage…") { model.showMaterialsSheet = true }
            Spacer()
        }
        .controlSize(.small)

        Divider().padding(.vertical, 2)

        Text("Stock size").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        HStack(spacing: 8) {
            InchField(label: "W", points: $model.project.pieceSize.width)
            InchField(label: "H", points: $model.project.pieceSize.height)
        }
        Text("Drawn on the bed as a guide, and checked before sending. Leave at zero "
             + "if you would rather not say.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        Toggle("Sort cuts so parts do not shift", isOn: $model.project.vectorSorting)
            .font(.callout)
        Text("Cuts the holes inside a part before the outline that frees it.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        Field("Mirror") {
            Picker("", selection: $model.project.mirror) {
                Text("Off").tag(JobOptions.MirrorMode.off)
                Text("Horizontal").tag(JobOptions.MirrorMode.horizontal)
                Text("Vertical").tag(JobOptions.MirrorMode.vertical)
                Text("Both").tag(JobOptions.MirrorMode.both)
            }
            .labelsHidden()
        }
        Text("For engraving the back face of clear material, read through the front.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

        Field("Engraving") {
            Picker("", selection: $model.project.rasterMode) {
                Text("Standard").tag(RasterMode.bitmap)
                Text("3D relief").tag(RasterMode.greyscale3D)
            }
            .labelsHidden()
        }
        if model.project.rasterMode == .greyscale3D {
            Text("Varies power with brightness to cut depth as well as marks. Needs "
                 + "artwork drawn as a height map, and a material that responds to it.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Toggle("Engrave from the bottom up", isOn: $model.project.engraveBottomUp)
            .font(.callout)
        Text("Keeps smoke off work already engraved when the exhaust pulls upward.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private func formatInches(_ value: Double) -> String {
        String(format: "%.4g\"", value)
    }

    private var decimalFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 3
        f.minimumFractionDigits = 0
        return f
    }
}

// MARK: - Small building blocks

/// A collapsible group with a plain header. DisclosureGroup's own styling is
/// heavier than this needs to be at inspector width.
private struct InspectorSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.leading, 2)
            }
        }
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(value).monospacedDigit()
            Spacer(minLength: 0)
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            content()
        }
    }
}

/// A field that reads and writes inches while the model stores points.
private struct InchField: View {
    let label: String
    @Binding var points: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 12)
            TextField("", value: Binding(
                get: { Double(points) / 72 },
                set: { points = CGFloat($0 * 72) }
            ), formatter: formatter)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 52)
            Text("\"").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var formatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 3
        f.minimumFractionDigits = 0
        return f
    }
}
