/*
 * ViewportTests.swift - Fitting things into a window
 *
 * The case that hides the bug is fitting a box that starts at the origin,
 * because then centring the box and centring the bed are the same thing. Zoom
 * to a selection in the far corner and they are not.
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class ViewportTests: XCTestCase {

    private let window = CGSize(width: 1000, height: 600)

    func testFittingCentresTheBox() throws {
        let box = CGRect(x: 0, y: 0, width: 1728, height: 864)   // a 24x12" bed
        let viewport = try XCTUnwrap(Viewport.fitting(box, in: window))

        // Width is the tighter constraint: 1000/1728 is 0.579, 600/864 is 0.694.
        XCTAssertEqual(viewport.zoom, 1000.0 / 1728.0, accuracy: 0.0001)

        let corner = viewport.bedToView(CGPoint(x: box.midX, y: box.midY))
        XCTAssertEqual(corner.x, window.width / 2, accuracy: 0.01)
        XCTAssertEqual(corner.y, window.height / 2, accuracy: 0.01)
    }

    /// Zoom to selection: the box is nowhere near the origin, and it is the box
    /// that has to end up in the middle.
    func testFittingAnOffsetBoxCentresTheBoxNotTheOrigin() throws {
        let box = CGRect(x: 1200, y: 700, width: 200, height: 100)
        let viewport = try XCTUnwrap(Viewport.fitting(box, in: window))

        let centre = viewport.bedToView(CGPoint(x: box.midX, y: box.midY))
        XCTAssertEqual(centre.x, window.width / 2, accuracy: 0.01)
        XCTAssertEqual(centre.y, window.height / 2, accuracy: 0.01)

        // And the whole box is on screen.
        let topLeft = viewport.bedToView(CGPoint(x: box.minX, y: box.minY))
        let bottomRight = viewport.bedToView(CGPoint(x: box.maxX, y: box.maxY))
        XCTAssertGreaterThanOrEqual(topLeft.x, -0.01)
        XCTAssertGreaterThanOrEqual(topLeft.y, -0.01)
        XCTAssertLessThanOrEqual(bottomRight.x, window.width + 0.01)
        XCTAssertLessThanOrEqual(bottomRight.y, window.height + 0.01)
    }

    func testFittingLeavesTheRequestedInset() throws {
        let box = CGRect(x: 0, y: 0, width: 1728, height: 864)
        let inset: CGFloat = 70
        let viewport = try XCTUnwrap(Viewport.fitting(box, in: window, inset: inset))

        let width = box.width * viewport.zoom
        let height = box.height * viewport.zoom
        XCTAssertLessThanOrEqual(width, window.width - inset + 0.01)
        XCTAssertLessThanOrEqual(height, window.height - inset + 0.01)
    }

    func testFittingRefusesImpossibleRequests() {
        XCTAssertNil(Viewport.fitting(.zero, in: window))
        XCTAssertNil(Viewport.fitting(CGRect(x: 0, y: 0, width: 100, height: 100),
                                      in: .zero))
        XCTAssertNil(Viewport.fitting(CGRect(x: 0, y: 0, width: 100, height: 100),
                                      in: CGSize(width: 40, height: 40), inset: 60))
    }

    func testRoundTripBetweenBedAndScreen() {
        let viewport = Viewport(zoom: 0.37, pan: CGSize(width: 120, height: -45))
        for p in [CGPoint.zero, CGPoint(x: 1728, y: 864), CGPoint(x: 33.3, y: 912.7)] {
            let back = viewport.viewToBed(viewport.bedToView(p))
            XCTAssertEqual(back.x, p.x, accuracy: 0.0001)
            XCTAssertEqual(back.y, p.y, accuracy: 0.0001)
        }
    }

    /// Zooming under the pointer is what makes a canvas feel precise: whatever
    /// is beneath the cursor must not move.
    func testZoomingHoldsThePointerStill() {
        let viewport = Viewport(zoom: 0.5, pan: CGSize(width: 30, height: 20))
        let pointer = CGPoint(x: 640, y: 210)
        let under = viewport.viewToBed(pointer)

        for factor in [1.25, 0.8, 4.0, 0.1] {
            let zoomed = viewport.zoomed(to: viewport.zoom * CGFloat(factor),
                                         holding: pointer)
            let after = zoomed.bedToView(under)
            XCTAssertEqual(after.x, pointer.x, accuracy: 0.01)
            XCTAssertEqual(after.y, pointer.y, accuracy: 0.01)
        }
    }

    func testZoomingAboutTheCentreHoldsTheCentreStill() {
        let viewport = Viewport(zoom: 0.5, pan: CGSize(width: 30, height: 20))
        let centre = CGPoint(x: window.width / 2, y: window.height / 2)
        let under = viewport.viewToBed(centre)

        let zoomed = viewport.zoomed(to: 1, in: window)
        let after = zoomed.bedToView(under)
        XCTAssertEqual(after.x, centre.x, accuracy: 0.01)
        XCTAssertEqual(after.y, centre.y, accuracy: 0.01)
    }

    func testZoomIsClamped() {
        let viewport = Viewport(zoom: 1, pan: .zero)
        XCTAssertEqual(viewport.zoomed(to: 1000, in: window).zoom, Viewport.maximumZoom)
        XCTAssertEqual(viewport.zoomed(to: 0.0001, in: window).zoom, Viewport.minimumZoom)

        // A bed far bigger than the window still cannot go below the floor.
        let huge = CGRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000)
        XCTAssertEqual(Viewport.fitting(huge, in: window)?.zoom, Viewport.minimumZoom)
    }
}
