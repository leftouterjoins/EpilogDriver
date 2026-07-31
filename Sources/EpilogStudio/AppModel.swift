/*
 * AppModel.swift - The state the whole window hangs off
 */

import Foundation
import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers
import EpilogKit

@MainActor
final class AppModel: ObservableObject {

    // MARK: - Document state

    @Published var project: LaserProject {
        didSet { markDirty() }
    }

    /// Currently selected pieces of artwork on the bed.
    @Published var selection: Set<UUID> = []

    /// Layer row the settings panel is showing.
    @Published var selectedLayerID: UUID?

    /// Where the project was last saved, if anywhere.
    @Published var documentURL: URL?
    @Published var hasUnsavedChanges = false

    // MARK: - View state

    /// Canvas magnification, in screen points per bed point.
    @Published var zoom: CGFloat = 1
    /// Canvas scroll offset, in screen points.
    @Published var pan: CGSize = .zero
    @Published var showGrid = true
    @Published var showRulers = true
    /// Draw the engraving as it will actually burn, dithering included. Slower
    /// to redraw, and worth it right before committing to expensive material.
    @Published var showBurnPreview = false

    // MARK: - Activity

    enum Activity: Equatable {
        case idle
        case building(String)
        case sending(Double)
    }

    @Published var activity: Activity = .idle
    @Published var lastSummary: JobSummary?
    @Published var alert: AlertContent?

    struct AlertContent: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var isError: Bool
    }

    // MARK: - Log

    struct LogEntry: Identifiable {
        let id = UUID()
        let level: EpilogLogLevel
        let message: String
        let date: Date
    }

    @Published private(set) var log: [LogEntry] = []
    @Published var showLog = false

    // MARK: - Preferences

    @Published var preferences = Preferences.load() {
        didSet { preferences.save() }
    }

    private var buildTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        var project = LaserProject(machine: .zing24)
        let prefs = Preferences.load()
        project.machine = prefs.machine
        project.resolution = prefs.resolution
        project.jobName = "Untitled"
        self.project = project
        self.preferences = prefs
        self.hasUnsavedChanges = false

        installLogHandler()
    }

    private func installLogHandler() {
        // The core reports through EpilogLog so it does not care who is
        // listening. Route it into the log panel, and keep stderr as well so a
        // crash report or a Console trace still has the same detail.
        EpilogLog.handler = { [weak self] level, message in
            fputs("\(level.cupsPrefix): \(message)\n", stderr)
            Task { @MainActor in self?.append(level: level, message: message) }
        }
        EpilogLog.minimumLevel = .debug
    }

    private func append(level: EpilogLogLevel, message: String) {
        log.append(LogEntry(level: level, message: message, date: Date()))
        // Engraving a photograph produces a lot of debug output; keep the panel
        // from growing without bound.
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    func clearLog() { log.removeAll() }

    private func markDirty() {
        hasUnsavedChanges = true
        lastSummary = nil
    }

    // MARK: - Importing

    func importFiles(_ urls: [URL]) {
        var imported = 0
        for url in urls {
            do {
                let pages = ArtworkImporter.pageCount(of: url)
                let artwork = try ArtworkImporter.importArtwork(from: url)
                var item = PlacedArtwork(artwork: artwork, sourceURL: url, pageIndex: 1)

                // Land it somewhere sensible: top-left of the bed, nudged along
                // so several files dropped at once do not stack up invisibly.
                let offset = CGFloat(project.items.count % 8) * 18
                item.origin = CGPoint(x: 18 + offset, y: 18 + offset)

                // Shrink anything larger than the bed. Applications that export
                // at one point per pixel produce enormous pages - a 12000x6000
                // pixel canvas becomes a 166-inch-wide document - and rasterizing
                // that at its nominal size would never finish.
                let bed = project.bedSize
                if artwork.size.width > bed.width || artwork.size.height > bed.height {
                    let fit = min(bed.width / artwork.size.width,
                                  bed.height / artwork.size.height)
                    item.scale = fit
                    item.origin = .zero
                    EpilogLog.info(String(format:
                        "%@ is %.0f x %.0f pt, larger than the bed; scaled to fit (%.3f)",
                        artwork.name, artwork.size.width, artwork.size.height, fit))
                }

                project.items.append(item)
                selection = [item.id]
                imported += 1

                if pages > 1 {
                    EpilogLog.info("\(artwork.name) has \(pages) pages; page 1 was added. "
                                   + "Use the page control in the inspector to choose another.")
                }
                describe(artwork)
            } catch {
                present(error: error, whileDoing: "opening \(url.lastPathComponent)")
            }
        }

        if imported > 0 {
            project.synchronizeLayers()
            selectFirstLayerIfNeeded()
            if project.jobName == "Untitled", let first = project.items.first {
                project.jobName = first.artwork.name
            }
        }
    }

    /// Say something useful about what just arrived, especially when it is the
    /// kind of file that cannot do what the operator is about to ask of it.
    private func describe(_ artwork: Artwork) {
        if artwork.paths.isEmpty {
            if artwork.imageCount > 0 {
                EpilogLog.warning("\(artwork.name) contains no outlines - it is a flat image. "
                                  + "It can be engraved, but there is nothing to cut. To cut "
                                  + "its shapes, export it from the original application as "
                                  + "PDF or SVG.")
            } else {
                EpilogLog.warning("\(artwork.name) has no vector artwork in it.")
            }
        } else {
            EpilogLog.info("\(artwork.name): \(artwork.paths.count) shape(s) in "
                           + "\(artwork.distinctColors.count) colour(s).")
        }
    }

    /// Swap a placed PDF to a different page, keeping its position and scale.
    func setPage(_ page: Int, forItem id: UUID) {
        guard let index = project.items.firstIndex(where: { $0.id == id }),
              let url = project.items[index].sourceURL else { return }
        do {
            let artwork = try ArtworkImporter.importArtwork(from: url, pageIndex: page)
            project.items[index].artwork = artwork
            project.items[index].pageIndex = page
            project.synchronizeLayers()
        } catch {
            present(error: error, whileDoing: "loading page \(page)")
        }
    }

    /// Re-read every placed file from disk.
    func reloadAll() {
        for index in project.items.indices {
            guard let url = project.items[index].sourceURL else { continue }
            do {
                project.items[index].artwork = try ArtworkImporter.importArtwork(
                    from: url, pageIndex: project.items[index].pageIndex)
            } catch {
                present(error: error, whileDoing: "reloading \(url.lastPathComponent)")
            }
        }
        project.synchronizeLayers()
        EpilogLog.info("Reloaded \(project.items.count) file(s) from disk.")
    }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        project.items.removeAll { selection.contains($0.id) }
        selection = []
        project.synchronizeLayers()
        selectFirstLayerIfNeeded()
    }

    func duplicateSelected() {
        let copies = project.items.filter { selection.contains($0.id) }.map { original -> PlacedArtwork in
            var copy = original
            copy.id = UUID()
            copy.origin.x += 18
            copy.origin.y += 18
            return copy
        }
        guard !copies.isEmpty else { return }
        project.items.append(contentsOf: copies)
        selection = Set(copies.map(\.id))
    }

    func selectAll() {
        selection = Set(project.items.map(\.id))
    }

    private func selectFirstLayerIfNeeded() {
        if selectedLayerID == nil || !project.layers.contains(where: { $0.id == selectedLayerID }) {
            selectedLayerID = project.layers.first?.id
        }
    }

    // MARK: - Placement

    var selectedItems: [PlacedArtwork] {
        project.items.filter { selection.contains($0.id) }
    }

    func updateSelectedItems(_ transform: (inout PlacedArtwork) -> Void) {
        for index in project.items.indices where selection.contains(project.items[index].id) {
            transform(&project.items[index])
        }
    }

    func centerSelection() {
        for id in selection { project.centerOnBed(itemID: id) }
    }

    func fitSelectionToBed() {
        for id in selection { project.fitToBed(itemID: id) }
    }

    func moveSelectionToOrigin() {
        for id in selection { project.moveToOrigin(itemID: id) }
    }

    func rotateSelection(by radians: CGFloat) {
        updateSelectedItems { $0.rotation += radians }
    }

    // MARK: - Layers

    func binding(forLayer id: UUID) -> Binding<LaserLayer>? {
        guard let index = project.layers.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.project.layers[safe: index] ?? LaserLayer(target: .background, name: "",
                                                                operation: .skip, power: 0, speed: 100)
            },
            set: { [weak self] newValue in
                guard let self, self.project.layers.indices.contains(index) else { return }
                self.project.layers[index] = newValue
            }
        )
    }

    func applyMaterial(_ preset: MaterialPreset) {
        project.applyMaterial(preset)
        EpilogLog.info("Applied \(preset.name) \(preset.thicknessInches)\" settings"
                       + (preset.referenceWatts != project.machine.watts
                          ? ", rescaled from \(preset.referenceWatts)W to "
                            + "\(project.machine.watts)W - test on scrap first."
                          : "."))
    }

    // MARK: - Building and sending

    /// Build the job without sending it, to fill in the estimate and warnings.
    func refreshSummary() {
        buildTask?.cancel()
        let snapshot = project
        activity = .building("Checking the job")
        buildTask = Task.detached(priority: .userInitiated) {
            let job = JobBuilder.build(project: snapshot,
                                       shouldCancel: { Task.isCancelled })
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.activity = .idle
                self.lastSummary = job?.summary
            }
        }
    }

    func saveJobFile() {
        buildJob { [weak self] job in
            guard let self, let job else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = self.project.jobName + ".prn"
            panel.allowedContentTypes = [UTType(filenameExtension: "prn") ?? .data]
            panel.message = "Save the raw job as it would be sent to the laser."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try job.data.write(to: url)
                EpilogLog.info("Wrote \(job.data.count) bytes to \(url.lastPathComponent)")
            } catch {
                self.present(error: error, whileDoing: "saving the job file")
            }
        }
    }

    func sendFrame(mode: JobOptions.TestFrameMode = .trace) {
        guard !project.items.isEmpty else {
            present(title: "Nothing to trace",
                    message: "Add some artwork to the bed first.", isError: false)
            return
        }
        let snapshot = project
        activity = .building("Preparing the outline")
        Task.detached(priority: .userInitiated) {
            let job = JobBuilder.buildTestFrame(project: snapshot, mode: mode)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activity = .idle
                guard let job else {
                    self.present(title: "Nothing to trace",
                                 message: "There is no artwork on the bed to draw an outline around.",
                                 isError: false)
                    return
                }
                self.transmit(job, describing: "outline")
            }
        }
    }

    func sendJob() {
        buildJob { [weak self] job in
            guard let self, let job else { return }
            guard !job.summary.isEmpty else {
                self.present(title: "This job would do nothing",
                             message: job.summary.warnings.first
                                ?? "Every layer is switched off or set to zero power.",
                             isError: false)
                return
            }
            self.transmit(job, describing: "job")
        }
    }

    private func buildJob(then completion: @escaping (LaserJob?) -> Void) {
        buildTask?.cancel()
        let snapshot = project
        activity = .building("Preparing the job")
        buildTask = Task.detached(priority: .userInitiated) {
            let job = JobBuilder.build(project: snapshot, shouldCancel: { Task.isCancelled })
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activity = .idle
                self.lastSummary = job?.summary
                guard !Task.isCancelled else { return }
                guard let job else {
                    self.present(title: "Could not prepare the job",
                                 message: "Check the log for details.", isError: true)
                    return
                }
                completion(job)
            }
        }
    }

    private func transmit(_ job: LaserJob, describing what: String) {
        let host = project.machine.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            present(title: "No laser address",
                    message: "Enter the machine's IP address under Machine before sending. "
                           + "It is shown on the laser's own display.",
                    isError: true)
            return
        }

        let destination = LPDClient.Destination(host: host, port: project.machine.port)
        let title = job.name
        activity = .sending(0)

        sendTask = Task.detached(priority: .userInitiated) {
            let client = LPDClient()
            do {
                try client.send(job: job.data, title: title, to: destination,
                                progress: { fraction in
                                    Task { @MainActor in
                                        self.activity = .sending(fraction)
                                    }
                                },
                                shouldCancel: { Task.isCancelled })
                await MainActor.run {
                    self.activity = .idle
                    self.present(title: "Sent to the laser",
                                 message: "The \(what) is queued. Press GO on the machine "
                                        + "when the material is in place.",
                                 isError: false)
                }
            } catch {
                await MainActor.run {
                    self.activity = .idle
                    self.present(error: error, whileDoing: "sending the \(what)")
                }
            }
        }
    }

    func cancelSending() {
        sendTask?.cancel()
        buildTask?.cancel()
        activity = .idle
    }

    func testConnection() {
        let host = project.machine.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            present(title: "No laser address",
                    message: "Enter the machine's IP address first.", isError: true)
            return
        }
        let destination = LPDClient.Destination(host: host, port: project.machine.port)
        Task.detached(priority: .userInitiated) {
            do {
                try LPDClient(timeout: 8).testConnection(to: destination)
                await MainActor.run {
                    self.present(title: "The laser answered",
                                 message: "\(host) accepted a connection on port "
                                        + "\(destination.port).",
                                 isError: false)
                }
            } catch {
                await MainActor.run {
                    self.present(error: error, whileDoing: "contacting the laser")
                }
            }
        }
    }

    // MARK: - Project files

    func newProject() {
        project = {
            var p = LaserProject(machine: preferences.machine)
            p.resolution = preferences.resolution
            return p
        }()
        selection = []
        selectedLayerID = nil
        documentURL = nil
        hasUnsavedChanges = false
        lastSummary = nil
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        do {
            let loaded = try ProjectFile.load(from: url)
            project = loaded.project
            documentURL = url
            hasUnsavedChanges = false
            selection = []
            selectFirstLayerIfNeeded()
            for missing in loaded.missingFiles {
                EpilogLog.warning("\(missing.lastPathComponent) could not be found, so that "
                                  + "artwork is missing from the bed.")
            }
        } catch {
            present(error: error, whileDoing: "opening the project")
        }
    }

    func saveProject() {
        guard let url = documentURL else { saveProjectAs(); return }
        write(to: url)
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.nameFieldStringValue = project.jobName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try ProjectFile.save(project, to: url)
            documentURL = url
            hasUnsavedChanges = false
            EpilogLog.info("Saved \(url.lastPathComponent)")
        } catch {
            present(error: error, whileDoing: "saving the project")
        }
    }

    // MARK: - Messages

    func present(title: String, message: String, isError: Bool) {
        alert = AlertContent(title: title, message: message, isError: isError)
        EpilogLog.log(isError ? .error : .info, "\(title): \(message)")
    }

    func present(error: Error, whileDoing what: String) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        present(title: "Problem \(what)", message: detail, isError: true)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
