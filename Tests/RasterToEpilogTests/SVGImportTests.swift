/*
 * SVGImportTests.swift - The path grammar is where SVG importers go wrong
 *
 * SVG path data is not whitespace-delimited ("M10-20.5.3" is three numbers),
 * arc flags run together with the coordinates that follow them, and the
 * shorthand curve commands depend on the previous command's control point.
 * Each of those has its own test because each of them silently produces
 * plausible-looking, wrong geometry.
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class SVGImportTests: XCTestCase {

    private func load(_ svg: String) throws -> Artwork {
        try SVGArtworkImporter.importArtwork(from: Data(svg.utf8), name: "test")
    }

    // MARK: - Document setup

    func testViewBoxMapsOntoDeclaredSize() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 72 72">
              <rect x="0" y="0" width="36" height="36" fill="black"/>
            </svg>
            """)
        XCTAssertEqual(artwork.size.width, 144, accuracy: 0.01)
        // The viewBox is half the canvas, so the rect doubles on the way in.
        let box = try XCTUnwrap(artwork.paths.first).path.boundingBox
        XCTAssertEqual(box.width, 72, accuracy: 0.01)
        XCTAssertEqual(box.height, 72, accuracy: 0.01)
    }

    func testMillimetreWidthsBecomePoints() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="25.4mm" height="25.4mm">
              <rect x="0" y="0" width="10" height="10"/>
            </svg>
            """)
        XCTAssertEqual(artwork.size.width, 72, accuracy: 0.01, "25.4mm is one inch")
    }

    // MARK: - Colours

    func testColorFormsAndCutColorSnapping() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <rect x="0" y="0" width="10" height="10" fill="#0ff"/>
              <rect x="20" y="0" width="10" height="10" fill="rgb(255,0,0)"/>
              <rect x="40" y="0" width="10" height="10" fill="magenta"/>
              <rect x="60" y="0" width="10" height="10" fill="none" stroke="#00FFFF"/>
            </svg>
            """)
        let colors = Set(artwork.distinctColors)
        XCTAssertTrue(colors.contains(ArtworkColor(r8: 0, g8: 255, b8: 255)), "#0ff shorthand")
        XCTAssertTrue(colors.contains(ArtworkColor(r8: 255, g8: 0, b8: 0)), "rgb() form")
        XCTAssertTrue(colors.contains(ArtworkColor(r8: 255, g8: 0, b8: 255)), "named colour")
        XCTAssertEqual(artwork.paths.count, 4)
    }

    func testFillNoneIsNotPainted() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <rect x="0" y="0" width="10" height="10" fill="none"/>
              <rect x="20" y="0" width="10" height="10" fill="none" stroke="red"/>
            </svg>
            """)
        XCTAssertEqual(artwork.paths.count, 1, "a shape with no fill and no stroke draws nothing")
        XCTAssertNil(artwork.paths[0].fill)
        XCTAssertNotNil(artwork.paths[0].stroke)
    }

    func testStyleAttributeOverridesPresentationAttribute() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <rect x="0" y="0" width="10" height="10" fill="black" style="fill:#00ffff"/>
            </svg>
            """)
        XCTAssertEqual(artwork.paths.first?.keyColor, ArtworkColor(r8: 0, g8: 255, b8: 255))
    }

    func testDefsContentIsNotDrawn() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <defs><rect x="0" y="0" width="10" height="10" fill="red"/></defs>
              <rect x="20" y="0" width="10" height="10" fill="black"/>
            </svg>
            """)
        XCTAssertEqual(artwork.paths.count, 1, "a template in <defs> is not artwork")
    }

    // MARK: - Transforms

    func testNestedTransformsCompose() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
              <g transform="translate(50,50)">
                <g transform="scale(2)">
                  <rect x="0" y="0" width="10" height="10" fill="black"/>
                </g>
              </g>
            </svg>
            """)
        let box = try XCTUnwrap(artwork.paths.first).path.boundingBox
        XCTAssertEqual(box.minX, 50, accuracy: 0.01)
        XCTAssertEqual(box.minY, 50, accuracy: 0.01)
        XCTAssertEqual(box.width, 20, accuracy: 0.01, "scale applies inside the translate")
    }

    func testRotateAboutAPoint() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
              <rect x="90" y="90" width="20" height="20" fill="black"
                    transform="rotate(90,100,100)"/>
            </svg>
            """)
        // A square centred on the point it turns about lands back on itself.
        let box = try XCTUnwrap(artwork.paths.first).path.boundingBox
        XCTAssertEqual(box.minX, 90, accuracy: 0.01)
        XCTAssertEqual(box.minY, 90, accuracy: 0.01)
        XCTAssertEqual(box.width, 20, accuracy: 0.01)
    }

    func testStrokeWidthScalesWithTheTransform() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
              <g transform="scale(4)">
                <line x1="0" y1="0" x2="10" y2="0" stroke="black" stroke-width="2"/>
              </g>
            </svg>
            """)
        XCTAssertEqual(try XCTUnwrap(artwork.paths.first).strokeWidth, 8, accuracy: 0.01)
    }

    // MARK: - Path data

    func testCompactNumberRunsParse() throws {
        // No separators anywhere: "M10-20.5.3" is 10, -20.5, then .3 begins
        // the implicit lineto that follows a moveto.
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <path d="M10-20.5.3-4Z" fill="black"/>
            </svg>
            """)
        let box = try XCTUnwrap(artwork.paths.first).path.boundingBox
        XCTAssertEqual(box.minX, 0.3, accuracy: 0.001)
        XCTAssertEqual(box.maxX, 10, accuracy: 0.001)
        XCTAssertEqual(box.minY, -20.5, accuracy: 0.001)
        XCTAssertEqual(box.maxY, -4, accuracy: 0.001)
    }

    func testRepeatedMoveToOperandsBecomeLines() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <path d="M0 0 10 0 10 10" stroke="black" fill="none"/>
            </svg>
            """)
        let box = try XCTUnwrap(artwork.paths.first).path.boundingBox
        XCTAssertEqual(box.width, 10, accuracy: 0.001)
        XCTAssertEqual(box.height, 10, accuracy: 0.001)
    }

    func testRelativeCommandsAccumulate() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <path d="M10 10 l10 0 l0 10 l-10 0 z" fill="black"/>
            </svg>
            """)
        let box = try XCTUnwrap(artwork.paths.first).path.boundingBox
        XCTAssertEqual(box.minX, 10, accuracy: 0.001)
        XCTAssertEqual(box.minY, 10, accuracy: 0.001)
        XCTAssertEqual(box.width, 10, accuracy: 0.001)
        XCTAssertEqual(box.height, 10, accuracy: 0.001)
    }

    func testHorizontalAndVerticalShorthand() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <path d="M5 5 H25 V35 H5 Z" fill="black"/>
            </svg>
            """)
        let box = try XCTUnwrap(artwork.paths.first).path.boundingBox
        XCTAssertEqual(box, CGRect(x: 5, y: 5, width: 20, height: 30))
    }

    /// Arc flags are single characters and need not be separated from what
    /// follows them: "a5 5 0 011 1" packs largeArc=0, sweep=1, then x=1, y=1.
    func testArcFlagsPackedAgainstCoordinates() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <path d="M10 10a5 5 0 0110 0" stroke="black" fill="none"/>
            </svg>
            """)
        let path = try XCTUnwrap(artwork.paths.first).path
        let box = path.boundingBox
        XCTAssertEqual(box.minX, 10, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 20, accuracy: 0.01, "the arc ends 10 units to the right")
        XCTAssertGreaterThan(box.height, 3, "a half-circle of radius 5 bulges about 5")
    }

    func testArcSweepDirection() throws {
        // Same endpoints, opposite sweep: one bulges up, the other down.
        let up = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <path d="M10 50 A20 20 0 0 1 50 50" stroke="black" fill="none"/>
            </svg>
            """)
        let down = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <path d="M10 50 A20 20 0 0 0 50 50" stroke="black" fill="none"/>
            </svg>
            """)
        let upBox = try XCTUnwrap(up.paths.first).path.boundingBox
        let downBox = try XCTUnwrap(down.paths.first).path.boundingBox
        XCTAssertLessThan(upBox.minY, 49.9, "sweep=1 arcs one way")
        XCTAssertGreaterThan(downBox.maxY, 50.1, "sweep=0 arcs the other")
    }

    func testSmoothCurveReflectsThePreviousControlPoint() throws {
        // The S command's first control point mirrors C's second one. Getting
        // that wrong yields a visibly kinked curve with a plausible bounding box,
        // so check the reflected control actually pulls the curve upward.
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <path d="M0 50 C0 0 50 0 50 50 S100 100 100 50" stroke="black" fill="none"/>
            </svg>
            """)
        let box = try XCTUnwrap(artwork.paths.first).path.boundingBox
        XCTAssertLessThan(box.minY, 20, "the first curve rises")
        XCTAssertGreaterThan(box.maxY, 80, "the reflected control sends the second one down")
    }

    // MARK: - Shapes

    func testBasicShapesAllImport() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
              <rect x="0" y="0" width="10" height="10" fill="black"/>
              <rect x="20" y="0" width="10" height="10" rx="2" fill="black"/>
              <circle cx="50" cy="50" r="10" fill="black"/>
              <ellipse cx="80" cy="50" rx="10" ry="5" fill="black"/>
              <line x1="0" y1="100" x2="10" y2="100" stroke="black"/>
              <polyline points="0,120 10,120 10,130" stroke="black" fill="none"/>
              <polygon points="0,150 10,150 10,160" fill="black"/>
            </svg>
            """)
        XCTAssertEqual(artwork.paths.count, 7)
    }

    func testMalformedSVGReportsRatherThanCrashes() {
        XCTAssertThrowsError(try load("<svg><rect"))
        XCTAssertThrowsError(try load("not xml at all"))
    }

    /// An SVG is all paths, so it needs no background layer - and offering one
    /// would just be a control that does nothing.
    func testSVGProjectHasNoBackgroundLayer() throws {
        let artwork = try load("""
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
              <rect x="0" y="0" width="10" height="10" fill="black"/>
            </svg>
            """)
        var project = LaserProject(machine: .zing24)
        project.items = [PlacedArtwork(artwork: artwork)]
        project.synchronizeLayers()
        XCTAssertFalse(project.layers.contains { $0.target == .background })
        XCTAssertEqual(project.layers.count, 1)
    }
}
