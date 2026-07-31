/*
 * ArtworkSplitterTests.swift - Breaking a file into its separate objects
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class ArtworkSplitterTests: XCTestCase {

    private func square(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat = 40,
                        _ color: ArtworkColor = .black) -> ArtworkPath {
        ArtworkPath(path: CGPath(rect: CGRect(x: x, y: y, width: side, height: side),
                                 transform: nil),
                    stroke: color, strokeWidth: 0.5)
    }

    private func artwork(_ paths: [ArtworkPath],
                         size: CGSize = CGSize(width: 400, height: 200),
                         source: ArtworkSource = .pathsOnly) -> Artwork {
        Artwork(name: "sheet", size: size, paths: paths, source: source)
    }

    // MARK: - Clustering

    func testWellSeparatedShapesBecomeSeparateParts() {
        // Three squares in a row, 100pt apart: the bookmarks case.
        let art = artwork([square(0, 0), square(140, 0), square(280, 0)])
        XCTAssertEqual(art.partCount(mergingWithin: 7.2), 3)

        let parts = art.splitIntoParts(mergingWithin: 7.2)
        XCTAssertEqual(parts.count, 3)
        for (part, _) in parts {
            XCTAssertEqual(part.size.width, 40, accuracy: 1)
            XCTAssertEqual(part.paths.count, 1)
        }
    }

    func testTouchingShapesStayTogether() {
        // Two squares 2pt apart, merged at a 7.2pt gap.
        let art = artwork([square(0, 0), square(42, 0)])
        XCTAssertEqual(art.partCount(mergingWithin: 7.2), 1)
        XCTAssertTrue(art.splitIntoParts(mergingWithin: 7.2).isEmpty,
                      "one part is not a split")
    }

    /// A hole inside an outline must never be separated from the part it is in.
    func testHolesStayWithTheirOutline() {
        let outline = square(0, 0, 100)
        let hole = square(30, 30, 20)
        let other = square(200, 0, 40)

        let art = artwork([outline, hole, other])
        let parts = art.splitIntoParts(mergingWithin: 7.2)
        XCTAssertEqual(parts.count, 2)

        let withHole = parts.first { $0.artwork.paths.count == 2 }
        XCTAssertNotNil(withHole, "the outline and its hole belong to one part")
    }

    /// The gap is what decides, so widening it must merge and never split.
    func testWideningTheGapMergesParts() {
        let art = artwork([square(0, 0), square(60, 0), square(120, 0)])
        XCTAssertEqual(art.partCount(mergingWithin: 1), 3)
        XCTAssertEqual(art.partCount(mergingWithin: 25), 1)

        var previous = Int.max
        for gap in stride(from: CGFloat(1), through: 40, by: 3) {
            let count = art.partCount(mergingWithin: gap)
            XCTAssertLessThanOrEqual(count, previous, "a wider gap cannot mean more parts")
            previous = count
        }
    }

    // MARK: - Geometry

    /// A part must come back with its geometry at its own origin, and report
    /// where it sat, or reassembling the sheet would move everything.
    func testPartsReportWhereTheyCameFrom() throws {
        let art = artwork([square(0, 0), square(140, 20)])
        let parts = art.splitIntoParts(mergingWithin: 7.2)
        XCTAssertEqual(parts.count, 2)

        let second = try XCTUnwrap(parts.last)
        XCTAssertEqual(second.offset.x, 140, accuracy: 1)
        XCTAssertEqual(second.offset.y, 20, accuracy: 1)

        // Its own geometry starts at its own corner.
        let box = try XCTUnwrap(second.artwork.paths.first).path.boundingBox
        XCTAssertEqual(box.minX, 0, accuracy: 1)
        XCTAssertEqual(box.minY, 0, accuracy: 1)
    }

    /// Splitting must not change what will burn. Reassembled parts have to
    /// produce the same cut extent as the sheet they came from.
    func testSplittingDoesNotMoveTheArtwork() throws {
        let art = artwork([square(0, 0), square(140, 20), square(280, 40)])

        var whole = LaserProject(machine: .zing24, resolution: 500, jobName: "whole")
        whole.items = [PlacedArtwork(artwork: art, origin: CGPoint(x: 72, y: 72))]
        whole.synchronizeLayers()

        var split = LaserProject(machine: .zing24, resolution: 500, jobName: "split")
        split.items = art.splitIntoParts(mergingWithin: 7.2).map { part, offset in
            PlacedArtwork(artwork: part,
                          origin: CGPoint(x: 72 + offset.x, y: 72 + offset.y))
        }
        split.synchronizeLayers()

        let a = try XCTUnwrap(JobBuilder.build(project: whole)).summary
        let b = try XCTUnwrap(JobBuilder.build(project: split)).summary

        XCTAssertEqual(a.bounds.minX, b.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(a.bounds.minY, b.bounds.minY, accuracy: 0.01)
        XCTAssertEqual(a.bounds.width, b.bounds.width, accuracy: 0.01)
        XCTAssertEqual(a.bounds.height, b.bounds.height, accuracy: 0.01)
        XCTAssertEqual(a.cutLengthInches, b.cutLengthInches, accuracy: 0.02)
    }

    /// Every part of a split page carries the same page as its source, so each
    /// one has to be clipped to its own area - otherwise all three bookmarks
    /// engrave all three bookmarks' text.
    func testPartsOfAPageAreClippedToThemselves() {
        let art = artwork([square(0, 0), square(280, 0)],
                          source: .image(makeImage()))
        let parts = art.splitIntoParts(mergingWithin: 7.2)
        XCTAssertEqual(parts.count, 2)

        for (part, offset) in parts {
            let clip = part.sourceClip
            XCTAssertNotNil(clip, "a split part must not draw the whole page")
            XCTAssertEqual(clip?.width ?? 0, part.size.width, accuracy: 0.01)
            XCTAssertEqual(part.sourceTransform.tx, -offset.x, accuracy: 0.01,
                           "the page is shifted to line up with the part")
        }
    }

    func testSplittingAnEmptyOrSingleObjectDocumentDoesNothing() {
        XCTAssertTrue(artwork([]).splitIntoParts().isEmpty)
        XCTAssertTrue(artwork([square(0, 0)]).splitIntoParts().isEmpty)
    }

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }
}
