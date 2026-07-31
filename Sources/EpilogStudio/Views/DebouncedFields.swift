/*
 * DebouncedFields.swift - Text fields that do not make the whole app think
 *
 * Every write to the project republishes it: the canvas redraws, the layer
 * table rebuilds, the estimate is discarded, an undo snapshot is taken. That is
 * the right amount of work for a change, and far too much for a keystroke -
 * typing "80" into a power field should not cost two full rounds of it.
 *
 * So these keep what you are typing locally and hand it to the model once you
 * stop. Typing stays at keyboard speed, and the value still lands on its own a
 * quarter of a second later - no committing step to forget, which matters when
 * forgetting it would mean cutting at the old power.
 */

import SwiftUI

/// How long the field waits after the last keystroke before publishing.
/// Short enough that reaching for the mouse is slower than it is.
private let commitDelay: UInt64 = 250_000_000   // nanoseconds

// MARK: - Whole numbers

struct DebouncedIntField: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var suffix: String = ""
    var showsStepper = true
    var help: String?

    @State private var text = ""
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 1) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit(commitNow)
                .onChange(of: text) { _ in scheduleCommit() }
                .onChange(of: focused) { isFocused in if !isFocused { commitNow() } }
                .onChange(of: value) { newValue in
                    // Something else changed it - a stepper, an undo, a
                    // material being applied. Do not fight the user's typing.
                    if !focused { text = String(newValue) }
                }
                .onAppear { text = String(value) }

            if !suffix.isEmpty {
                Text(suffix).font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if showsStepper {
                // Steppers write straight through: one click is one change, and
                // waiting a quarter second to see it would feel broken.
                Stepper("", value: Binding(
                    get: { value },
                    set: { value = clamp($0); text = String(value) }
                ), in: range)
                    .labelsHidden()
                    .controlSize(.mini)
            }
        }
        .modifier(OptionalHelp(text: help))
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: commitDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { commitNow() }
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // An empty or half-typed field is not a value; leave the model alone
        // and let the text stand until it becomes one.
        guard let parsed = Int(trimmed) else { return }
        let clamped = clamp(parsed)
        if clamped != value { value = clamped }
        if String(clamped) != trimmed { text = String(clamped) }
    }

    private func clamp(_ n: Int) -> Int {
        min(max(n, range.lowerBound), range.upperBound)
    }
}

// MARK: - Lengths

/// Reads and writes inches while the model stores points.
struct DebouncedInchField: View {
    let label: String
    @Binding var points: CGFloat
    var labelWidth: CGFloat = 12
    var fieldWidth: CGFloat = 52

    @State private var text = ""
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if !label.isEmpty {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .frame(width: labelWidth)
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: fieldWidth)
                .focused($focused)
                .onSubmit(commitNow)
                .onChange(of: text) { _ in scheduleCommit() }
                .onChange(of: focused) { isFocused in if !isFocused { commitNow() } }
                .onChange(of: points) { newValue in
                    if !focused { text = format(newValue / 72) }
                }
                .onAppear { text = format(points / 72) }
            Text("\"").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: commitDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { commitNow() }
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let inches = Double(trimmed) else { return }
        let newPoints = CGFloat(inches * 72)
        if abs(newPoints - points) > 0.0001 { points = newPoints }
    }

    private func format(_ inches: CGFloat) -> String {
        // Trailing zeros in a field you are about to type into are noise.
        let rounded = (Double(inches) * 1000).rounded() / 1000
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%g", rounded)
    }
}

/// A plain decimal field - degrees, millimetres, anything not in inches.
struct DebouncedDoubleField: View {
    @Binding var value: Double
    var width: CGFloat = 62
    var maximumFractionDigits = 3

    @State private var text = ""
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .onSubmit(commitNow)
            .onChange(of: text) { _ in scheduleCommit() }
            .onChange(of: focused) { isFocused in if !isFocused { commitNow() } }
            .onChange(of: value) { newValue in if !focused { text = format(newValue) } }
            .onAppear { text = format(value) }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: commitDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { commitNow() }
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        // "-" and "1." are on the way to a number, not numbers. Leave them be.
        guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
        if abs(parsed - value) > 0.0001 { value = parsed }
    }

    private func format(_ v: Double) -> String {
        let scale = pow(10.0, Double(maximumFractionDigits))
        let rounded = (v * scale).rounded() / scale
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
    }
}

// MARK: - Free text

/// A name field that does not republish the project on every character.
struct DebouncedTextField: View {
    var prompt: String = ""
    @Binding var text: String
    var rounded = false

    @State private var draft = ""
    @State private var commitTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if rounded {
                TextField(prompt, text: $draft).textFieldStyle(.roundedBorder)
            } else {
                TextField(prompt, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
        }
        .focused($focused)
        .onSubmit(commitNow)
        .onChange(of: draft) { _ in scheduleCommit() }
        .onChange(of: focused) { isFocused in if !isFocused { commitNow() } }
        .onChange(of: text) { newValue in if !focused { draft = newValue } }
        .onAppear { draft = text }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: commitDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { commitNow() }
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        if draft != text { text = draft }
    }
}


/// Applies a help tooltip only when there is one, so a caller's own `.help`
/// on the surrounding view is not overwritten with an empty string.
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}
