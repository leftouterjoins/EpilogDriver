/*
 * PDFArtworkImporter.swift - Read a PDF page into the artwork model
 *
 * This walks the page's content stream and records every painted path with the
 * colour it was painted in. That is the whole difference from the CUPS filter's
 * extractor, which asked "is this one of the six cut colours?" and dropped
 * everything else on the floor. Here nothing is dropped and nothing is decided:
 * the layer model decides later, and a person can overrule it.
 *
 * Text and images are deliberately not turned into paths. Doing that properly
 * means reimplementing a font rasterizer and every image filter in the PDF
 * spec. Instead the page itself is kept as the artwork's source and drawn
 * whenever a raster is needed, which is exactly what it is good at.
 */

import Foundation
import CoreGraphics

public final class PDFArtworkImporter {

    /// Graphics state tracked while scanning.
    private struct State {
        var lineWidth: CGFloat = 1.0
        var strokeColor = ArtworkColor.black
        var fillColor = ArtworkColor.black
        var ctm: CGAffineTransform = .identity
    }

    private var stateStack: [State] = [State()]
    private var state: State {
        get { stateStack.last ?? State() }
        set {
            if stateStack.isEmpty { stateStack.append(newValue) }
            else { stateStack[stateStack.count - 1] = newValue }
        }
    }

    private var currentPath: CGMutablePath?
    private var currentPoint: CGPoint = .zero

    private var paths: [ArtworkPath] = []
    private var paintedCount = 0
    private var images = 0

    /// Content streams currently being scanned, innermost last. Needed to
    /// resolve XObject names and to parent nested form streams.
    private var contentStreams: [CGPDFContentStreamRef] = []
    private var formDepth = 0
    private static let maxFormDepth = 12

    private lazy var operatorTable: CGPDFOperatorTableRef = makeOperatorTable()

    public init() {}

    // MARK: - Entry points

    /// Read a PDF file. `pageIndex` is 1-based.
    public static func importArtwork(from url: URL, pageIndex: Int = 1) throws -> Artwork {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw ArtworkImportError.unreadableFile(url)
        }
        return try importArtwork(from: document,
                                 pageIndex: pageIndex,
                                 name: url.deletingPathExtension().lastPathComponent)
    }

    public static func importArtwork(from data: Data, name: String,
                                     pageIndex: Int = 1) throws -> Artwork {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            throw ArtworkImportError.malformed("not a readable PDF")
        }
        return try importArtwork(from: document, pageIndex: pageIndex, name: name)
    }

    public static func importArtwork(from document: CGPDFDocument,
                                     pageIndex: Int, name: String) throws -> Artwork {
        guard document.numberOfPages > 0 else { throw ArtworkImportError.emptyDocument }
        let index = min(max(1, pageIndex), document.numberOfPages)
        guard let page = document.page(at: index) else { throw ArtworkImportError.emptyDocument }

        let importer = PDFArtworkImporter()
        return importer.read(page: page, name: name)
    }

    /// How many pages a PDF has, for the page picker.
    public static func pageCount(of url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }

    // MARK: - Scanning

    /// Transform taking PDF user space into document space: points, origin
    /// top-left, y increasing downward, page rotation applied.
    private static func documentTransform(for page: CGPDFPage) -> (CGAffineTransform, CGSize) {
        let media = page.getBoxRect(.mediaBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360

        var width = media.width
        var height = media.height
        if rotation == 90 || rotation == 270 { swap(&width, &height) }

        // Move the media box to the origin, then apply the page's own rotation,
        // leaving an upright y-up page of (width, height).
        var t = CGAffineTransform(translationX: -media.origin.x, y: -media.origin.y)
        switch rotation {
        case 90:
            t = t.concatenating(CGAffineTransform(rotationAngle: .pi / 2))
                 .concatenating(CGAffineTransform(translationX: height, y: 0))
        case 180:
            t = t.concatenating(CGAffineTransform(rotationAngle: .pi))
                 .concatenating(CGAffineTransform(translationX: width, y: height))
        case 270:
            t = t.concatenating(CGAffineTransform(rotationAngle: -.pi / 2))
                 .concatenating(CGAffineTransform(translationX: 0, y: width))
        default:
            break
        }

        // Flip to y-down.
        t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height))

        return (t, CGSize(width: width, height: height))
    }

    private func read(page: CGPDFPage, name: String) -> Artwork {
        let (transform, size) = Self.documentTransform(for: page)

        stateStack = [State()]
        state.ctm = transform
        paths = []
        paintedCount = 0
        images = 0

        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, operatorTable,
                                         Unmanaged.passUnretained(self).toOpaque())
        contentStreams.append(stream)
        CGPDFScannerScan(scanner)
        contentStreams.removeLast()
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)

        EpilogLog.debug("Imported \(name): \(paths.count) path(s) from "
                        + "\(paintedCount) painting operator(s), \(images) image(s), "
                        + String(format: "page %.1f x %.1f pt", size.width, size.height))

        return Artwork(name: name,
                       size: size,
                       paths: paths,
                       source: .pdfPage(page, transform: transform),
                       paintedOperatorCount: paintedCount,
                       imageCount: images)
    }

    /// Scan into a form XObject invoked by `Do`.
    ///
    /// CGPDFScanner does not follow `Do` on its own, and macOS's print pipeline
    /// routinely wraps a document's content in a form XObject when scaling it
    /// to the page. Without this, such a page looks completely empty.
    private func enterXObject(named name: String) {
        guard formDepth < Self.maxFormDepth, let parent = contentStreams.last,
              let obj = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }

        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &stream), let formStream = stream,
              let dict = CGPDFStreamGetDictionary(formStream) else { return }

        var subtype: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let st = subtype else { return }
        let kind = String(cString: st)

        if kind == "Image" {
            images += 1
            return
        }
        guard kind == "Form" else { return }

        formDepth += 1
        stateStack.append(state)
        defer {
            if stateStack.count > 1 { stateStack.removeLast() }
            formDepth -= 1
        }

        // A form's /Matrix maps form space into the space of its invoker.
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &matrix),
           let ma = matrix, CGPDFArrayGetCount(ma) == 6 {
            var v = [CGFloat](repeating: 0, count: 6)
            var ok = true
            for i in 0..<6 {
                var num: CGPDFReal = 0
                if CGPDFArrayGetNumber(ma, i, &num) { v[i] = CGFloat(num) } else { ok = false }
            }
            if ok {
                let m = CGAffineTransform(a: v[0], b: v[1], c: v[2],
                                          d: v[3], tx: v[4], ty: v[5])
                state.ctm = m.concatenating(state.ctm)
            }
        }

        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dict, "Resources", &resources)

        let sub = CGPDFContentStreamCreateWithStream(formStream, resources ?? dict, parent)
        let scanner = CGPDFScannerCreate(sub, operatorTable,
                                         Unmanaged.passUnretained(self).toOpaque())
        contentStreams.append(sub)
        CGPDFScannerScan(scanner)
        contentStreams.removeLast()
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(sub)
    }

    // MARK: - Operator table

    private func makeOperatorTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!

        func me(_ info: UnsafeMutableRawPointer?) -> PDFArtworkImporter {
            Unmanaged<PDFArtworkImporter>.fromOpaque(info!).takeUnretainedValue()
        }

        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = me(info); s.stateStack.append(s.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = me(info); if s.stateStack.count > 1 { s.stateStack.removeLast() }
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            var width: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &width) { me(info).state.lineWidth = CGFloat(width) }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            var a: CGPDFReal = 0, b: CGPDFReal = 0, c: CGPDFReal = 0
            var d: CGPDFReal = 0, e: CGPDFReal = 0, f: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &f), CGPDFScannerPopNumber(scanner, &e),
               CGPDFScannerPopNumber(scanner, &d), CGPDFScannerPopNumber(scanner, &c),
               CGPDFScannerPopNumber(scanner, &b), CGPDFScannerPopNumber(scanner, &a) {
                let m = CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c),
                                          d: CGFloat(d), tx: CGFloat(e), ty: CGFloat(f))
                let s = me(info)
                s.state.ctm = m.concatenating(s.state.ctm)
            }
        }

        // Path construction
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            var x: CGPDFReal = 0, y: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) {
                me(info).moveTo(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            var x: CGPDFReal = 0, y: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) {
                me(info).lineTo(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            var x1: CGPDFReal = 0, y1: CGPDFReal = 0, x2: CGPDFReal = 0
            var y2: CGPDFReal = 0, x3: CGPDFReal = 0, y3: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y3), CGPDFScannerPopNumber(scanner, &x3),
               CGPDFScannerPopNumber(scanner, &y2), CGPDFScannerPopNumber(scanner, &x2),
               CGPDFScannerPopNumber(scanner, &y1), CGPDFScannerPopNumber(scanner, &x1) {
                me(info).curveTo(CGPoint(x: CGFloat(x1), y: CGFloat(y1)),
                                 CGPoint(x: CGFloat(x2), y: CGFloat(y2)),
                                 CGPoint(x: CGFloat(x3), y: CGFloat(y3)))
            }
        }
        // v: first control point is the current point
        CGPDFOperatorTableSetCallback(table, "v") { scanner, info in
            var x2: CGPDFReal = 0, y2: CGPDFReal = 0, x3: CGPDFReal = 0, y3: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y3), CGPDFScannerPopNumber(scanner, &x3),
               CGPDFScannerPopNumber(scanner, &y2), CGPDFScannerPopNumber(scanner, &x2) {
                let s = me(info)
                let start = s.currentPointInUserSpace
                s.curveTo(start,
                          CGPoint(x: CGFloat(x2), y: CGFloat(y2)),
                          CGPoint(x: CGFloat(x3), y: CGFloat(y3)))
            }
        }
        // y: second control point is the end point
        CGPDFOperatorTableSetCallback(table, "y") { scanner, info in
            var x1: CGPDFReal = 0, y1: CGPDFReal = 0, x3: CGPDFReal = 0, y3: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y3), CGPDFScannerPopNumber(scanner, &x3),
               CGPDFScannerPopNumber(scanner, &y1), CGPDFScannerPopNumber(scanner, &x1) {
                let end = CGPoint(x: CGFloat(x3), y: CGFloat(y3))
                me(info).curveTo(CGPoint(x: CGFloat(x1), y: CGFloat(y1)), end, end)
            }
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in me(info).currentPath?.closeSubpath() }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            var x: CGPDFReal = 0, y: CGPDFReal = 0, w: CGPDFReal = 0, h: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &h), CGPDFScannerPopNumber(scanner, &w),
               CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) {
                me(info).addRect(CGRect(x: CGFloat(x), y: CGFloat(y),
                                        width: CGFloat(w), height: CGFloat(h)))
            }
        }

        // Painting
        CGPDFOperatorTableSetCallback(table, "S")  { _, info in me(info).paint(fill: false, stroke: true, evenOdd: false) }
        CGPDFOperatorTableSetCallback(table, "s")  { _, info in
            let s = me(info); s.currentPath?.closeSubpath(); s.paint(fill: false, stroke: true, evenOdd: false)
        }
        CGPDFOperatorTableSetCallback(table, "f")  { _, info in me(info).paint(fill: true, stroke: false, evenOdd: false) }
        CGPDFOperatorTableSetCallback(table, "F")  { _, info in me(info).paint(fill: true, stroke: false, evenOdd: false) }
        CGPDFOperatorTableSetCallback(table, "f*") { _, info in me(info).paint(fill: true, stroke: false, evenOdd: true) }
        CGPDFOperatorTableSetCallback(table, "B")  { _, info in me(info).paint(fill: true, stroke: true, evenOdd: false) }
        CGPDFOperatorTableSetCallback(table, "B*") { _, info in me(info).paint(fill: true, stroke: true, evenOdd: true) }
        CGPDFOperatorTableSetCallback(table, "b")  { _, info in
            let s = me(info); s.currentPath?.closeSubpath(); s.paint(fill: true, stroke: true, evenOdd: false)
        }
        CGPDFOperatorTableSetCallback(table, "b*") { _, info in
            let s = me(info); s.currentPath?.closeSubpath(); s.paint(fill: true, stroke: true, evenOdd: true)
        }
        // n ends the path without painting it - typically after W/W* set a clip.
        CGPDFOperatorTableSetCallback(table, "n")  { _, info in me(info).currentPath = nil }

        // Colour
        CGPDFOperatorTableSetCallback(table, "RG") { scanner, info in
            if let c = popComponents(scanner, max: 3), let rgb = toRGB(c) { me(info).state.strokeColor = rgb }
        }
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
            if let c = popComponents(scanner, max: 3), let rgb = toRGB(c) { me(info).state.fillColor = rgb }
        }
        CGPDFOperatorTableSetCallback(table, "G") { scanner, info in
            if let c = popComponents(scanner, max: 1), let rgb = toRGB(c) { me(info).state.strokeColor = rgb }
        }
        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
            if let c = popComponents(scanner, max: 1), let rgb = toRGB(c) { me(info).state.fillColor = rgb }
        }
        CGPDFOperatorTableSetCallback(table, "K") { scanner, info in
            if let c = popComponents(scanner, max: 4), let rgb = toRGB(c) { me(info).state.strokeColor = rgb }
        }
        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
            if let c = popComponents(scanner, max: 4), let rgb = toRGB(c) { me(info).state.fillColor = rgb }
        }
        // Generic colour operators: the component count depends on the current
        // colour space, which is inferred from what is on the stack. Anything
        // written in ICCBased or Separation colour arrives through these.
        for op in ["SC", "SCN"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                if let c = popComponents(scanner, max: 4), let rgb = toRGB(c) {
                    me(info).state.strokeColor = rgb
                }
            }
        }
        for op in ["sc", "scn"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                if let c = popComponents(scanner, max: 4), let rgb = toRGB(c) {
                    me(info).state.fillColor = rgb
                }
            }
        }

        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name), let n = name else { return }
            me(info).enterXObject(named: String(cString: n))
        }

        return table
    }

    // MARK: - Path building (all points transformed to document space)

    /// The current point expressed back in user space, for the `v` operator
    /// whose first control point is implicitly the current point.
    private var currentPointInUserSpace: CGPoint {
        currentPoint.applying(state.ctm.inverted())
    }

    private func moveTo(_ p: CGPoint) {
        if currentPath == nil { currentPath = CGMutablePath() }
        let d = p.applying(state.ctm)
        currentPath?.move(to: d)
        currentPoint = d
    }

    private func lineTo(_ p: CGPoint) {
        if currentPath == nil { currentPath = CGMutablePath(); currentPath?.move(to: currentPoint) }
        let d = p.applying(state.ctm)
        currentPath?.addLine(to: d)
        currentPoint = d
    }

    private func curveTo(_ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint) {
        if currentPath == nil { currentPath = CGMutablePath(); currentPath?.move(to: currentPoint) }
        let d = end.applying(state.ctm)
        currentPath?.addCurve(to: d,
                              control1: c1.applying(state.ctm),
                              control2: c2.applying(state.ctm))
        currentPoint = d
    }

    private func addRect(_ r: CGRect) {
        if currentPath == nil { currentPath = CGMutablePath() }
        // Transform the corners rather than the rect: `CGRect.applying` returns
        // the bounding box, which silently squares up any rotation.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY), transform: state.ctm)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY), transform: state.ctm)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY), transform: state.ctm)
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY), transform: state.ctm)
        p.closeSubpath()
        currentPath?.addPath(p)
        currentPoint = CGPoint(x: r.minX, y: r.minY).applying(state.ctm)
    }

    /// Effective stroke width in document points, after the CTM.
    ///
    /// Uses sqrt(|determinant|) rather than the `a` component so rotated and
    /// skewed transforms give a sane width instead of collapsing to zero.
    private var deviceStrokeWidth: CGFloat {
        let m = state.ctm
        let scale = sqrt(abs(m.a * m.d - m.b * m.c))
        // A zero-width line means "thinnest the device can draw", not "invisible".
        return max(0.05, state.lineWidth * scale)
    }

    private func paint(fill: Bool, stroke: Bool, evenOdd: Bool) {
        guard let path = currentPath else { return }
        defer { currentPath = nil }
        paintedCount += 1
        guard !path.isEmpty else { return }

        paths.append(ArtworkPath(
            path: path.copy() ?? path,
            stroke: stroke ? state.strokeColor : nil,
            strokeWidth: deviceStrokeWidth,
            fill: fill ? state.fillColor : nil,
            usesEvenOdd: evenOdd
        ))
    }
}

// MARK: - Colour operand helpers

/// Pop up to `max` numeric operands, returned in source order.
/// Stops early on a non-numeric operand (e.g. a pattern name after `scn`).
private func popComponents(_ scanner: CGPDFScannerRef, max limit: Int) -> [CGFloat]? {
    var reversed: [CGFloat] = []
    while reversed.count < limit {
        var v: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &v) else { break }
        reversed.append(CGFloat(v))
    }
    return reversed.isEmpty ? nil : reversed.reversed()
}

/// Interpret 1, 3 or 4 colour components as RGB.
private func toRGB(_ c: [CGFloat]) -> ArtworkColor? {
    switch c.count {
    case 1:
        return ArtworkColor(r: Double(c[0]), g: Double(c[0]), b: Double(c[0]))
    case 3:
        return ArtworkColor(r: Double(c[0]), g: Double(c[1]), b: Double(c[2]))
    case 4:
        let k = Double(c[3])
        return ArtworkColor(r: (1 - Double(c[0])) * (1 - k),
                        g: (1 - Double(c[1])) * (1 - k),
                        b: (1 - Double(c[2])) * (1 - k))
    default:
        return nil
    }
}
