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
        didSet { markDirty(previous: oldValue) }
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

    /// Driven from both the Arrange menu and the toolbar.
    @Published var showArraySheet = false
    @Published var showToolpathSheet = false

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
            // Bind the weak reference before starting the task: `self?` inside
            // one would capture the optional variable itself, which is not
            // allowed across a concurrency boundary. The strong reference this
            // holds lasts only until the hop to the main actor completes.
            guard let model = self else { return }
            Task { @MainActor in model.append(level: level, message: message) }
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

    private func markDirty(previous: LaserProject) {
        hasUnsavedChanges = true
        lastSummary = nil
        recordForUndo(previous)
    }

    // MARK: - Undo

    /// The project is a value type, so undo is just keeping the old one.
    ///
    /// The difficulty is not storing states but deciding what counts as a step.
    /// Every character typed into a power field and every frame of a drag is a
    /// change; undoing them one at a time would be useless. So changes are
    /// coalesced: the state from before a burst is held until things go quiet,
    /// and only then does it become an undo step. Dragging a part across the
    /// bed and letting go is one undo, which is what a person means by it.
    ///
    /// Deliberately not Foundation's UndoManager: its registration API hands
    /// the target back on an unspecified context, which cannot safely touch a
    /// main-actor model on the macOS versions this has to run on. Two stacks of
    /// values do the same job with none of that.
    ///
    /// These three are published rather than the stacks themselves, so the Edit
    /// menu can enable and disable itself without anything having to watch a
    /// sixty-deep array of project snapshots for changes.
    @Published private(set) var undoDepth = 0
    @Published private(set) var redoDepth = 0
    @Published private(set) var hasPendingEdit = false

    private var undoStack: [LaserProject] = []
    private var redoStack: [LaserProject] = []
    private var undoBaseline: LaserProject?
    private var undoCoalescingTimer: Timer?
    private var isRestoring = false

    /// How long the project has to sit still before a change becomes a step.
    private static let undoQuietPeriod: TimeInterval = 0.45

    /// Snapshots kept. Each shares its artwork's geometry with the others - the
    /// paths are immutable and referenced, not copied - so the cost is the item
    /// and layer arrays, which is small.
    private static let undoLimit = 60

    private func recordForUndo(_ previous: LaserProject) {
        guard !isRestoring else { return }
        if undoBaseline == nil {
            undoBaseline = previous
            hasPendingEdit = true
        }

        undoCoalescingTimer?.invalidate()
        undoCoalescingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.undoQuietPeriod, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.commitUndoStep() }
        }
    }

    /// Close off the current burst of changes as one undoable step.
    ///
    /// Runs on a timer, and is called directly by anything that knows it has
    /// finished - the end of a drag, a save, a send - so a step is never left
    /// open across something the user would expect to undo on its own.
    func commitUndoStep() {
        undoCoalescingTimer?.invalidate()
        undoCoalescingTimer = nil
        guard let baseline = undoBaseline else { return }
        undoBaseline = nil

        // A change that leaves the project as it was is not a step. Clicking
        // into a power field and tabbing out of it should not fill the undo
        // stack with entries that do nothing when applied.
        guard project.differs(from: baseline) else {
            refreshUndoDepths()
            return
        }

        undoStack.append(baseline)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoDepths()
    }

    func undo() {
        commitUndoStep()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        restore(next)
    }

    var canUndo: Bool { undoDepth > 0 || hasPendingEdit }
    var canRedo: Bool { redoDepth > 0 }

    /// Replace the project without the change becoming a step of its own.
    private func restore(_ state: LaserProject) {
        isRestoring = true
        project = state
        isRestoring = false
        refreshUndoDepths()

        // A selection can name artwork the restored state does not have.
        selection = selection.filter { id in project.items.contains { $0.id == id } }
        if !project.layers.contains(where: { $0.id == selectedLayerID }) {
            selectedLayerID = project.layers.first?.id
        }
    }

    private func clearUndoHistory() {
        undoCoalescingTimer?.invalidate()
        undoCoalescingTimer = nil
        undoBaseline = nil
        undoStack.removeAll()
        redoStack.removeAll()
        refreshUndoDepths()
    }

    private func refreshUndoDepths() {
        undoDepth = undoStack.count
        redoDepth = redoStack.count
        hasPendingEdit = undoBaseline != nil
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

    // MARK: - Arranging

    enum AlignEdge {
        case left, right, top, bottom, centerHorizontally, centerVertically
    }

    /// Line the selection up.
    ///
    /// Two or more items align to each other; a single item aligns to the bed,
    /// because lining something up with itself is not a thing anyone wants and
    /// aligning to the bed is.
    func alignSelection(_ edge: AlignEdge) {
        let items = selectedItems
        guard !items.isEmpty else { return }

        let reference: CGRect
        if items.count == 1 {
            reference = CGRect(origin: .zero, size: project.bedSize)
        } else {
            reference = items.dropFirst().reduce(items[0].boundsOnBed) {
                $0.union($1.boundsOnBed)
            }
        }

        updateSelectedItems { item in
            let box = item.boundsOnBed
            switch edge {
            case .left:
                item.origin.x += reference.minX - box.minX
            case .right:
                item.origin.x += reference.maxX - box.maxX
            case .top:
                item.origin.y += reference.minY - box.minY
            case .bottom:
                item.origin.y += reference.maxY - box.maxY
            case .centerHorizontally:
                item.origin.x += reference.midX - box.midX
            case .centerVertically:
                item.origin.y += reference.midY - box.midY
            }
        }
        commitUndoStep()
    }

    /// Even out the gaps between three or more items.
    func distributeSelection(horizontally: Bool) {
        var items = selectedItems
        guard items.count > 2 else { return }

        items.sort {
            horizontally ? $0.boundsOnBed.midX < $1.boundsOnBed.midX
                         : $0.boundsOnBed.midY < $1.boundsOnBed.midY
        }

        // Hold the outermost two still and spread the rest between them, which
        // is what every drawing program does and what people expect.
        let first = items.first!.boundsOnBed
        let last = items.last!.boundsOnBed
        let span = horizontally ? last.midX - first.midX : last.midY - first.midY
        let step = span / CGFloat(items.count - 1)

        for (index, item) in items.enumerated() where index > 0 && index < items.count - 1 {
            guard let i = project.items.firstIndex(where: { $0.id == item.id }) else { continue }
            let box = item.boundsOnBed
            let target = (horizontally ? first.midX : first.midY) + step * CGFloat(index)
            if horizontally {
                project.items[i].origin.x += target - box.midX
            } else {
                project.items[i].origin.y += target - box.midY
            }
        }
        commitUndoStep()
    }

    /// Fill the bed with copies of the selection.
    ///
    /// Cutting twenty of the same part is most of what a laser gets used for,
    /// and doing it by duplicating and nudging twenty times is miserable.
    /// Spacing is the gap between copies, not the pitch, because that is the
    /// number someone measures off their material.
    func makeArray(columns: Int, rows: Int, gapX: CGFloat, gapY: CGFloat) {
        let originals = selectedItems
        guard !originals.isEmpty, columns > 0, rows > 0, columns * rows > 1 else { return }

        let box = originals.dropFirst().reduce(originals[0].boundsOnBed) {
            $0.union($1.boundsOnBed)
        }
        let pitchX = box.width + gapX
        let pitchY = box.height + gapY

        var copies: [PlacedArtwork] = []
        for row in 0..<rows {
            for column in 0..<columns where !(row == 0 && column == 0) {
                for original in originals {
                    var copy = original
                    copy.id = UUID()
                    copy.origin.x += CGFloat(column) * pitchX
                    copy.origin.y += CGFloat(row) * pitchY
                    copies.append(copy)
                }
            }
        }

        project.items.append(contentsOf: copies)
        selection.formUnion(copies.map(\.id))
        commitUndoStep()

        let total = originals.count * columns * rows
        EpilogLog.info("Arrayed \(originals.count) item(s) into \(columns) x \(rows) "
                       + "- \(total) in total.")
        if project.hasContentOffBed {
            EpilogLog.warning("Part of the array falls outside the bed.")
        }
    }

    // MARK: - Layer order

    /// Layers run in the order they are listed, so moving one changes the job.
    func moveLayer(id: UUID, by offset: Int) {
        guard let from = project.layers.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard project.layers.indices.contains(to) else { return }
        project.layers.swapAt(from, to)
        commitUndoStep()
    }

    func canMoveLayer(id: UUID, by offset: Int) -> Bool {
        guard let from = project.layers.firstIndex(where: { $0.id == id }) else { return false }
        return project.layers.indices.contains(from + offset)
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
        clearUndoHistory()
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
            clearUndoHistory()
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
        commitUndoStep()
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
