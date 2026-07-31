/*
 * JobPreviewTests.swift - A preview that lies is worse than no preview
 *
 * The whole value of showing the toolpath is that it is what the machine will
 * do. If the preview and the job disagree about the order, someone will watch
 * a correct-looking animation and then scrap a part.
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class JobPreviewTests: XCTestCase {

    private let cyan = ArtworkColor(r8: 0, g8: 255, b8: 255)
    private let red = ArtworkColor(r8: 255, g8: 0, b8: 0)

    /// A part with a hole in it, plus a separate square, which is the shape
    /// that makes cut ordering matter.
    private func makeProject() -> LaserProject {
        func outline(_ rect: CGRect, _ color: ArtworkColor) -> ArtworkPath {
            ArtworkPath(path: CGPath(rect: rect, transform: nil),
                        stroke: color, strokeWidth: 0.1)
        }

        let artwork = Artwork(
            name: "part",
            size: CGSize(width: 288, height: 216),
            paths: [outline(CGRect(x: 20, y: 20, width: 120, height: 120), cyan),
                    outline(CGRect(x: 60, y: 60, width: 30, height: 30), cyan),
                    outline(CGRect(x: 200, y: 20, width: 40, height: 40), red)],
            source: .pathsOnly)

        var project = LaserProject(machine: .zing24, resolution: 500, jobName: "Preview")
        project.items = [PlacedArtwork(artwork: artwork)]
        project.synchronizeLayers()
        return project
    }

    /// Pen-up x coordinates from the real job, in order.
    private func penUps(_ data: Data) -> [Int] {
        var result: [Int] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count - 2 {
            if bytes[i] == UInt8(ascii: "P"), bytes[i + 1] == UInt8(ascii: "U") {
                var j = i + 2, value = 0, digits = false
                while j < bytes.count, bytes[j] >= 48, bytes[j] <= 57 {
                    value = value * 10 + Int(bytes[j] - 48); digits = true; j += 1
                }
                if digits { result.append(value) }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    func testPreviewMatchesTheJobItPreviews() throws {
        let project = makeProject()

        let job = try XCTUnwrap(JobBuilder.build(project: project))
        let preview = JobBuilder.preview(project: project)

        let jobStarts = penUps(job.data)
        let previewStarts = preview.moves.filter { !$0.cutting }.map { Int($0.to.x.rounded()) }

        XCTAssertEqual(jobStarts.count, previewStarts.count,
                       "the preview should show every repositioning the job makes")
        XCTAssertEqual(jobStarts, previewStarts,
                       "the preview must visit things in the same order as the job")
    }

    func testPreviewSeparatesCuttingFromTravelling() {
        let preview = JobBuilder.preview(project: makeProject())

        XCTAssertGreaterThan(preview.moves.filter(\.cutting).count, 0)
        XCTAssertGreaterThan(preview.moves.filter { !$0.cutting }.count, 0)
        XCTAssertGreaterThan(preview.cutLengthInches, 0)
        XCTAssertGreaterThan(preview.travelLengthInches, 0)

        // Three rectangles, four sides each, at 120, 30 and 40 points a side.
        let perimeterPoints: Double = (120 + 30 + 40) * 4
        XCTAssertEqual(preview.cutLengthInches, perimeterPoints / 72.0, accuracy: 0.05)
    }

    /// Scrubbing is by distance, not by segment count, or a flattened curve
    /// would take as long to scrub through as a two-foot straight line.
    func testScrubbingIsProportionalToDistance() {
        let preview = JobBuilder.preview(project: makeProject())
        XCTAssertGreaterThan(preview.totalLength, 0)

        XCTAssertEqual(preview.moveCount(upTo: 0), 1)
        XCTAssertEqual(preview.moveCount(upTo: 1), preview.moves.count)

        let half = preview.moveCount(upTo: 0.5)
        XCTAssertGreaterThan(half, 0)
        XCTAssertLessThanOrEqual(half, preview.moves.count)

        // The distance covered by halfway should actually be about half.
        let covered = preview.cumulativeLength[half - 1]
        XCTAssertEqual(Double(covered / preview.totalLength), 0.5, accuracy: 0.2)
    }

    func testEngravingIsReportedAsARegionPerSetting() {
        var project = makeProject()
        for i in project.layers.indices {
            project.layers[i].operation = .engrave
            project.layers[i].power = project.layers[i].target == .color(red) ? 80 : 40
            project.layers[i].speed = 100
        }

        let preview = JobBuilder.preview(project: project)
        XCTAssertEqual(preview.engraveRegions.count, 2,
                       "two different powers means two sweeps")
        XCTAssertTrue(preview.moves.isEmpty, "nothing is being cut")
        XCTAssertTrue(preview.engraveRegions.allSatisfy { $0.bounds.width > 0 })
    }

    // MARK: - Engraving

    /// A box round the extent tells you where the head goes, not what gets
    /// marked. The preview has to carry the artwork itself.
    func testEngraveRegionsCarryAPictureOfWhatWillBeMarked() throws {
        var project = makeProject()
        for i in project.layers.indices {
            project.layers[i].operation = .engrave
            project.layers[i].rendering = .solid
        }

        let preview = JobBuilder.preview(project: project)
        let region = try XCTUnwrap(preview.engraveRegions.first)
        let image = try XCTUnwrap(region.image, "the pass should render a picture")

        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(darkFraction(of: image), 0.0001,
                             "a blank picture would be no better than a bounding box")
        XCTAssertLessThan(darkFraction(of: image), 0.9,
                          "and it should not be a solid block either")
    }

    /// Somebody who turned on bottom-up engraving did so for a reason; a
    /// preview that always swept the other way would look like it had not taken.
    func testPreviewReportsTheSweepDirection() {
        var project = makeProject()
        for i in project.layers.indices { project.layers[i].operation = .engrave }

        XCTAssertFalse(JobBuilder.preview(project: project).engraveBottomUp)

        project.engraveBottomUp = true
        XCTAssertTrue(JobBuilder.preview(project: project).engraveBottomUp)
    }

    /// The picture is composed by the same code that builds the job, so a layer
    /// switched off has to disappear from it too.
    func testTurningALayerOffRemovesItFromThePicture() throws {
        var project = makeProject()
        for i in project.layers.indices {
            project.layers[i].operation = .engrave
            project.layers[i].rendering = .solid
        }

        let all = try XCTUnwrap(JobBuilder.preview(project: project)
            .engraveRegions.first?.image)

        for i in project.layers.indices where project.layers[i].target == .color(red) {
            project.layers[i].enabled = false
        }
        let fewer = try XCTUnwrap(JobBuilder.preview(project: project)
            .engraveRegions.first?.image)

        XCTAssertLessThan(darkFraction(of: fewer), darkFraction(of: all),
                          "switching a layer off should mark less material")
    }

    /// Fraction of pixels that are dark enough to count as marked.
    private func darkFraction(of image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)
        var dark = 0
        for i in 0..<(w * h) where pixels[i] < 128 { dark += 1 }
        return Double(dark) / Double(w * h)
    }

    func testDisabledLayersDoNotAppear() {
        var project = makeProject()
        for i in project.layers.indices { project.layers[i].enabled = false }

        let preview = JobBuilder.preview(project: project)
        XCTAssertTrue(preview.moves.isEmpty)
        XCTAssertTrue(preview.engraveRegions.isEmpty)
    }
}
