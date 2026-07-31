/*
 * StudioView.swift - The window
 */

import SwiftUI
import UniformTypeIdentifiers
import EpilogKit

struct StudioView: View {
    @EnvironmentObject var model: AppModel
    @State private var showImporter = false
    @State private var confirmSend = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VSplitView {
                    BedCanvasView()
                        .frame(minWidth: 420, minHeight: 260)
                    LayerListView()
                        .frame(minHeight: 120, idealHeight: 190, maxHeight: 420)
                }
                InspectorView()
                    .frame(minWidth: 280, idealWidth: 306, maxWidth: 380)
            }
            Divider()
            statusBar
            if model.showLog {
                Divider()
                LogPanel().frame(height: 170)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: ArtworkImporter.supportedContentTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importFiles(urls)
            case .failure(let error): model.present(error: error, whileDoing: "opening the file")
            }
        }
        .alert(item: $model.alert) { content in
            Alert(title: Text(content.title),
                  message: Text(content.message),
                  dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Send this job to the laser?",
                            isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send") { model.sendJob() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sendConfirmationMessage)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                showImporter = true
            } label: {
                Label("Add artwork", systemImage: "plus.rectangle.on.folder")
            }
            .help("Add a PDF, SVG or image to the bed")
        }

        ToolbarItem {
            Button {
                model.sendFrame()
            } label: {
                Label("Trace outline", systemImage: "viewfinder")
            }
            .disabled(model.project.items.isEmpty || model.activity != .idle)
            .help("Run the head around the job with the laser off, so you can line up "
                  + "your material. The lid can stay open.")
        }

        ToolbarItem {
            Button {
                if model.preferences.confirmBeforeSending {
                    confirmSend = true
                } else {
                    model.sendJob()
                }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .disabled(model.project.items.isEmpty || model.activity != .idle)
            .help("Send the job to the laser")
        }

        ToolbarItem {
            Menu {
                Button("Save job file…") { model.saveJobFile() }
                    .help("Write the raw bytes that would be sent, for inspection or "
                          + "for sending later")
                Divider()
                Button("Reload artwork from disk") { model.reloadAll() }
                    .disabled(model.project.items.isEmpty)
                Divider()
                Toggle("Show grid", isOn: $model.showGrid)
                Toggle("Show rulers", isOn: $model.showRulers)
                Divider()
                Toggle("Confirm before sending",
                       isOn: $model.preferences.confirmBeforeSending)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem {
            Button {
                model.showLog.toggle()
            } label: {
                Label("Log", systemImage: "text.alignleft")
            }
            .help("Show what the application is doing")
        }
    }

    private var sendConfirmationMessage: String {
        var parts: [String] = []
        if let summary = model.lastSummary {
            parts.append("About \(summary.estimatedDuration).")
        }
        parts.append("Check the material is in place and the lid is closed. "
                     + "The laser will wait for you to press GO.")
        return parts.joined(separator: " ")
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            switch model.activity {
            case .idle:
                if let summary = model.lastSummary, !summary.warnings.isEmpty {
                    Label(summary.warnings[0], systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if model.project.items.isEmpty {
                    Text("Drop a PDF, SVG or image onto the bed to begin.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(idleSummary).foregroundStyle(.secondary)
                }

            case .building(let what):
                ProgressView().controlSize(.small)
                Text(what + "…").foregroundStyle(.secondary)

            case .sending(let fraction):
                ProgressView(value: fraction).frame(width: 130)
                Text("Sending to \(model.project.machine.host)…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelSending() }
                    .controlSize(.small)
            }

            Spacer()

            if model.hasUnsavedChanges {
                Text("Edited").foregroundStyle(.tertiary)
            }
            Text(model.project.machine.name).foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 24)
    }

    private var idleSummary: String {
        let cuts = model.project.layers.filter { $0.operation.isVector && $0.contributes }.count
        let engraves = model.project.layers.filter { $0.operation == .engrave && $0.contributes }.count
        var parts: [String] = ["\(model.project.items.count) item(s)"]
        if engraves > 0 { parts.append("\(engraves) engraving layer(s)") }
        if cuts > 0 { parts.append("\(cuts) cutting layer(s)") }
        if cuts == 0 && engraves == 0 { parts.append("nothing switched on") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Log

struct LogPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var minimumLevel: EpilogLogLevel = .info

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $minimumLevel) {
                    Text("Everything").tag(EpilogLogLevel.debug)
                    Text("Normal").tag(EpilogLogLevel.info)
                    Text("Problems only").tag(EpilogLogLevel.warning)
                }
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.small)
                Spacer()
                Button("Copy") { copyAll() }.controlSize(.small)
                Button("Clear") { model.clearLog() }.controlSize(.small)
                Button {
                    model.showLog = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(icon(for: entry.level))
                                    .foregroundStyle(color(for: entry.level))
                                Text(entry.message)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.log.count) { _ in
                    if let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var visible: [AppModel.LogEntry] {
        model.log.filter { $0.level >= minimumLevel }
    }

    private func icon(for level: EpilogLogLevel) -> String {
        switch level {
        case .debug:   return "·"
        case .info:    return "›"
        case .warning: return "!"
        case .error:   return "×"
        }
    }

    private func color(for level: EpilogLogLevel) -> Color {
        switch level {
        case .debug:   return .secondary
        case .info:    return .accentColor
        case .warning: return .orange
        case .error:   return .red
        }
    }

    private func copyAll() {
        let text = visible.map { "\($0.level.cupsPrefix): \($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
