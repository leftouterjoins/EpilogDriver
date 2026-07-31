/*
 * BedCanvasView.swift - The bed, drawn to scale, with the artwork on it
 *
 * Everything on screen is in bed points (72 to the inch, origin top-left,
 * y down), which is the same space the laser works in. Nothing is flipped or
 * offset on the way to the machine, so where something appears here is where
 * the head goes.
 *
 * Drawing is SwiftUI; input is AppKit. SwiftUI on macOS 12 has no scroll or
 * magnify event and no hover, and this has to keep running on the same
 * machines the CUPS driver does. One NSView over the canvas handles the
 * pointer and hands back plain callbacks.
 */

import SwiftUI
import AppKit
import CoreGraphics
import EpilogKit

struct BedCanvasView: View {
    @EnvironmentObject var model: AppModel

    @StateObject private var cache = ObservableCache()

    /// Where each dragged item started, so a gesture applies relative to its
    /// beginning rather than accumulating rounding error frame by frame.
    @State private var dragOrigin: [UUID: CGPoint] = [:]
    @State private var dragStartScale: CGFloat = 1
    @State private var dragMode: DragMode = .none
    @State private var panStart: CGSize = .zero
    @State private var dragStartPoint: CGPoint = .zero

    @State private var hoverBedPoint: CGPoint?
    @State private var hasSized = false

    private enum DragMode {
        case none, move, pan, rubberBand
        case scale(anchor: CGPoint, startDistance: CGFloat)
    }

    /// Live rubber band, in view coordinates.
    @State private var bandRect: CGRect?
    /// What was selected when the band started, so shift-dragging adds to it.
    @State private var selectionBeforeBand: Set<UUID> = []

    private var rulerThickness: CGFloat { AppModel.rulerThickness }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                canvas
                if model.showRulers { rulers(size: geometry.size) }
                readout
                events
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onAppear {
                model.canvasSize = geometry.size
                if !hasSized, geometry.size.width > 40 {
                    model.zoomToFit()
                    hasSized = true
                }
            }
            .onChange(of: geometry.size) { newSize in
                model.canvasSize = newSize
                if !hasSized, newSize.width > 40 {
                    model.zoomToFit()
                    hasSized = true
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    // MARK: - Drawing

    private var canvas: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let bed = model.project.bedSize
            let t = viewTransform

            // What is actually on screen, in bed points. Split a sheet into
            // fifty parts and zoom in on one, and there is no reason to render
            // the other forty-nine.
            let visible = CGRect(origin: viewToBed(.zero),
                                 size: CGSize(width: size.width / model.zoom,
                                              height: size.height / model.zoom))
                .insetBy(dx: -8 / model.zoom, dy: -8 / model.zoom)

            let bedRect = CGRect(origin: .zero, size: bed).applying(t)
            context.fill(Path(roundedRect: bedRect, cornerRadius: 2),
                         with: .color(Color(nsColor: .textBackgroundColor)))
            context.stroke(Path(roundedRect: bedRect, cornerRadius: 2),
                           with: .color(.secondary.opacity(0.6)), lineWidth: 1)

            if model.showGrid { drawGrid(&context, bedRect: bedRect) }
            drawMaterial(&context, transform: t)
            drawOriginMarker(&context, bedRect: bedRect)

            for item in model.project.items
            where item.visible && item.boundsOnBed.intersects(visible) {
                drawItem(item, in: &context, transform: t)
            }
            for item in model.project.items
            where model.selection.contains(item.id) && item.boundsOnBed.intersects(visible) {
                drawSelection(item, in: &context, transform: t)
            }

            if let band = bandRect, band.width > 1 || band.height > 1 {
                context.fill(Path(band), with: .color(.accentColor.opacity(0.12)))
                context.stroke(Path(band), with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
    }

    private func drawGrid(_ context: inout GraphicsContext, bedRect: CGRect) {
        let bed = model.project.bedSize
        // One inch always; quarter inches once there is room to tell them apart.
        var steps: [(spacing: CGFloat, opacity: Double)] = [(72, 0.22)]
        if model.zoom * 18 > 9 { steps.insert((18, 0.08), at: 0) }

        for (spacing, opacity) in steps {
            var path = Path()
            var x: CGFloat = 0
            while x <= bed.width + 0.01 {
                let vx = bedToView(CGPoint(x: x, y: 0)).x
                path.move(to: CGPoint(x: vx, y: bedRect.minY))
                path.addLine(to: CGPoint(x: vx, y: bedRect.maxY))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= bed.height + 0.01 {
                let vy = bedToView(CGPoint(x: 0, y: y)).y
                path.move(to: CGPoint(x: bedRect.minX, y: vy))
                path.addLine(to: CGPoint(x: bedRect.maxX, y: vy))
                y += spacing
            }
            context.stroke(path, with: .color(.secondary.opacity(opacity)), lineWidth: 0.5)
        }
    }

    /// The stock outline, when the operator has said how big their material is.
    private func drawMaterial(_ context: inout GraphicsContext, transform: CGAffineTransform) {
        let piece = model.project.pieceSize
        guard piece.width > 0, piece.height > 0 else { return }
        let rect = CGRect(origin: .zero, size: piece).applying(transform)
        context.fill(Path(rect), with: .color(.orange.opacity(0.06)))
        context.stroke(Path(rect), with: .color(.orange.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
    }

    /// The Epilog homes to the top-left and every coordinate in the job is
    /// measured from there. Showing it heads off the "why is my engraving in
    /// the wrong corner" confusion before it starts.
    private func drawOriginMarker(_ context: inout GraphicsContext, bedRect: CGRect) {
        var path = Path()
        path.move(to: CGPoint(x: bedRect.minX, y: bedRect.minY + 14))
        path.addLine(to: CGPoint(x: bedRect.minX, y: bedRect.minY))
        path.addLine(to: CGPoint(x: bedRect.minX + 14, y: bedRect.minY))
        context.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
    }

    private func drawItem(_ item: PlacedArtwork, in context: inout GraphicsContext,
                          transform: CGAffineTransform) {
        let combined = item.transform.concatenating(transform)

        cache.storage.generation = model.previewGeneration
        if let image = cache.storage.image(for: item, project: model.project,
                                           pixelsPerPoint: max(model.zoom * item.scale, 0.05)) {
            var layer = context
            layer.transform = combined
            layer.draw(Image(decorative: image, scale: 1),
                       in: CGRect(origin: .zero, size: item.artwork.size))
        } else {
            // Nothing renderable: show the footprint so it can still be moved.
            let rect = CGRect(origin: .zero, size: item.artwork.size).applying(combined)
            context.stroke(Path(rect), with: .color(.secondary), lineWidth: 1)
        }
    }

    private func drawSelection(_ item: PlacedArtwork, in context: inout GraphicsContext,
                               transform: CGAffineTransform) {
        let box = item.boundsOnBed.applying(transform)
        context.stroke(Path(box), with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

        // Corner handles, only when one thing is selected: scaling several at
        // once from a shared box is a different feature with different rules.
        guard model.selection.count == 1 else { return }
        for corner in corners(of: box) {
            let dot = CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(.white))
            context.stroke(Path(ellipseIn: dot), with: .color(.accentColor), lineWidth: 1.5)
        }
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    // MARK: - Rulers

    private func rulers(size: CGSize) -> some View {
        Canvas { context, _ in
            let bed = model.project.bedSize
            let bg = Color(nsColor: .windowBackgroundColor)

            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: rulerThickness)),
                         with: .color(bg))
            context.fill(Path(CGRect(x: 0, y: 0, width: rulerThickness, height: size.height)),
                         with: .color(bg))

            // Label every inch while they are far enough apart to read, then
            // every two, then every six.
            let spacingOnScreen = model.zoom * 72
            let step: CGFloat = spacingOnScreen > 34 ? 1 : (spacingOnScreen > 14 ? 2 : 6)

            var inch: CGFloat = 0
            while inch <= bed.width / 72 + 0.001 {
                let x = bedToView(CGPoint(x: inch * 72, y: 0)).x
                if x > rulerThickness, x < size.width {
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: rulerThickness - 5))
                    tick.addLine(to: CGPoint(x: x, y: rulerThickness))
                    context.stroke(tick, with: .color(.secondary), lineWidth: 0.75)
                    context.draw(Text("\(Int(inch))").font(.system(size: 9))
                                    .foregroundColor(.secondary),
                                 at: CGPoint(x: x + 8, y: rulerThickness / 2))
                }
                inch += step
            }

            inch = 0
            while inch <= bed.height / 72 + 0.001 {
                let y = bedToView(CGPoint(x: 0, y: inch * 72)).y
                if y > rulerThickness, y < size.height {
                    var tick = Path()
                    tick.move(to: CGPoint(x: rulerThickness - 5, y: y))
                    tick.addLine(to: CGPoint(x: rulerThickness, y: y))
                    context.stroke(tick, with: .color(.secondary), lineWidth: 0.75)
                    context.draw(Text("\(Int(inch))").font(.system(size: 9))
                                    .foregroundColor(.secondary),
                                 at: CGPoint(x: rulerThickness / 2, y: y + 9))
                }
                inch += step
            }

            context.fill(Path(CGRect(x: 0, y: 0, width: rulerThickness,
                                     height: rulerThickness)), with: .color(bg))
        }
        .allowsHitTesting(false)
    }

    /// Where the pointer is, in inches from the bed's top-left corner.
    private var readout: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let p = hoverBedPoint {
                    Text(String(format: "%.3f\", %.3f\"", p.x / 72, p.y / 72))
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .allowsHitTesting(false)
                }
                HStack(spacing: 2) {
                    Button { model.zoomOut() } label: {
                        Image(systemName: "minus").frame(width: 14)
                    }
                    Button { model.zoomToActualSize() } label: {
                        Text("\(Int((model.zoom * 100).rounded()))%")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 42)
                    }
                    .help("Back to 100%")
                    Button { model.zoomIn() } label: {
                        Image(systemName: "plus").frame(width: 14)
                    }
                    Divider().frame(height: 12)
                    Button { model.zoomToFit() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 16)
                    }
                    .help("Fit the bed in the window")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(8)
        }
    }

    // MARK: - Input

    private var events: some View {
        CanvasEventView(
            onHover: { hoverBedPoint = $0.map(viewToBed) },
            onScroll: { delta in
                model.pan = CGSize(width: model.pan.width + delta.width,
                                   height: model.pan.height + delta.height)
            },
            onZoom: { factor, at in zoom(by: factor, around: at) },
            onDown: { point, extend, forcePan in
                begin(at: point, extend: extend, forcePan: forcePan)
            },
            onDragged: { point in update(to: point) },
            onUp: { finishDrag() },
            cursor: { point in cursorHint(at: point) },
            contextMenu: { point in makeContextMenu(at: point) },
            nudge: { delta in model.nudgeSelection(byPoints: delta) },
            deleteSelection: { model.removeSelected() })
    }

    /// Zoom about a point on screen, so whatever is under the pointer stays
    /// under it. Zooming about the window's centre instead is the difference
    /// between a canvas that feels precise and one that fights you.
    private func zoom(by factor: CGFloat, around viewPoint: CGPoint) {
        model.viewport = model.viewport.zoomed(to: model.zoom * factor,
                                               holding: viewPoint)
    }

    private func begin(at location: CGPoint, extend: Bool, forcePan: Bool) {
        dragStartPoint = location

        if forcePan {
            dragMode = .pan
            panStart = model.pan
            return
        }

        if let (item, anchor) = handle(at: location) {
            let start = viewToBed(location)
            dragMode = .scale(anchor: anchor,
                              startDistance: hypot(start.x - anchor.x, start.y - anchor.y))
            dragOrigin = [item.id: item.origin]
            dragStartScale = item.scale
            return
        }

        if let hit = item(at: location) {
            if extend {
                if model.selection.contains(hit.id) {
                    model.selection.remove(hit.id)
                } else {
                    model.selection.insert(hit.id)
                }
            } else if !model.selection.contains(hit.id) {
                model.selection = [hit.id]
            }
            dragMode = .move
            dragOrigin = [:]
            for item in model.project.items where model.selection.contains(item.id) {
                dragOrigin[item.id] = item.origin
            }
            return
        }

        // Empty space: sweep out a selection. Panning lives on scroll, on
        // space-drag and on the middle button, which leaves the plain drag for
        // the thing every drawing program does with it.
        if !extend { model.selection = [] }
        selectionBeforeBand = model.selection
        dragMode = .rubberBand
        bandRect = CGRect(origin: location, size: .zero)
    }

    private func update(to location: CGPoint) {
        let dxView = location.x - dragStartPoint.x
        let dyView = location.y - dragStartPoint.y

        switch dragMode {
        case .none:
            break

        case .pan:
            model.pan = CGSize(width: panStart.width + dxView,
                               height: panStart.height + dyView)

        case .rubberBand:
            let rect = CGRect(x: min(dragStartPoint.x, location.x),
                              y: min(dragStartPoint.y, location.y),
                              width: abs(dxView), height: abs(dyView))
            bandRect = rect

            let inBed = CGRect(origin: viewToBed(rect.origin),
                               size: CGSize(width: rect.width / model.zoom,
                                            height: rect.height / model.zoom))
            let caught = model.project.items(intersecting: inBed).map(\.id)
            model.selection = selectionBeforeBand.union(caught)

        case .move:
            let dx = dxView / model.zoom
            let dy = dyView / model.zoom
            for index in model.project.items.indices {
                guard let start = dragOrigin[model.project.items[index].id] else { continue }
                model.project.items[index].origin = CGPoint(x: start.x + dx, y: start.y + dy)
            }

        case .scale(let anchor, let startDistance):
            guard startDistance > 1,
                  let id = model.selection.first,
                  let index = model.project.items.firstIndex(where: { $0.id == id }),
                  let startOrigin = dragOrigin[id] else { break }

            let current = viewToBed(location)
            let factor = max(0.02,
                             hypot(current.x - anchor.x, current.y - anchor.y) / startDistance)

            model.project.items[index].scale = dragStartScale * factor
            // Keep the anchor corner where it was.
            model.project.items[index].origin = CGPoint(
                x: anchor.x + (startOrigin.x - anchor.x) * factor,
                y: anchor.y + (startOrigin.y - anchor.y) * factor)
        }
    }

    private func finishDrag() {
        // Letting go is the end of one edit, whatever happened during it: the
        // whole drag undoes in a single step rather than frame by frame.
        // Panning and selecting change nothing about the job, so neither needs
        // an undo step of its own.
        switch dragMode {
        case .pan, .rubberBand, .none: break
        default: model.commitUndoStep()
        }
        dragMode = .none
        dragOrigin = [:]
        bandRect = nil
        selectionBeforeBand = []
    }

    private func cursorHint(at location: CGPoint) -> NSCursor {
        if handle(at: location) != nil { return .crosshair }
        if item(at: location) != nil { return .openHand }
        return .crosshair
    }

    // MARK: - Context menu

    /// Build the menu for a right-click, and make the selection match what was
    /// clicked first - a menu that acts on something other than the thing under
    /// the pointer is a trap.
    private func makeContextMenu(at location: CGPoint) -> NSMenu {
        if let hit = item(at: location) {
            if !model.selection.contains(hit.id) { model.selection = [hit.id] }
        } else {
            model.selection = []
        }

        let menu = NSMenu()
        if model.selection.isEmpty {
            buildEmptySpaceMenu(menu)
        } else {
            buildSelectionMenu(menu)
        }
        return menu
    }

    private func buildSelectionMenu(_ menu: NSMenu) {
        let many = model.selection.count > 1
        let noun = many ? "\(model.selection.count) Items" : "Item"

        menu.add("Duplicate", key: "d") { model.duplicateSelected() }
        menu.add("Delete \(noun)") { model.removeSelected() }
        menu.addItem(.separator())

        menu.add("Split into Parts…", key: "j",
                 enabled: model.canSplitSelection) { model.showSplitSheet = true }
        menu.add("Make Array…", key: "k") { model.showArraySheet = true }
        menu.addItem(.separator())

        let arrange = NSMenu()
        arrange.add("Bring to Front") { model.bringSelectionToFront() }
        arrange.add("Send to Back") { model.sendSelectionToBack() }
        arrange.addItem(.separator())
        arrange.add("Centre on Bed") { model.centerSelection() }
        arrange.add("Move to Top Left") { model.moveSelectionToOrigin() }
        arrange.add("Fit to Bed") { model.fitSelectionToBed() }
        arrange.addItem(.separator())
        arrange.add("Align Left") { model.alignSelection(.left) }
        arrange.add("Align Right") { model.alignSelection(.right) }
        arrange.add("Align Top") { model.alignSelection(.top) }
        arrange.add("Align Bottom") { model.alignSelection(.bottom) }
        arrange.add("Centre Horizontally") { model.alignSelection(.centerHorizontally) }
        arrange.add("Centre Vertically") { model.alignSelection(.centerVertically) }
        arrange.addItem(.separator())
        arrange.add("Distribute Horizontally", enabled: model.selection.count > 2) {
            model.distributeSelection(horizontally: true)
        }
        arrange.add("Distribute Vertically", enabled: model.selection.count > 2) {
            model.distributeSelection(horizontally: false)
        }
        menu.addSubmenu("Arrange", arrange)

        let rotate = NSMenu()
        rotate.add("90° Left") { model.rotateSelection(by: -.pi / 2) }
        rotate.add("90° Right") { model.rotateSelection(by: .pi / 2) }
        rotate.add("180°") { model.rotateSelection(by: .pi) }
        menu.addSubmenu("Rotate", rotate)

        menu.addItem(.separator())
        menu.add(model.selectionIsHidden ? "Show \(noun)" : "Hide \(noun)") {
            model.toggleSelectionVisible()
        }
        menu.add("Zoom to Selection") { model.zoomToSelection() }

        let hasFiles = model.selectedItems.contains { $0.sourceURL != nil }
        if hasFiles {
            menu.addItem(.separator())
            menu.add("Reload from Disk") { model.reloadAll() }
            menu.add("Reveal in Finder") { model.revealSelectionInFinder() }
        }
    }

    private func buildEmptySpaceMenu(_ menu: NSMenu) {
        menu.add("Add Artwork…", key: "i") { model.presentImportPanel() }
        menu.addItem(.separator())
        menu.add("Select All", key: "a",
                 enabled: !model.project.items.isEmpty) { model.selectAll() }
        menu.addItem(.separator())
        menu.add("Zoom to Fit", key: "0") { model.zoomToFit() }
        menu.add("Zoom to Everything",
                 enabled: !model.project.items.isEmpty) { model.zoomToSelection() }
        menu.add("Actual Size", key: "1") { model.zoomToActualSize() }
        menu.addItem(.separator())
        menu.add("Show Grid", checked: model.showGrid) { model.showGrid.toggle() }
        menu.add("Show Rulers", checked: model.showRulers) { model.showRulers.toggle() }
        menu.addItem(.separator())
        menu.add("Show Toolpath…", key: "y",
                 enabled: !model.project.items.isEmpty) { model.showToolpathSheet = true }
        menu.add("Trace Outline",
                 enabled: !model.project.items.isEmpty) { model.sendFrame() }
    }

    // MARK: - Coordinates

    private var viewTransform: CGAffineTransform {
        CGAffineTransform(scaleX: model.zoom, y: model.zoom)
            .concatenating(CGAffineTransform(translationX: model.pan.width,
                                             y: model.pan.height))
    }

    private func bedToView(_ p: CGPoint) -> CGPoint { model.viewport.bedToView(p) }
    private func viewToBed(_ p: CGPoint) -> CGPoint { model.viewport.viewToBed(p) }

    // MARK: - Hit testing

    private func item(at viewPoint: CGPoint) -> PlacedArtwork? {
        let bedPoint = viewToBed(viewPoint)
        // Topmost first: the last drawn is the one the eye picks.
        for item in model.project.items.reversed() where item.visible {
            let local = bedPoint.applying(item.transform.inverted())
            if CGRect(origin: .zero, size: item.artwork.size).insetBy(dx: -2, dy: -2)
                .contains(local) {
                return item
            }
        }
        return nil
    }

    private func handle(at viewPoint: CGPoint) -> (item: PlacedArtwork, anchor: CGPoint)? {
        guard model.selection.count == 1,
              let item = model.project.items.first(where: { model.selection.contains($0.id) })
        else { return nil }

        let points = corners(of: item.boundsOnBed.applying(viewTransform))
        for (index, corner) in points.enumerated() {
            if hypot(corner.x - viewPoint.x, corner.y - viewPoint.y) < 9 {
                // Scaling pins the opposite corner in place.
                return (item, viewToBed(points[(index + 2) % 4]))
            }
        }
        return nil
    }

    // MARK: - Drops

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            model.importFiles(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
    }
}

/// Wrapper so the preview cache can live in `@StateObject` without the cache
/// itself having to publish anything.
private final class ObservableCache: ObservableObject {
    let storage = PreviewCache()
}

// MARK: - AppKit event layer

/// Pointer, scroll and pinch handling for the canvas.
///
/// All of the canvas's input goes through here rather than through SwiftUI
/// gestures. Partly because SwiftUI on macOS 12 has no scroll or magnify event
/// and no hover, and partly because doing it in one place means the pointer
/// behaves the way a Mac canvas is expected to: two fingers pan, pinch zooms,
/// command-scroll zooms, shift-click extends the selection, and the cursor says
/// what a drag would do before it happens.
private struct CanvasEventView: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onScroll: (CGSize) -> Void
    let onZoom: (CGFloat, CGPoint) -> Void
    /// Point, whether to extend the selection, whether to pan instead.
    let onDown: (CGPoint, Bool, Bool) -> Void
    let onDragged: (CGPoint) -> Void
    let onUp: () -> Void
    let cursor: (CGPoint) -> NSCursor
    let contextMenu: (CGPoint) -> NSMenu
    let nudge: (CGVector) -> Void
    let deleteSelection: () -> Void

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.handlers = handlers
        return view
    }

    func updateNSView(_ view: EventView, context: Context) {
        view.handlers = handlers
    }

    private var handlers: EventView.Handlers {
        .init(hover: onHover, scroll: onScroll, zoom: onZoom,
              down: onDown, dragged: onDragged, up: onUp, cursor: cursor,
              contextMenu: contextMenu, nudge: nudge,
              deleteSelection: deleteSelection)
    }

    final class EventView: NSView {
        struct Handlers {
            var hover: (CGPoint?) -> Void = { _ in }
            var scroll: (CGSize) -> Void = { _ in }
            var zoom: (CGFloat, CGPoint) -> Void = { _, _ in }
            var down: (CGPoint, Bool, Bool) -> Void = { _, _, _ in }
            var dragged: (CGPoint) -> Void = { _ in }
            var up: () -> Void = {}
            var cursor: (CGPoint) -> NSCursor = { _ in .arrow }
            var contextMenu: (CGPoint) -> NSMenu = { _ in NSMenu() }
            var nudge: (CGVector) -> Void = { _ in }
            var deleteSelection: () -> Void = {}
        }

        var handlers = Handlers()
        private var tracking: NSTrackingArea?

        /// AppKit views have their origin at the bottom left; the canvas
        /// underneath works from the top.
        private func point(_ event: NSEvent) -> CGPoint {
            let p = convert(event.locationInWindow, from: nil)
            return CGPoint(x: p.x, y: bounds.height - p.y)
        }

        /// Take focus when the window opens, so the arrow keys work without
        /// having to click the canvas first. Only when nothing else has it -
        /// stealing focus from a field somebody is typing in would be worse
        /// than making them click once.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                if window.firstResponder === window {
                    window.makeFirstResponder(self)
                }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .mouseEnteredAndExited,
                                                .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            let p = point(event)
            handlers.hover(p)
            if spaceHeld { NSCursor.openHand.set() } else { handlers.cursor(p).set() }
        }

        override func mouseExited(with event: NSEvent) {
            handlers.hover(nil)
            NSCursor.arrow.set()
        }

        /// Space held turns any drag into a pan, the way it does in every
        /// canvas application. Panning has to live somewhere once the plain
        /// drag is doing rubber-band selection; this and the middle button and
        /// two-finger scroll are the three places people look for it.
        private var spaceHeld = false {
            didSet {
                guard spaceHeld != oldValue else { return }
                if spaceHeld { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            handlers.down(point(event), event.modifierFlags.contains(.shift), spaceHeld)
        }

        override func mouseDragged(with event: NSEvent) {
            handlers.dragged(point(event))
        }

        override func mouseUp(with event: NSEvent) {
            handlers.up()
        }

        // The middle button pans, for anyone with a three-button mouse.
        override func otherMouseDown(with event: NSEvent) {
            handlers.down(point(event), false, true)
        }

        override func otherMouseDragged(with event: NSEvent) {
            handlers.dragged(point(event))
        }

        override func otherMouseUp(with event: NSEvent) {
            handlers.up()
        }

        override func scrollWheel(with event: NSEvent) {
            let at = point(event)

            if event.modifierFlags.contains(.command) {
                // Command-scroll zooms, the way it does in a document view.
                let step = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY / 90 : event.scrollingDeltaY / 12
                handlers.zoom(1 + step, at)
                return
            }

            // A trackpad reports precise deltas already in points; a wheel
            // reports lines, which need scaling to feel like the same gesture.
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            handlers.scroll(CGSize(width: event.scrollingDeltaX * factor,
                                   height: event.scrollingDeltaY * factor))
        }

        override func magnify(with event: NSEvent) {
            handlers.zoom(1 + event.magnification, point(event))
        }

        /// AppKit asks for the menu before showing it, which is the moment to
        /// make the selection match what was clicked.
        override func menu(for event: NSEvent) -> NSMenu? {
            handlers.contextMenu(point(event))
        }

        /// Arrow keys nudge the selection; delete removes it.
        ///
        /// Handled here rather than as menu shortcuts on purpose. A menu key
        /// equivalent is matched before the responder chain sees the key, so
        /// binding an arrow or a plain delete in the menu bar would take them
        /// away from every text field in the window - press delete while
        /// renaming a layer and the artwork would disappear instead of a
        /// character. As a responder, this only fires when the canvas is the
        /// thing you are actually working in.
        override func keyDown(with event: NSEvent) {
            guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
                super.keyDown(with: event)
                return
            }

            let step: CGFloat = event.modifierFlags.contains(.shift)
                ? AppModel.coarseNudgeStep : AppModel.nudgeStep

            switch Int(scalar.value) {
            case NSUpArrowFunctionKey:    handlers.nudge(CGVector(dx: 0, dy: -step))
            case NSDownArrowFunctionKey:  handlers.nudge(CGVector(dx: 0, dy: step))
            case NSLeftArrowFunctionKey:  handlers.nudge(CGVector(dx: -step, dy: 0))
            case NSRightArrowFunctionKey: handlers.nudge(CGVector(dx: step, dy: 0))
            case NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey:
                handlers.deleteSelection()
            case 0x20:
                // Swallowed rather than passed on, or the window beeps at every
                // press while somebody is holding space to pan.
                spaceHeld = true
            default:
                super.keyDown(with: event)
            }
        }

        override func keyUp(with event: NSEvent) {
            if event.charactersIgnoringModifiers == " " {
                spaceHeld = false
            } else {
                super.keyUp(with: event)
            }
        }

        /// Releasing space while the window is not focused would otherwise
        /// leave the canvas stuck in panning mode.
        override func resignFirstResponder() -> Bool {
            spaceHeld = false
            return super.resignFirstResponder()
        }

        override var acceptsFirstResponder: Bool { true }

        /// Act on the click that brings the window forward rather than
        /// swallowing it - a canvas that ignores your first click is maddening.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}


// MARK: - Menu construction

private extension NSMenu {
    /// AppKit menus want a target and a selector; everything here wants a
    /// closure. One small item subclass bridges the two.
    @discardableResult
    func add(_ title: String, key: String = "", enabled: Bool = true,
             checked: Bool? = nil, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, key: key, handler: handler)
        item.isEnabled = enabled
        if let checked { item.state = checked ? .on : .off }
        addItem(item)
        return item
    }

    func addSubmenu(_ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not loaded from a nib") }

    @objc private func fire() { handler() }
}
