/*
 * SplitSheet.swift - Choose how far apart counts as separate
 *
 * There is no right answer to this, which is why it is a control rather than a
 * constant. At a small gap every letter of a word is its own object; at a large
 * one the whole page is one. The number that means "these are separate things"
 * depends entirely on the drawing, so the answer is shown while it is chosen.
 */

import SwiftUI
import EpilogKit

struct SplitSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentation

    @State private var gapInches = Double(Artwork.defaultSplitGap) / 72
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Split into parts").font(.headline)
            Text("Breaks the selection into separate objects you can move, "
                 + "rearrange and delete on their own. Shapes closer together "
                 + "than the gap stay as one object.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)

            HStack(spacing: 8) {
                Text("Gap").frame(width: 34, alignment: .leading)
                Slider(value: $gapInches, in: 0.005...1.0)
                TextField("", value: $gapInches, formatter: formatter)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Text("\"").foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: count > 1 ? "square.grid.2x2" : "square")
                    .foregroundStyle(count > 1 ? Color.accentColor : Color.secondary)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(count > 1 ? Color.primary : Color.secondary)
            }
            .padding(.vertical, 2)

            Text("A small gap separates the letters of a word. A large one keeps "
                 + "everything that is close together as one piece.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { presentation.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Split") {
                    model.splitSelection(mergingWithin: CGFloat(gapInches * 72))
                    presentation.wrappedValue.dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count < 2)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { recount() }
        .onChange(of: gapInches) { _ in recount() }
    }

    private func recount() {
        count = model.partCount(mergingWithin: CGFloat(gapInches * 72))
    }

    private var description: String {
        switch count {
        case 0:  return "Nothing selected."
        case 1:  return "One object — nothing to split at this gap."
        default: return "\(count) separate parts."
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
