/*
 * MaterialSheets.swift - Keeping the settings that actually worked
 *
 * The most valuable thing a laser operator owns is a table of numbers that are
 * known to cut cleanly, because arriving at one costs scrap and time. The
 * application ships with none of them on purpose: settings that came off
 * somebody else's machine, with a different tube at a different age, are a
 * confident way of wasting an afternoon.
 */

import SwiftUI
import EpilogKit

// MARK: - Saving

/// Store what the layers are set to now.
struct SaveMaterialSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentation

    @State private var name = ""
    @State private var thickness = 0.125
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save material settings").font(.headline)
            Text("Stores the power, speed, frequency and passes your layers are "
                 + "using right now, so you can put them back with one click.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)

            HStack(spacing: 6) {
                Text("Material").frame(width: 74, alignment: .leading)
                TextField("Birch plywood", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Text("Thickness").frame(width: 74, alignment: .leading)
                TextField("", value: $thickness, formatter: inchFormatter)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("\"").foregroundStyle(.secondary)
                Spacer()
            }
            HStack(alignment: .top, spacing: 6) {
                Text("Notes").frame(width: 74, alignment: .leading)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.3)))
            }

            summary

            HStack {
                Spacer()
                Button("Cancel") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveCurrentAsMaterial(
                        name: name.trimmingCharacters(in: .whitespaces),
                        thicknessInches: thickness, notes: notes)
                    presentation.wrappedValue.dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 430)
        .onAppear {
            if let current = model.project.material {
                name = current.name
                thickness = current.thicknessInches
                notes = current.notes
            }
        }
    }

    /// Show what is about to be stored, so nobody saves the wrong thing.
    @ViewBuilder
    private var summary: some View {
        let cut = model.project.layers.first { $0.operation == .cut }
        let engrave = model.project.layers.first { $0.operation == .engrave }
        let score = model.project.layers.first { $0.operation == .score }

        VStack(alignment: .leading, spacing: 2) {
            if let cut {
                Text("Cut  \(cut.power)% / \(cut.speed)% / \(cut.frequency) Hz"
                     + (cut.passes > 1 ? " / \(cut.passes) passes" : ""))
            }
            if let engrave {
                Text("Engrave  \(engrave.power)% / \(engrave.speed)%")
            }
            if let score {
                Text("Score  \(score.power)% / \(score.speed)%")
            }
            if cut == nil && engrave == nil && score == nil {
                Text("No layers to save settings from yet.").foregroundStyle(.orange)
            }
            Text("Recorded against \(model.project.machine.watts) W.")
                .foregroundStyle(.tertiary)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Managing

struct MaterialsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentation

    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Materials").font(.headline)
                Spacer()
                Button("Done") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            HSplitView {
                list.frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
                editor.frame(minWidth: 340)
            }
        }
        .frame(width: 700, height: 470)
        .onAppear { selected = selected ?? model.preferences.sortedMaterials.first?.id }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.preferences.materials.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing saved yet").font(.callout.weight(.medium))
                    Text("Dial in settings that cut cleanly on a scrap, then use "
                         + "Save current in the Material section.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selected) {
                    ForEach(model.preferences.sortedMaterials) { preset in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                            Text(String(format: "%.4g\" · %d W",
                                        preset.thicknessInches, preset.referenceWatts))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(preset.id)
                    }
                }
            }

            Divider()

            HStack(spacing: 4) {
                Button {
                    if let selected { model.duplicateMaterial(id: selected) }
                } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(selected == nil)
                    .help("Duplicate")

                Button {
                    guard let selected else { return }
                    model.deleteMaterial(id: selected)
                    self.selected = model.preferences.sortedMaterials.first?.id
                } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                    .help("Delete")

                Spacer()

                Button("Apply") {
                    guard let selected,
                          let preset = model.preferences.materials
                              .first(where: { $0.id == selected }) else { return }
                    model.applyMaterial(preset)
                }
                .disabled(selected == nil)
                .help("Set every layer in this job to these numbers")
            }
            .controlSize(.small)
            .padding(6)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selected,
           let index = model.preferences.materials.firstIndex(where: { $0.id == id }) {
            MaterialEditor(preset: Binding(
                get: { model.preferences.materials[index] },
                set: { model.updateMaterial($0) }))
        } else {
            Text("Select a material.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MaterialEditor: View {
    @Binding var preset: MaterialPreset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                group("Material") {
                    row("Name") {
                        TextField("", text: $preset.name).textFieldStyle(.roundedBorder)
                    }
                    row("Thickness") {
                        HStack(spacing: 4) {
                            TextField("", value: $preset.thicknessInches,
                                      formatter: inchFormatter)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 66)
                            Text("\"").foregroundStyle(.secondary)
                        }
                    }
                    row("Measured on") {
                        HStack(spacing: 4) {
                            TextField("", value: $preset.referenceWatts,
                                      formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                            Text("W").foregroundStyle(.secondary)
                        }
                    }
                    Text("Applying these to a machine of a different wattage adjusts "
                         + "the speeds to match, which is a starting point and not a "
                         + "promise.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("Cutting") {
                    percent("Power", $preset.cutPower)
                    percent("Speed", $preset.cutSpeed)
                    row("Frequency") {
                        stepperField($preset.cutFrequency, range: 1...5000, width: 66,
                                     suffix: "Hz")
                    }
                    row("Passes") {
                        stepperField($preset.cutPasses, range: 1...20, width: 52, suffix: "")
                    }
                }

                group("Engraving") {
                    percent("Power", $preset.engravePower)
                    percent("Speed", $preset.engraveSpeed)
                    row("Dithering") {
                        Picker("", selection: $preset.engraveDither) {
                            ForEach(DitherMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }
                }

                group("Scoring") {
                    percent("Power", $preset.scorePower)
                    percent("Speed", $preset.scoreSpeed)
                }

                group("Notes") {
                    TextEditor(text: $preset.notes)
                        .font(.body)
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.3)))
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 88, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func percent(_ label: String, _ value: Binding<Int>) -> some View {
        row(label) {
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ), in: 0...100)
                    .frame(width: 150)
                Text("\(value.wrappedValue)%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private func stepperField(_ value: Binding<Int>, range: ClosedRange<Int>,
                              width: CGFloat, suffix: String) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, formatter: NumberFormatter())
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
            Stepper("", value: value, in: range).labelsHidden()
        }
    }
}

private var inchFormatter: NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 4
    f.minimumFractionDigits = 0
    return f
}
