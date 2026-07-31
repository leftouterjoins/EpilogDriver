/*
 * Viewport.swift - Where the bed sits on screen
 *
 * Bed points to screen points is one scale and one offset, which sounds too
 * simple to get wrong until you fit something that does not start at the
 * origin. Zooming to a selection in the far corner of the bed has to put *that*
 * in the middle of the window, not the bed's top-left corner, and the two
 * differ by an offset it is easy to leave out.
 */

import Foundation
import CoreGraphics

public struct Viewport: Equatable {
    /// Screen points per bed point.
    public var zoom: CGFloat
    /// Screen-point offset of the bed's origin.
    public var pan: CGSize

    public init(zoom: CGFloat = 1, pan: CGSize = .zero) {
        self.zoom = zoom
        self.pan = pan
    }

    public static let minimumZoom: CGFloat = 0.05
    public static let maximumZoom: CGFloat = 16

    public func bedToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.width, y: p.y * zoom + pan.height)
    }

    public func viewToBed(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    /// Fit `box` into a window of `size`, centred.
    ///
    /// `inset` is room to leave: the margin around the artwork plus whatever
    /// the rulers occupy.
    public static func fitting(_ box: CGRect, in size: CGSize,
                               inset: CGFloat = 0) -> Viewport? {
        guard size.width > inset, size.height > inset,
              box.width > 0, box.height > 0 else { return nil }

        let usable = CGSize(width: size.width - inset, height: size.height - inset)
        let scale = min(usable.width / box.width, usable.height / box.height)
        let zoom = max(minimumZoom, min(scale, maximumZoom))

        // Centre the box, not the bed: the two are the same only when the box
        // starts at the origin, which is exactly the case that hides the bug.
        return Viewport(zoom: zoom,
                        pan: CGSize(width: (size.width - box.width * zoom) / 2 - box.minX * zoom,
                                    height: (size.height - box.height * zoom) / 2 - box.minY * zoom))
    }

    /// Change magnification while holding one screen point still.
    public func zoomed(to newZoom: CGFloat, holding viewPoint: CGPoint) -> Viewport {
        let anchor = viewToBed(viewPoint)
        let clamped = max(Self.minimumZoom, min(newZoom, Self.maximumZoom))
        return Viewport(zoom: clamped,
                        pan: CGSize(width: viewPoint.x - anchor.x * clamped,
                                    height: viewPoint.y - anchor.y * clamped))
    }

    /// Change magnification about the middle of the window.
    public func zoomed(to newZoom: CGFloat, in size: CGSize) -> Viewport {
        guard size.width > 0, size.height > 0 else {
            var copy = self
            copy.zoom = max(Self.minimumZoom, min(newZoom, Self.maximumZoom))
            return copy
        }
        return zoomed(to: newZoom,
                      holding: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}
