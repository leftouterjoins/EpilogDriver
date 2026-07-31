/*
 * ProjectFile.swift - Saving and reopening a job
 *
 * A project file stores the settings and a reference to each piece of artwork,
 * not the artwork itself. That is deliberate: the point of saving a job is to
 * run it again after changing the drawing, and a file that embedded a snapshot
 * would quietly go on cutting last week's version.
 */

import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import EpilogKit

enum ProjectFile {

    static let fileExtension = "epilogjob"

    static var contentType: UTType {
        UTType(exportedAs: "sh.macinjo.epilogstudio.job",
               conformingTo: .json)
    }

    struct LoadResult {
        var project: LaserProject
        /// Artwork the file referred to that is no longer where it was.
        var missingFiles: [URL] = []
    }

    // MARK: - On-disk shape

    private struct Document: Codable {
        var version = 1
        var jobName: String
        var machine: LaserMachine
        var resolution: Int
        var autofocus: Bool
        var focusOffset: Int
        var vectorSorting: Bool
        var mirror: String
        var rasterMode: RasterMode
        var engraveBottomUp: Bool
        var material: MaterialPreset?
        var pieceWidth: Double
        var pieceHeight: Double
        var layers: [LaserLayer]
        var items: [Item]

        struct Item: Codable {
            var path: String
            /// Relative to the project file, so a project and its artwork can
            /// be moved or shared together.
            var relativePath: String?
            var page: Int
            var x: Double
            var y: Double
            var scale: Double
            var rotation: Double
            var visible: Bool
        }
    }

    // MARK: - Save

    static func save(_ project: LaserProject, to url: URL) throws {
        let folder = url.deletingLastPathComponent()

        let items = project.items.compactMap { item -> Document.Item? in
            guard let source = item.sourceURL else { return nil }
            return Document.Item(
                path: source.path,
                relativePath: relativePath(from: folder, to: source),
                page: item.pageIndex,
                x: Double(item.origin.x),
                y: Double(item.origin.y),
                scale: Double(item.scale),
                rotation: Double(item.rotation),
                visible: item.visible)
        }

        if items.count < project.items.count {
            EpilogLog.warning("\(project.items.count - items.count) piece(s) of artwork were "
                              + "not saved because they did not come from a file.")
        }

        let document = Document(
            jobName: project.jobName,
            machine: project.machine,
            resolution: project.resolution,
            autofocus: project.autofocus,
            focusOffset: project.focusOffset,
            vectorSorting: project.vectorSorting,
            mirror: project.mirror.rawValue,
            rasterMode: project.rasterMode,
            engraveBottomUp: project.engraveBottomUp,
            material: project.material,
            pieceWidth: Double(project.pieceSize.width),
            pieceHeight: Double(project.pieceSize.height),
            layers: project.layers,
            items: items)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    // MARK: - Load

    static func load(from url: URL) throws -> LoadResult {
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(Document.self, from: data)
        let folder = url.deletingLastPathComponent()

        var project = LaserProject(machine: document.machine)
        project.jobName = document.jobName
        project.resolution = document.resolution
        project.autofocus = document.autofocus
        project.focusOffset = document.focusOffset
        project.vectorSorting = document.vectorSorting
        project.mirror = JobOptions.MirrorMode(rawValue: document.mirror) ?? .off
        project.rasterMode = document.rasterMode
        project.engraveBottomUp = document.engraveBottomUp
        project.material = document.material
        project.pieceSize = CGSize(width: document.pieceWidth, height: document.pieceHeight)

        var missing: [URL] = []
        for entry in document.items {
            // Prefer the artwork sitting next to the project file: that is the
            // copy that travelled with it.
            var candidates: [URL] = []
            if let relative = entry.relativePath {
                candidates.append(URL(fileURLWithPath: relative, relativeTo: folder)
                    .standardizedFileURL)
            }
            candidates.append(URL(fileURLWithPath: entry.path))

            guard let found = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) else {
                missing.append(URL(fileURLWithPath: entry.path))
                continue
            }

            do {
                let artwork = try ArtworkImporter.importArtwork(from: found,
                                                                pageIndex: entry.page)
                var item = PlacedArtwork(artwork: artwork, sourceURL: found,
                                         pageIndex: entry.page)
                item.origin = CGPoint(x: entry.x, y: entry.y)
                item.scale = CGFloat(entry.scale)
                item.rotation = CGFloat(entry.rotation)
                item.visible = entry.visible
                project.items.append(item)
            } catch {
                missing.append(found)
            }
        }

        // Take the saved layers, then reconcile against what the artwork now
        // contains. A colour that has appeared since the last save gets a new
        // layer; one that has gone disappears; everything else keeps its
        // settings.
        project.layers = document.layers
        project.synchronizeLayers()

        return LoadResult(project: project, missingFiles: missing)
    }

    // MARK: - Paths

    private static func relativePath(from folder: URL, to file: URL) -> String? {
        let base = folder.standardizedFileURL.pathComponents
        let target = file.standardizedFileURL.pathComponents

        var shared = 0
        while shared < base.count, shared < target.count, base[shared] == target[shared] {
            shared += 1
        }
        // Nothing in common but the root: a relative path would be nonsense.
        guard shared > 1 else { return nil }

        let up = Array(repeating: "..", count: base.count - shared)
        return (up + target[shared...]).joined(separator: "/")
    }
}
