/*
 * BackgroundShapeTests.swift - A white backdrop must not burn
 *
 * Plenty of documents carry a white rectangle behind the artwork, because
 * that is what a drawing program puts there when you set a canvas colour. It
 * is not artwork and it must never reach the laser: engraving a solid
 * bed-sized rectangle wastes an hour and ruins the material.
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class BackgroundShapeTests: XCTestCase {

    private func artwork(with paths: [ArtworkPath],
                         size: CGSize = CGSize(width: 288, height: 216)) -> Artwork {
        Artwork(name: "test", size: size, paths: paths, source: .pathsOnly)
    }

    private func filled(_ rect: CGRect, _ color: ArtworkColor) -> ArtworkPath {
        ArtworkPath(path: CGPath(rect: rect, transform: nil), fill: color)
    }

    // MARK: - Detection

    func testFullPageWhiteFillIsDroppedOnImport() {
        var art = artwork(with: [
            filled(CGRect(x: 0, y: 0, width: 288, height: 216), .white),
            filled(CGRect(x: 40, y: 40, width: 60, height: 60),
                   ArtworkColor(r: 0.1, g: 0.1, b: 0.1)),
        ])

        let removed = art.removeBackdropShapes()
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(art.paths.count, 1)
        XCTAssertEqual(art.paths[0].fill?.luma ?? 1, 0.1, accuracy: 0.01,
                       "the actual artwork must survive")
    }

    /// Off-white counts. Applications write "white" as #FEFEFE often enough.
    func testNearWhiteBackdropIsAlsoDropped() {
        var art = artwork(with: [
            filled(CGRect(x: 0, y: 0, width: 288, height: 216),
                   ArtworkColor(r8: 253, g8: 254, b8: 252)),
            filled(CGRect(x: 40, y: 40, width: 60, height: 60), .black),
        ])
        XCTAssertEqual(art.removeBackdropShapes(), 1)
        XCTAssertEqual(art.paths.count, 1)
    }

    /// A small white shape is a highlight, an eye, a cut-out - it is artwork.
    func testSmallWhiteShapesAreKept() {
        var art = artwork(with: [
            filled(CGRect(x: 40, y: 40, width: 30, height: 30), .white),
            filled(CGRect(x: 90, y: 40, width: 30, height: 30), .black),
        ])
        XCTAssertEqual(art.removeBackdropShapes(), 0)
        XCTAssertEqual(art.paths.count, 2)
    }

    /// A big shape in a real colour is the artwork, however large it is.
    func testLargeColouredShapesAreKept() {
        var art = artwork(with: [
            filled(CGRect(x: 0, y: 0, width: 288, height: 216),
                   ArtworkColor(r8: 0, g8: 255, b8: 255)),
        ])
        XCTAssertEqual(art.removeBackdropShapes(), 0)
        XCTAssertEqual(art.paths.count, 1)
    }

    /// An outline round the page is a cut, not a backdrop - the difference is
    /// whether it is filled.
    func testFullPageStrokeIsKept() {
        let outline = ArtworkPath(
            path: CGPath(rect: CGRect(x: 0, y: 0, width: 288, height: 216), transform: nil),
            stroke: .white, strokeWidth: 0.5)
        var art = artwork(with: [outline])
        XCTAssertEqual(art.removeBackdropShapes(), 0)
        XCTAssertEqual(art.paths.count, 1)
    }

    // MARK: - The consequence

    /// The bug this all exists to prevent: a white backdrop defaulting to a
    /// solid engrave and burning the whole sheet black.
    func testWhiteNeverDefaultsToASolidEngrave() {
        let layer = LaserLayer.makeDefault(for: .color(.white), material: nil, index: 0)
        XCTAssertEqual(layer.operation, .skip,
                       "white is a backdrop colour; burning it solid ruins the material")
        XCTAssertFalse(layer.contributes)
    }

    /// Pale but real tones still engrave, and engrave solid - a light grey
    /// shape is meant to be engraved, not left almost invisible.
    func testPaleTonesStillEngraveSolid() {
        let lightGrey = ArtworkColor(r: 0.85, g: 0.85, b: 0.85)
        let layer = LaserLayer.makeDefault(for: .color(lightGrey), material: nil, index: 0)
        XCTAssertEqual(layer.operation, .engrave)
        XCTAssertEqual(layer.rendering, .solid)
    }

    /// A pale *saturated* colour is still one of the six the workflow routes to
    /// the cutter. Washed-out yellow is yellow, and yellow means cut.
    func testPaleSaturatedColoursStillRouteToTheCutter() {
        let paleYellow = ArtworkColor(r: 1.0, g: 0.98, b: 0.6)
        XCTAssertFalse(paleYellow.isNearWhite)
        let layer = LaserLayer.makeDefault(for: .color(paleYellow), material: nil, index: 0)
        XCTAssertEqual(layer.operation, .cut)
    }

    /// End to end: a document with a white backdrop must not produce a
    /// bed-sized engraving.
    func testDocumentWithWhiteBackdropEngravesOnlyItsArtwork() throws {
        var art = artwork(with: [
            filled(CGRect(x: 0, y: 0, width: 288, height: 216), .white),
            filled(CGRect(x: 40, y: 40, width: 60, height: 60), .black),
        ])
        _ = art.removeBackdropShapes()

        var project = LaserProject(machine: .zing24, resolution: 500, jobName: "Backdrop")
        project.items = [PlacedArtwork(artwork: art)]
        project.synchronizeLayers()

        let job = try XCTUnwrap(JobBuilder.build(project: project))

        // The black square is 60x60pt; anything much larger means the backdrop
        // got engraved too.
        XCTAssertEqual(job.summary.bounds.width, 60.0 / 72.0, accuracy: 0.05)
        XCTAssertEqual(job.summary.bounds.height, 60.0 / 72.0, accuracy: 0.05)
    }
}
