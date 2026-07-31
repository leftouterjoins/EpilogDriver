/*
 * AppearanceHashTests.swift - What is allowed to force a re-render
 *
 * Previews are cached against appearanceHash. Fold a setting into it that does
 * not change the picture, and every keystroke in that field throws away every
 * rendered page and re-renders it - which is how typing a power value came to
 * take a second per character.
 *
 * So the rule is worth pinning down: only things you can see belong in here.
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class AppearanceHashTests: XCTestCase {

    private func makeProject() -> LaserProject {
        let art = Artwork(
            name: "art",
            size: CGSize(width: 200, height: 100),
            paths: [ArtworkPath(path: CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50),
                                             transform: nil),
                                stroke: ArtworkColor(r8: 0, g8: 255, b8: 255),
                                strokeWidth: 0.5),
                    ArtworkPath(path: CGPath(rect: CGRect(x: 80, y: 0, width: 50, height: 50),
                                             transform: nil),
                                fill: .black)],
            source: .pathsOnly)

        var project = LaserProject(machine: .zing24)
        project.items = [PlacedArtwork(artwork: art)]
        project.synchronizeLayers()
        return project
    }

    /// Settings that change the job but not the picture.
    func testCuttingSettingsDoNotForceARerender() {
        let original = makeProject()
        let before = original.appearanceHash

        for change in [
            { (p: inout LaserProject) in p.layers[0].power = 42 },
            { (p: inout LaserProject) in p.layers[0].speed = 7 },
            { (p: inout LaserProject) in p.layers[0].frequency = 1234 },
            { (p: inout LaserProject) in p.layers[0].passes = 3 },
            { (p: inout LaserProject) in p.layers[0].dither = .stucki },
            { (p: inout LaserProject) in p.layers[0].name = "renamed" },
        ] {
            var project = original
            change(&project)
            XCTAssertNotEqual(project.layers, original.layers, "the change did happen")
            XCTAssertEqual(project.appearanceHash, before,
                           "this setting does not change what the artwork looks like, "
                           + "so it must not discard the rendered preview")
        }
    }

    /// Settings that do change the picture.
    func testAppearanceSettingsDoForceARerender() {
        let original = makeProject()
        let before = original.appearanceHash

        for change in [
            { (p: inout LaserProject) in p.layers[0].operation = .engrave },
            { (p: inout LaserProject) in p.layers[0].rendering = .solid },
            { (p: inout LaserProject) in p.layers[0].visible = false },
            { (p: inout LaserProject) in p.layers[0].enabled = false },
        ] {
            var project = original
            change(&project)
            XCTAssertNotEqual(project.appearanceHash, before,
                              "this setting changes what you see, so the preview is stale")
        }
    }

    /// Moving artwork does not change how it is drawn, only where - the canvas
    /// applies the placement transform to a cached image.
    func testPlacementDoesNotForceARerender() {
        let original = makeProject()
        var moved = original
        moved.items[0].origin = CGPoint(x: 100, y: 50)
        XCTAssertEqual(moved.appearanceHash, original.appearanceHash)
    }

    /// Adding or removing a layer must be noticed.
    func testLayerSetChangesAreNoticed() {
        let original = makeProject()
        var fewer = original
        fewer.layers.removeLast()
        XCTAssertNotEqual(fewer.appearanceHash, original.appearanceHash)

        var reordered = original
        reordered.layers.reverse()
        XCTAssertNotEqual(reordered.appearanceHash, original.appearanceHash,
                          "order decides which layer draws over which")
    }
}
