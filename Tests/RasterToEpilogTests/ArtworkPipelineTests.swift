/*
 * ArtworkPipelineTests.swift - Import a document, build a job, check the bytes
 *
 * These exist because the failure this project kept hitting was silent: the
 * machine engraved, stopped, and never cut, with nothing anywhere saying why.
 * Every test here asserts on something that failure would have caught.
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class ArtworkPipelineTests: XCTestCase {

    // MARK: - Fixtures

    /// A 4x3" page: a dark grey filled box, a cyan hairline rectangle, and a
    /// red circle. Deliberately the shape of a real job - something to engrave,
    /// something to cut, and a second cut colour.
    private func makeTestPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("epilog-test-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 288, height: 216)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw XCTSkip("Cannot create a PDF context")
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 0.15, alpha: 1)
        ctx.fill(CGRect(x: 40, y: 120, width: 90, height: 50))
        ctx.setStrokeColor(red: 0, green: 1, blue: 1, alpha: 1)
        ctx.setLineWidth(0.1)
        ctx.stroke(CGRect(x: 20, y: 20, width: 248, height: 176))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 170, y: 60, width: 60, height: 60))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private func makeProject(with artwork: Artwork) -> LaserProject {
        var project = LaserProject(machine: .zing24, resolution: 500, jobName: "Test")
        project.items = [PlacedArtwork(artwork: artwork, origin: CGPoint(x: 72, y: 72))]
        project.synchronizeLayers()
        return project
    }

    // MARK: - PDF import

    func testPDFImportFindsPathsAndColors() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let artwork = try ArtworkImporter.importArtwork(from: url)

        XCTAssertEqual(artwork.size.width, 288, accuracy: 0.5)
        XCTAssertEqual(artwork.size.height, 216, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(artwork.paths.count, 3,
                                    "the box, the hairline rectangle and the circle")

        let colors = artwork.distinctColors
        XCTAssertTrue(colors.contains(RGBColor(r8: 0, g8: 255, b8: 255)),
                      "cyan should survive import and snap to the nominal cut colour")
        XCTAssertTrue(colors.contains(RGBColor(r8: 255, g8: 0, b8: 0)),
                      "red should survive import")
    }

    /// The importer flips PDF's bottom-left origin to the top-left one the
    /// laser uses. A shape drawn near the top of the page must come out near
    /// the top, not mirrored to the bottom.
    func testPDFImportFlipsToTopLeftOrigin() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let artwork = try ArtworkImporter.importArtwork(from: url)

        // The grey box is at PDF y 120..170 on a 216pt page, so in document
        // space it lands at y 46..96 - in the upper half.
        let grey = artwork.paths.first { $0.fill != nil && $0.fill!.luma < 0.5 }
        let box = try XCTUnwrap(grey?.path.boundingBox)
        XCTAssertEqual(box.minY, 216 - 170, accuracy: 1.5)
        XCTAssertEqual(box.maxY, 216 - 120, accuracy: 1.5)
    }

    // MARK: - Layers

    func testDefaultLayersCutSaturatedColorsAndEngraveTheRest() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = makeProject(with: try ArtworkImporter.importArtwork(from: url))

        let cyan = try XCTUnwrap(project.layers.first {
            $0.target == .color(RGBColor(r8: 0, g8: 255, b8: 255))
        })
        XCTAssertEqual(cyan.operation, .cut)

        let red = try XCTUnwrap(project.layers.first {
            $0.target == .color(RGBColor(r8: 255, g8: 0, b8: 0))
        })
        XCTAssertEqual(red.operation, .cut)

        let grey = try XCTUnwrap(project.layers.first {
            guard let c = $0.target.color else { return false }
            return c.saturation < 0.1 && c.luma < 0.5
        })
        XCTAssertEqual(grey.operation, .engrave)

        XCTAssertTrue(project.layers.contains { $0.target == .background },
                      "a PDF page can hold text and images, so it needs a background layer")
    }

    /// Editing a layer must survive re-syncing, or every reimport would throw
    /// away the settings the operator just dialled in.
    func testSynchronizeLayersKeepsExistingSettings() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var project = makeProject(with: try ArtworkImporter.importArtwork(from: url))

        let index = try XCTUnwrap(project.layers.firstIndex { $0.operation == .cut })
        project.layers[index].power = 42
        project.layers[index].name = "my cut"

        project.synchronizeLayers()

        let again = try XCTUnwrap(project.layers.first { $0.name == "my cut" })
        XCTAssertEqual(again.power, 42)
    }

    // MARK: - Job assembly

    func testBuiltJobContainsRasterAndVectorSections() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = makeProject(with: try ArtworkImporter.importArtwork(from: url))

        let job = try XCTUnwrap(JobBuilder.build(project: project))
        let bytes = job.data

        XCTAssertTrue(contains(bytes, "@PJL JOB NAME=Test"), "PJL header")
        XCTAssertTrue(contains(bytes, "\u{1B}E@PJL ENTER LANGUAGE=PCL"), "PCL mode")
        XCTAssertTrue(contains(bytes, "\u{1B}*b2M"), "1-bit raster compression mode")
        XCTAssertTrue(contains(bytes, "\u{1B}%1B"), "HPGL vector section")
        XCTAssertTrue(contains(bytes, "PU"), "a pen-up move")
        XCTAssertTrue(contains(bytes, "PD"), "a pen-down cut")
        XCTAssertTrue(contains(bytes, "@PJL EOJ"), "PJL footer")

        XCTAssertGreaterThan(job.summary.vectorPathCount, 0, "the cyan and red shapes cut")
        XCTAssertGreaterThan(job.summary.engraveRows, 0, "the grey box engraves")

        // LPD decides a job is over when it sees the trailing NUL pad.
        XCTAssertEqual(bytes.suffix(4096), Data(repeating: 0, count: 4096))
    }

    /// The regression that cost a scrapped test cut: the vector section opened
    /// with SP0, which deselects the pen, so nothing fired.
    func testVectorSectionDoesNotDeselectThePen() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = makeProject(with: try ArtworkImporter.importArtwork(from: url))
        let job = try XCTUnwrap(JobBuilder.build(project: project))

        XCTAssertFalse(contains(job.data, "SP0"),
                       "SP0 deselects the pen and stops the machine cutting")
        XCTAssertTrue(contains(job.data, "\u{1B}%1BIN;"),
                      "the vector section opens with a plain HPGL initialise")
    }

    /// Turning a layer off has to actually remove it from the output. This is
    /// the one control an operator relies on when something is about to burn
    /// that should not.
    func testDisablingCutLayersRemovesTheVectorSection() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var project = makeProject(with: try ArtworkImporter.importArtwork(from: url))

        for i in project.layers.indices where project.layers[i].operation == .cut {
            project.layers[i].enabled = false
        }

        let job = try XCTUnwrap(JobBuilder.build(project: project))
        XCTAssertEqual(job.summary.vectorPathCount, 0)
        XCTAssertFalse(contains(job.data, "PD"), "nothing should cut")
        XCTAssertTrue(contains(job.data, "\u{1B}%1BIN;WF0;"),
                      "a raster-only job still needs the dummy vector section")
    }

    /// A shape routed to the cutter must not also be engraved, or every cut
    /// line gets a burned shadow beside it.
    func testCutGeometryIsNotAlsoEngraved() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let artwork = try ArtworkImporter.importArtwork(from: url)

        var project = makeProject(with: artwork)
        // Engrave everything, cut nothing.
        for i in project.layers.indices { project.layers[i].operation = .engrave }
        let engravedAll = try XCTUnwrap(JobBuilder.build(project: project))

        // Now cut the red circle instead of engraving it.
        project = makeProject(with: artwork)
        let red = RGBColor(r8: 255, g8: 0, b8: 0)
        for i in project.layers.indices {
            project.layers[i].operation = project.layers[i].target == .color(red)
                ? .cut : .engrave
        }
        let withCut = try XCTUnwrap(JobBuilder.build(project: project))

        XCTAssertLessThan(withCut.summary.engraveRows, engravedAll.summary.engraveRows,
                          "moving a filled shape to the cutter should shrink the engraving")
        XCTAssertGreaterThan(withCut.summary.vectorPathCount, 0)
    }

    func testTestFrameTracesTheExtentWithoutFiring() throws {
        let url = try makeTestPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = makeProject(with: try ArtworkImporter.importArtwork(from: url))

        let frame = try XCTUnwrap(JobBuilder.buildTestFrame(project: project, mode: .trace))
        XCTAssertTrue(contains(frame.data, "YP000;"), "trace runs at zero power")
        XCTAssertTrue(contains(frame.data, "PU"))
        XCTAssertEqual(frame.summary.vectorPathCount, 1)

        // The artwork sits at 1" in, on a 4x3" page.
        XCTAssertEqual(frame.summary.bounds.minX, 1.0, accuracy: 0.05)
        XCTAssertEqual(frame.summary.bounds.minY, 1.0, accuracy: 0.05)
        XCTAssertEqual(frame.summary.bounds.width, 4.0, accuracy: 0.05)
        XCTAssertEqual(frame.summary.bounds.height, 3.0, accuracy: 0.05)
    }

    /// A flat image has no outlines. Saying so is the whole difference between
    /// "this tool is broken" and "this file cannot do what you asked".
    func testFlattenedImageWarnsThatNothingWillCut() throws {
        let width = 64, height = 64
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: cs,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 8, y: 8, width: 48, height: 48))
        let image = try XCTUnwrap(ctx.makeImage())

        var project = LaserProject(machine: .zing24, jobName: "Flat")
        project.items = [PlacedArtwork(artwork: Artwork(name: "flat", size: CGSize(width: 64, height: 64),
                                                        paths: [], source: .image(image),
                                                        imageCount: 1))]
        project.synchronizeLayers()
        // Ask for a cut that the document cannot provide.
        project.layers.append(LaserLayer(target: .color(RGBColor(r8: 0, g8: 255, b8: 255)),
                                         name: "cyan", operation: .cut, power: 100, speed: 20))

        let job = try XCTUnwrap(JobBuilder.build(project: project))
        XCTAssertEqual(job.summary.vectorPathCount, 0)
        XCTAssertTrue(job.summary.warnings.contains { $0.contains("flat image") },
                      "got: \(job.summary.warnings)")
    }

    // MARK: - Helpers

    private func contains(_ haystack: Data, _ needle: String) -> Bool {
        haystack.range(of: Data(needle.utf8)) != nil
    }
}
