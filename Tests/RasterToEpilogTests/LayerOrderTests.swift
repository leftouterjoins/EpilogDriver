/*
 * LayerOrderTests.swift - Layer order is run order
 *
 * If someone puts the score layer above the cut layer, they mean the scoring
 * to happen first - the part is still held by its material at that point, and
 * doing it the other way round scores a piece that has already dropped. The
 * travel optimiser must not be allowed to quietly undo that decision.
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class LayerOrderTests: XCTestCase {

    private let red = ArtworkColor(r8: 255, g8: 0, b8: 0)
    private let blue = ArtworkColor(r8: 0, g8: 0, b8: 255)

    /// Two separated squares, one red and one blue, so their cut order is
    /// visible in the coordinates the job comes out with.
    private func makeProject() -> LaserProject {
        func square(_ rect: CGRect, _ color: ArtworkColor) -> ArtworkPath {
            ArtworkPath(path: CGPath(rect: rect, transform: nil),
                        stroke: color, strokeWidth: 0.1)
        }

        let artwork = Artwork(
            name: "two squares",
            size: CGSize(width: 288, height: 144),
            paths: [square(CGRect(x: 20, y: 20, width: 40, height: 40), red),
                    square(CGRect(x: 200, y: 20, width: 40, height: 40), blue)],
            source: .pathsOnly)

        var project = LaserProject(machine: .zing24, resolution: 500, jobName: "Order")
        project.items = [PlacedArtwork(artwork: artwork)]
        project.synchronizeLayers()
        return project
    }

    /// The x coordinate of each pen-up move, in the order the job issues them.
    private func penUpOrder(_ job: LaserJob) -> [Int] {
        var result: [Int] = []
        let bytes = [UInt8](job.data)
        var i = 0
        while i < bytes.count - 2 {
            if bytes[i] == UInt8(ascii: "P"), bytes[i + 1] == UInt8(ascii: "U") {
                var j = i + 2
                var value = 0
                var digits = false
                while j < bytes.count, bytes[j] >= 48, bytes[j] <= 57 {
                    value = value * 10 + Int(bytes[j] - 48)
                    digits = true
                    j += 1
                }
                if digits { result.append(value) }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    func testLayersCutInTheOrderTheyAreListed() throws {
        var project = makeProject()

        // Put red first.
        project.layers.sort { a, _ in a.target == .color(red) }
        let redFirst = try XCTUnwrap(JobBuilder.build(project: project))
        let redOrder = penUpOrder(redFirst)
        XCTAssertGreaterThanOrEqual(redOrder.count, 2)

        // Now blue first. Same artwork, same settings, reversed list.
        project.layers.reverse()
        let blueFirst = try XCTUnwrap(JobBuilder.build(project: project))
        let blueOrder = penUpOrder(blueFirst)
        XCTAssertGreaterThanOrEqual(blueOrder.count, 2)

        // Red sits at x=20pt, blue at x=200pt, so the first pen-up says which
        // layer ran first without having to decode the whole stream.
        XCTAssertLessThan(redOrder[0], blueOrder[0],
                          "the layer listed first should be cut first")
    }

    /// Sorting is allowed to reorder inside a layer, never across layers.
    func testSortingDoesNotReorderAcrossLayers() throws {
        var project = makeProject()
        project.layers.sort { a, _ in a.target == .color(red) }
        project.vectorSorting = true

        let job = try XCTUnwrap(JobBuilder.build(project: project))
        let order = penUpOrder(job)

        // Everything belonging to the red layer (x near 20pt) must come before
        // anything belonging to blue (x near 200pt).
        let boundary = 500 * 100 / 72   // halfway across, in device pixels
        let firstBlue = order.firstIndex { $0 > boundary }
        let lastRed = order.lastIndex { $0 < boundary }
        if let firstBlue, let lastRed {
            XCTAssertLessThan(lastRed, firstBlue,
                              "travel optimisation must stay inside a layer")
        }
    }

    func testScoreAndCutAreBothEmittedWithTheirOwnSettings() throws {
        var project = makeProject()
        for i in project.layers.indices {
            if project.layers[i].target == .color(red) {
                project.layers[i].operation = .score
                project.layers[i].power = 20
                project.layers[i].speed = 60
            } else {
                project.layers[i].operation = .cut
                project.layers[i].power = 100
                project.layers[i].speed = 15
            }
        }

        let job = try XCTUnwrap(JobBuilder.build(project: project))
        let text = String(decoding: job.data, as: UTF8.self)
        XCTAssertTrue(text.contains("YP020;"), "the score layer's power")
        XCTAssertTrue(text.contains("ZS060;"), "the score layer's speed")
        XCTAssertTrue(text.contains("YP100;"), "the cut layer's power")
        XCTAssertTrue(text.contains("ZS015;"), "the cut layer's speed")
    }

    // MARK: - Undo bookkeeping

    /// Undo keeps snapshots of the project; a snapshot that changes nothing is
    /// an undo step that appears to do nothing when applied.
    func testDiffersIgnoresUnchangedProjects() {
        let project = makeProject()
        XCTAssertFalse(project.differs(from: project))

        var moved = project
        moved.items[0].origin.x += 1
        XCTAssertTrue(moved.differs(from: project))

        var relabelled = project
        relabelled.layers[0].power = 42
        XCTAssertTrue(relabelled.differs(from: project))

        var renamed = project
        renamed.jobName = "something else"
        XCTAssertTrue(renamed.differs(from: project))

        var rescaled = project
        rescaled.resolution = 1000
        XCTAssertTrue(rescaled.differs(from: project))
    }

    /// Re-running the layer sync must not read as a change, or every reimport
    /// would leave a useless entry on the undo stack.
    func testSynchronizingLayersIsNotAChange() {
        var project = makeProject()
        let before = project
        project.synchronizeLayers()
        XCTAssertFalse(project.differs(from: before))
    }
}
