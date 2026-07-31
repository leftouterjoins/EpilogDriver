/*
 * AreaSelectionTests.swift - What a swept-out rectangle should catch
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class AreaSelectionTests: XCTestCase {

    /// Four 40pt squares in a row at x = 0, 100, 200, 300.
    private func makeProject() -> LaserProject {
        let art = Artwork(name: "part", size: CGSize(width: 40, height: 40),
                          paths: [ArtworkPath(path: CGPath(rect: CGRect(x: 0, y: 0,
                                                                        width: 40, height: 40),
                                                           transform: nil),
                                              stroke: .black, strokeWidth: 0.5)],
                          source: .pathsOnly)

        var project = LaserProject(machine: .zing24)
        project.items = (0..<4).map { index in
            PlacedArtwork(artwork: art,
                          origin: CGPoint(x: CGFloat(index) * 100, y: 0))
        }
        project.synchronizeLayers()
        return project
    }

    func testTouchingCountsAsCaught() {
        let project = makeProject()

        // A band across the row, overlapping the first two squares only partly.
        let caught = project.items(intersecting: CGRect(x: 20, y: 10,
                                                        width: 100, height: 10))
        XCTAssertEqual(caught.count, 2,
                       "a band that clips two squares should take both, not neither")
    }

    func testAnEmptyAreaCatchesNothing() {
        let project = makeProject()
        XCTAssertTrue(project.items(intersecting: CGRect(x: 500, y: 500,
                                                         width: 50, height: 50)).isEmpty)
    }

    func testSweepingEverythingTakesEverything() {
        let project = makeProject()
        XCTAssertEqual(project.items(intersecting: CGRect(x: -10, y: -10,
                                                          width: 400, height: 200)).count, 4)
    }

    /// You cannot see a hidden item, so you cannot have meant to select it.
    func testHiddenItemsAreLeftOut() {
        var project = makeProject()
        project.items[1].visible = false

        let caught = project.items(intersecting: CGRect(x: -10, y: -10,
                                                        width: 400, height: 200))
        XCTAssertEqual(caught.count, 3)
        XCTAssertFalse(caught.contains { $0.id == project.items[1].id })
    }

    /// A rectangle with no area still catches whatever it lies on, which is
    /// what makes a click that barely moves behave like a click.
    func testAZeroSizedAreaStillCatchesWhatItIsOver() {
        let project = makeProject()
        let caught = project.items(intersecting: CGRect(x: 20, y: 20, width: 0, height: 0))
        XCTAssertEqual(caught.count, 1)
    }

    /// Selection is by where things sit on the bed, so a scaled or moved item
    /// is caught where it appears rather than where its artwork starts.
    func testCatchesItemsWhereTheyActuallySit() {
        var project = makeProject()
        project.items[0].scale = 3          // 40pt becomes 120pt
        project.items[0].origin = CGPoint(x: 600, y: 600)

        XCTAssertTrue(project.items(intersecting: CGRect(x: 0, y: 0,
                                                         width: 50, height: 50))
            .allSatisfy { $0.id != project.items[0].id })

        let caught = project.items(intersecting: CGRect(x: 650, y: 650,
                                                        width: 10, height: 10))
        XCTAssertEqual(caught.count, 1)
        XCTAssertEqual(caught.first?.id, project.items[0].id)
    }
}
