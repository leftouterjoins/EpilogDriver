/*
 * EpilogStudioApp.swift - Entry point, menus and the headless mode
 */

import SwiftUI
import AppKit
import EpilogKit

@main
struct EpilogStudioApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // A command line invocation never opens a window. Useful for scripting
        // a batch of parts, and for checking what the application would send
        // without standing at the machine.
        CommandLineRunner.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            StudioView()
                .environmentObject(model)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .commands { menus }
    }

    @CommandsBuilder
    private var menus: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { model.newProject() }
                .keyboardShortcut("n")
            Button("Open…") { model.openProject() }
                .keyboardShortcut("o")
            Divider()
            Button("Add Artwork…") { addArtwork() }
                .keyboardShortcut("i")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveProject() }
                .keyboardShortcut("s")
            Button("Save As…") { model.saveProjectAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Save Job File…") { model.saveJobFile() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }

        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { model.duplicateSelected() }
                .keyboardShortcut("d")
                .disabled(model.selection.isEmpty)
            Button("Delete") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selection.isEmpty)
            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a")
        }

        CommandMenu("Arrange") {
            Button("Centre on Bed") { model.centerSelection() }
                .disabled(model.selection.isEmpty)
            Button("Move to Top Left") { model.moveSelectionToOrigin() }
                .disabled(model.selection.isEmpty)
            Button("Fit to Bed") { model.fitSelectionToBed() }
                .disabled(model.selection.isEmpty)
            Divider()
            Button("Align Left") { model.alignSelection(.left) }
                .disabled(model.selection.isEmpty)
            Button("Align Right") { model.alignSelection(.right) }
                .disabled(model.selection.isEmpty)
            Button("Align Top") { model.alignSelection(.top) }
                .disabled(model.selection.isEmpty)
            Button("Align Bottom") { model.alignSelection(.bottom) }
                .disabled(model.selection.isEmpty)
            Button("Centre Horizontally") { model.alignSelection(.centerHorizontally) }
                .disabled(model.selection.isEmpty)
            Button("Centre Vertically") { model.alignSelection(.centerVertically) }
                .disabled(model.selection.isEmpty)
            Divider()
            Button("Distribute Horizontally") { model.distributeSelection(horizontally: true) }
                .disabled(model.selection.count < 3)
            Button("Distribute Vertically") { model.distributeSelection(horizontally: false) }
                .disabled(model.selection.count < 3)
            Divider()
            Button("Make Array…") { model.showArraySheet = true }
                .keyboardShortcut("k")
                .disabled(model.selection.isEmpty)
            Divider()
            Button("Rotate 90° Left") { model.rotateSelection(by: -.pi / 2) }
                .disabled(model.selection.isEmpty)
            Button("Rotate 90° Right") { model.rotateSelection(by: .pi / 2) }
                .disabled(model.selection.isEmpty)
        }

        CommandMenu("Laser") {
            Button("Trace Outline") { model.sendFrame(mode: .trace) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.project.items.isEmpty)
            Button("Trace Outline, Marking Faintly") { model.sendFrame(mode: .mark) }
                .disabled(model.project.items.isEmpty)
            Divider()
            Button("Send to Laser") { model.sendJob() }
                .keyboardShortcut("p")
                .disabled(model.project.items.isEmpty)
            Button("Check Job") { model.refreshSummary() }
                .keyboardShortcut("r")
            Divider()
            Button("Test Connection") { model.testConnection() }
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom In") { model.zoom = min(8, model.zoom * 1.25) }
                .keyboardShortcut("+")
            Button("Zoom Out") { model.zoom = max(0.05, model.zoom / 1.25) }
                .keyboardShortcut("-")
            Divider()
            Toggle("Show Grid", isOn: $model.showGrid)
            Toggle("Show Rulers", isOn: $model.showRulers)
            Toggle("Show Log", isOn: $model.showLog)
        }

        CommandGroup(replacing: .help) {
            Button("Epilog Studio Help") {
                NSWorkspace.shared.open(
                    URL(string: "https://github.com/leftouterjoins/EpilogDriver")!)
            }
        }
    }

    private func addArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ArtworkImporter.supportedContentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose artwork to place on the bed."
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Headless mode

enum CommandLineRunner {

    /// Run and exit if the process was given work to do on the command line.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count > 1 else { return }

        // Xcode and the SwiftUI previews pass their own flags; ignore anything
        // that is not one of ours.
        guard args.contains(where: { $0 == "--render" || $0 == "--help" || $0 == "-h" })
        else { return }

        if args.contains("--help") || args.contains("-h") {
            print(usage)
            exit(0)
        }

        var input: String?
        var output: String?
        var host: String?
        var dpi = 500
        var machineID = "zing24"
        var frameOnly = false

        var index = 1
        while index < args.count {
            switch args[index] {
            case "--render":  input = args[safe: index + 1]; index += 1
            case "-o", "--output": output = args[safe: index + 1]; index += 1
            case "--send":    host = args[safe: index + 1]; index += 1
            case "--dpi":     dpi = Int(args[safe: index + 1] ?? "") ?? 500; index += 1
            case "--machine": machineID = args[safe: index + 1] ?? "zing24"; index += 1
            case "--frame":   frameOnly = true
            default: break
            }
            index += 1
        }

        guard let input else {
            FileHandle.standardError.write(Data("error: --render needs a file\n".utf8))
            exit(2)
        }

        let machine = LaserMachine.presets.first { $0.id == machineID } ?? .zing24

        do {
            let url = URL(fileURLWithPath: input)
            let artwork = try ArtworkImporter.importArtwork(from: url)

            var project = LaserProject(machine: machine, resolution: dpi,
                                       jobName: artwork.name)
            var item = PlacedArtwork(artwork: artwork, sourceURL: url)
            let bed = project.bedSize
            if artwork.size.width > bed.width || artwork.size.height > bed.height {
                item.scale = min(bed.width / artwork.size.width,
                                 bed.height / artwork.size.height)
            }
            project.items = [item]
            project.synchronizeLayers()

            guard let job = frameOnly
                    ? JobBuilder.buildTestFrame(project: project, mode: .trace)
                    : JobBuilder.build(project: project) else {
                FileHandle.standardError.write(Data("error: nothing to send\n".utf8))
                exit(1)
            }

            for warning in job.summary.warnings {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }

            if let output {
                try job.data.write(to: URL(fileURLWithPath: output))
                print("wrote \(job.data.count) bytes to \(output)")
            }
            if let host {
                try LPDClient().send(job: job.data, title: job.name,
                                     to: .init(host: host))
                print("sent \(job.data.count) bytes to \(host)")
            }
            if output == nil && host == nil {
                FileHandle.standardOutput.write(job.data)
            }
            exit(0)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            FileHandle.standardError.write(Data("error: \(detail)\n".utf8))
            exit(1)
        }
    }

    private static let usage = """
        Epilog Studio

        Opens a window when run with no arguments. With --render it prepares a
        job and exits, which is what you want from a script.

          --render FILE      artwork to prepare (PDF, SVG, PNG, JPEG)
          -o, --output FILE  write the job here instead of to standard output
          --send HOST        send the job to a laser at this address
          --frame            trace the outline instead of running the job
          --dpi N            engraving resolution (default 500)
          --machine ID       zing24 or zing16 (default zing24)

        Layers get their default assignment: saturated colours cut, everything
        else engraves. Open the file in the application to change that.
        """
}
