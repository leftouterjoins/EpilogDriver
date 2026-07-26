/*
 * PDFVectorExtractor.swift - Extract vector paths from PDF for laser cutting
 *
 * Uses CoreGraphics to parse PDF content streams and extract the paths that
 * should be vector cut rather than raster engraved.
 *
 * Routing rule: a path painted in one of the six saturated Epilog cut colors
 * (red, green, blue, cyan, yellow, magenta) is cut; everything else is left to
 * the raster pipeline. This matches Epilog's own workflow and the per-color
 * power/speed/frequency settings exposed in the PPD.
 *
 * Line width is not used to make this decision. The previous rule cut only
 * strokes ≤0.003" (0.216pt), which no drawing application emits, so in practice
 * nothing was ever routed to the cutter.
 */

import Foundation
import CoreGraphics
import ImageIO

/// Extracts vector paths from PDF documents for laser cutting
class PDFVectorExtractor {
    /// Strokes at or below this width, in points, are cut rather than engraved.
    /// 0.25pt (0.0035") follows Epilog's hairline convention. macOS emits a
    /// default 1.0 line width scaled by the page CTM, which for a bed-sized page
    /// lands at 0.144pt - comfortably inside this.
    static let maxVectorLineWidth: CGFloat = 0.25

    /// Resolution for coordinate conversion (DPI)
    let resolution: Int

    /// Extracted vector paths
    private(set) var paths: [VectorPath] = []

    /// How many path-painting operators the page contained, whether or not they
    /// qualified as cuts. Zero means the document holds no vector artwork at
    /// all - typically a page flattened to a single image - which is a very
    /// different problem from artwork that simply was not routed to the cutter.
    private(set) var paintedPathCount = 0

    /// How many image XObjects were drawn. A page that is one big image and
    /// nothing else is the signature of an application that flattens on print.
    private(set) var imageCount = 0

    /// Current graphics state stack
    private var stateStack: [GraphicsState] = []

    /// Current path being built
    private var currentPath: CGMutablePath?

    /// Current point for path operations
    private var currentPoint: CGPoint = .zero

    /// Start point of current subpath (for closing paths)
    private var subpathStartPoint: CGPoint = .zero

    /// Page height in pixels (for Y-axis flipping - Epilog has Y=0 at top)
    private var pageHeightPixels: Int = 0

    /// Content streams currently being scanned, innermost last. Needed to
    /// resolve XObject names and to parent nested form streams.
    private var contentStreams: [CGPDFContentStreamRef] = []

    /// Recursion guard for pathological or self-referential form nesting
    private var formDepth = 0
    private static let maxFormDepth = 12

    /// Operator table, built once and reused for nested form streams
    private lazy var operatorTable: CGPDFOperatorTableRef = createOperatorTable()

    /// Graphics state for tracking stroke properties
    struct GraphicsState {
        var lineWidth: CGFloat = 1.0
        var strokeColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        var fillColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        var ctm: CGAffineTransform = .identity
    }

    /// Target page size in points, matching the rasterizer's. A larger document
    /// is scaled down to fit so cuts and engraving stay registered.
    let outputSizePoints: CGSize?

    init(resolution: Int = 500, outputSizePoints: CGSize? = nil) {
        self.resolution = resolution
        self.outputSizePoints = outputSizePoints
        stateStack = [GraphicsState()]
    }

    /// Current graphics state
    var currentState: GraphicsState {
        get { stateStack.last ?? GraphicsState() }
        set {
            if stateStack.isEmpty {
                stateStack.append(newValue)
            } else {
                stateStack[stateStack.count - 1] = newValue
            }
        }
    }

    /// Extract vector paths from a PDF file
    func extractFromPDF(at url: URL) -> [VectorPath] {
        guard let document = CGPDFDocument(url as CFURL) else {
            fputs("ERROR: Cannot open PDF: \(url.path)\n", stderr)
            return []
        }

        return extractFromPDF(document: document)
    }

    /// Extract vector paths from a PDF document
    func extractFromPDF(document: CGPDFDocument) -> [VectorPath] {
        paths = []

        let pageCount = document.numberOfPages
        for pageNum in 1...pageCount {
            guard let page = document.page(at: pageNum) else { continue }
            extractFromPage(page)
        }

        return paths
    }

    /// Extract vector paths from a single PDF page
    func extractFromPage(_ page: CGPDFPage) {
        // Reset state for new page
        stateStack = [GraphicsState()]

        // Get page dimensions and calculate height in pixels
        let mediaBox = page.getBoxRect(.mediaBox)
        let scale = CGFloat(resolution) / 72.0

        // Mirror the rasterizer's fit exactly, or cuts would land somewhere
        // other than the engraving they belong to.
        var outHeight = mediaBox.height
        var t = CGAffineTransform(translationX: -mediaBox.origin.x, y: -mediaBox.origin.y)
        if let target = outputSizePoints, target.width > 0, target.height > 0,
           mediaBox.width > 0, mediaBox.height > 0 {
            let fit = min(target.width / mediaBox.width, target.height / mediaBox.height)
            if fit < 0.999 {
                outHeight = target.height
                t = t.concatenating(CGAffineTransform(scaleX: fit, y: fit))
                t = t.concatenating(CGAffineTransform(
                    translationX: 0, y: outHeight - mediaBox.height * fit))
            }
        }
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        pageHeightPixels = Int(ceil(outHeight * scale))
        currentState.ctm = t

        // Parse the content stream
        let contentStream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(contentStream, operatorTable, Unmanaged.passUnretained(self).toOpaque())

        contentStreams.append(contentStream)
        CGPDFScannerScan(scanner)
        contentStreams.removeLast()

        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contentStream)
    }

    /// Scan into a form XObject invoked by `Do`.
    ///
    /// CGPDFScanner does not follow `Do` on its own. macOS's print pipeline
    /// routinely wraps a document's content in a form XObject when scaling it to
    /// the page, so without this the whole page would look empty.
    fileprivate func enterXObject(named name: String) {
        guard formDepth < Self.maxFormDepth, let parent = contentStreams.last else { return }

        guard let obj = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }

        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &stream), let formStream = stream,
              let formDict = CGPDFStreamGetDictionary(formStream) else { return }

        // Only form XObjects carry drawable operators; images are the raster
        // pipeline's problem, but count them so a page that is nothing but one
        // big image can be reported as such.
        var subtype: UnsafePointer<Int8>?
        guard CGPDFDictionaryGetName(formDict, "Subtype", &subtype),
              let st = subtype else { return }
        let kind = String(cString: st)
        if kind == "Image" { imageCount += 1 }
        guard kind == "Form" else { return }

        formDepth += 1
        pushState()
        defer {
            popState()
            formDepth -= 1
        }

        // A form's /Matrix maps form space into the space of its invoker.
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(formDict, "Matrix", &matrix),
           let ma = matrix, CGPDFArrayGetCount(ma) == 6 {
            var v = [CGFloat](repeating: 0, count: 6)
            var ok = true
            for i in 0..<6 {
                var num: CGPDFReal = 0
                if CGPDFArrayGetNumber(ma, i, &num) { v[i] = CGFloat(num) } else { ok = false }
            }
            if ok {
                let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                currentState.ctm = m.concatenating(currentState.ctm)
            }
        }

        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(formDict, "Resources", &resources)

        let sub = CGPDFContentStreamCreateWithStream(formStream, resources ?? formDict, parent)
        let scanner = CGPDFScannerCreate(sub, operatorTable, Unmanaged.passUnretained(self).toOpaque())

        contentStreams.append(sub)
        CGPDFScannerScan(scanner)
        contentStreams.removeLast()

        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(sub)
    }

    /// Create the PDF operator callback table
    private func createOperatorTable() -> CGPDFOperatorTableRef {
        let table = CGPDFOperatorTableCreate()!

        // Graphics state operators
        CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.pushState()
        }

        CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.popState()
        }

        // Line width
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var width: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &width) {
                extractor.currentState.lineWidth = CGFloat(width)
            }
        }

        // Concatenate matrix
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var a: CGPDFReal = 0, b: CGPDFReal = 0, c: CGPDFReal = 0
            var d: CGPDFReal = 0, e: CGPDFReal = 0, f: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &f) &&
               CGPDFScannerPopNumber(scanner, &e) &&
               CGPDFScannerPopNumber(scanner, &d) &&
               CGPDFScannerPopNumber(scanner, &c) &&
               CGPDFScannerPopNumber(scanner, &b) &&
               CGPDFScannerPopNumber(scanner, &a) {
                let matrix = CGAffineTransform(a: CGFloat(a), b: CGFloat(b),
                                               c: CGFloat(c), d: CGFloat(d),
                                               tx: CGFloat(e), ty: CGFloat(f))
                extractor.currentState.ctm = matrix.concatenating(extractor.currentState.ctm)
            }
        }

        // Path construction operators
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var x: CGPDFReal = 0, y: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y) &&
               CGPDFScannerPopNumber(scanner, &x) {
                extractor.moveTo(x: CGFloat(x), y: CGFloat(y))
            }
        }

        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var x: CGPDFReal = 0, y: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y) &&
               CGPDFScannerPopNumber(scanner, &x) {
                extractor.lineTo(x: CGFloat(x), y: CGFloat(y))
            }
        }

        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var x1: CGPDFReal = 0, y1: CGPDFReal = 0
            var x2: CGPDFReal = 0, y2: CGPDFReal = 0
            var x3: CGPDFReal = 0, y3: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y3) &&
               CGPDFScannerPopNumber(scanner, &x3) &&
               CGPDFScannerPopNumber(scanner, &y2) &&
               CGPDFScannerPopNumber(scanner, &x2) &&
               CGPDFScannerPopNumber(scanner, &y1) &&
               CGPDFScannerPopNumber(scanner, &x1) {
                extractor.curveTo(x1: CGFloat(x1), y1: CGFloat(y1),
                                  x2: CGFloat(x2), y2: CGFloat(y2),
                                  x3: CGFloat(x3), y3: CGFloat(y3))
            }
        }

        CGPDFOperatorTableSetCallback(table, "h") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.closePath()
        }

        // Rectangle
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var x: CGPDFReal = 0, y: CGPDFReal = 0
            var w: CGPDFReal = 0, h: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &h) &&
               CGPDFScannerPopNumber(scanner, &w) &&
               CGPDFScannerPopNumber(scanner, &y) &&
               CGPDFScannerPopNumber(scanner, &x) {
                extractor.addRectangle(x: CGFloat(x), y: CGFloat(y),
                                       width: CGFloat(w), height: CGFloat(h))
            }
        }

        // Path painting operators
        CGPDFOperatorTableSetCallback(table, "S") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.strokePath()
        }

        CGPDFOperatorTableSetCallback(table, "s") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.closePath()
            extractor.strokePath()
        }

        CGPDFOperatorTableSetCallback(table, "n") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.endPath()
        }

        // Fill operators - extract path boundary as vector cut
        CGPDFOperatorTableSetCallback(table, "f") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.fillPath()
        }

        CGPDFOperatorTableSetCallback(table, "f*") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.fillPath()
        }

        CGPDFOperatorTableSetCallback(table, "F") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.fillPath()
        }

        // Combined fill and stroke
        CGPDFOperatorTableSetCallback(table, "B") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.fillAndStrokePath()
        }

        CGPDFOperatorTableSetCallback(table, "B*") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.fillAndStrokePath()
        }

        CGPDFOperatorTableSetCallback(table, "b") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.closePath()
            extractor.fillAndStrokePath()
        }

        CGPDFOperatorTableSetCallback(table, "b*") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            extractor.closePath()
            extractor.fillAndStrokePath()
        }

        // Stroke color operators
        CGPDFOperatorTableSetCallback(table, "RG") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var r: CGPDFReal = 0, g: CGPDFReal = 0, b: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &b) &&
               CGPDFScannerPopNumber(scanner, &g) &&
               CGPDFScannerPopNumber(scanner, &r) {
                extractor.currentState.strokeColor = (CGFloat(r), CGFloat(g), CGFloat(b))
            }
        }

        CGPDFOperatorTableSetCallback(table, "G") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var gray: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &gray) {
                let g = CGFloat(gray)
                extractor.currentState.strokeColor = (g, g, g)
            }
        }

        // Fill color operators
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var r: CGPDFReal = 0, g: CGPDFReal = 0, b: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &b) &&
               CGPDFScannerPopNumber(scanner, &g) &&
               CGPDFScannerPopNumber(scanner, &r) {
                extractor.currentState.fillColor = (CGFloat(r), CGFloat(g), CGFloat(b))
            }
        }

        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var gray: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &gray) {
                let g = CGFloat(gray)
                extractor.currentState.fillColor = (g, g, g)
            }
        }

        // CMYK color operators
        CGPDFOperatorTableSetCallback(table, "K") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            if let c = PDFVectorExtractor.popComponents(scanner, max: 4),
               let rgb = PDFVectorExtractor.componentsToRGB(c) {
                extractor.currentState.strokeColor = rgb
            }
        }

        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            if let c = PDFVectorExtractor.popComponents(scanner, max: 4),
               let rgb = PDFVectorExtractor.componentsToRGB(c) {
                extractor.currentState.fillColor = rgb
            }
        }

        // Generic color operators - the component count depends on the current
        // color space, which we infer from how many numbers are on the stack.
        // Apps that write ICCBased or Separation colors reach us through these.
        for op in ["SC", "SCN"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
                if let c = PDFVectorExtractor.popComponents(scanner, max: 4),
                   let rgb = PDFVectorExtractor.componentsToRGB(c) {
                    extractor.currentState.strokeColor = rgb
                }
            }
        }

        for op in ["sc", "scn"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
                if let c = PDFVectorExtractor.popComponents(scanner, max: 4),
                   let rgb = PDFVectorExtractor.componentsToRGB(c) {
                    extractor.currentState.fillColor = rgb
                }
            }
        }

        // Form XObject invocation - recurse so wrapped content is not missed
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let extractor = Unmanaged<PDFVectorExtractor>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name), let n = name else { return }
            extractor.enterXObject(named: String(cString: n))
        }

        return table
    }

    /// Pop up to `max` numeric operands, returned in source order.
    /// Stops early on a non-numeric operand (e.g. a pattern name after `scn`).
    fileprivate static func popComponents(_ scanner: CGPDFScannerRef, max: Int) -> [CGFloat]? {
        var reversed: [CGFloat] = []
        while reversed.count < max {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &v) else { break }
            reversed.append(CGFloat(v))
        }
        return reversed.isEmpty ? nil : reversed.reversed()
    }

    /// Interpret 1, 3 or 4 color components as RGB.
    fileprivate static func componentsToRGB(_ c: [CGFloat]) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        switch c.count {
        case 1:
            return (c[0], c[0], c[0])
        case 3:
            return (c[0], c[1], c[2])
        case 4:
            let k = c[3]
            return ((1 - c[0]) * (1 - k), (1 - c[1]) * (1 - k), (1 - c[2]) * (1 - k))
        default:
            return nil
        }
    }

    // MARK: - State Management

    private func pushState() {
        stateStack.append(currentState)
    }

    private func popState() {
        if stateStack.count > 1 {
            stateStack.removeLast()
        }
    }

    // MARK: - Path Construction

    private func moveTo(x: CGFloat, y: CGFloat) {
        if currentPath == nil {
            currentPath = CGMutablePath()
        }
        let point = CGPoint(x: x, y: y).applying(currentState.ctm)
        currentPath?.move(to: point)
        currentPoint = point
        subpathStartPoint = point  // Track start for closeSubpath
    }

    private func lineTo(x: CGFloat, y: CGFloat) {
        if currentPath == nil {
            currentPath = CGMutablePath()
            currentPath?.move(to: currentPoint)
        }
        let point = CGPoint(x: x, y: y).applying(currentState.ctm)
        currentPath?.addLine(to: point)
        currentPoint = point
    }

    private func curveTo(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, x3: CGFloat, y3: CGFloat) {
        if currentPath == nil {
            currentPath = CGMutablePath()
            currentPath?.move(to: currentPoint)
        }
        let cp1 = CGPoint(x: x1, y: y1).applying(currentState.ctm)
        let cp2 = CGPoint(x: x2, y: y2).applying(currentState.ctm)
        let end = CGPoint(x: x3, y: y3).applying(currentState.ctm)
        currentPath?.addCurve(to: end, control1: cp1, control2: cp2)
        currentPoint = end
    }

    private func closePath() {
        currentPath?.closeSubpath()
    }

    private func addRectangle(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        if currentPath == nil {
            currentPath = CGMutablePath()
        }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let transformedRect = rect.applying(currentState.ctm)
        currentPath?.addRect(transformedRect)
    }

    private func endPath() {
        currentPath = nil
    }

    // MARK: - Path Stroking

    /// Decide whether a paint color routes this path to the vector cutter.
    ///
    /// Epilog's workflow (and this driver's per-color PPD settings) key off the
    /// six saturated colors; anything else - black, greys, unsaturated tints -
    /// is engraved by the raster pipeline instead. Stroke width is deliberately
    /// not consulted: no drawing app emits the sub-0.003" hairlines the old rule
    /// required, so in practice nothing ever qualified as a cut.
    private func cutColor(for color: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CutColor? {
        let r = UInt8(min(255, max(0, Int(color.r * 255))))
        let g = UInt8(min(255, max(0, Int(color.g * 255))))
        let b = UInt8(min(255, max(0, Int(color.b * 255))))
        return CutColor(r: r, g: g, b: b)
    }

    /// Effective stroke width in points, after the CTM.
    ///
    /// Uses sqrt(|determinant|) rather than the `a` component so rotated and
    /// skewed transforms give a sane width instead of collapsing to zero.
    private func strokeWidthInPoints() -> CGFloat {
        let m = currentState.ctm
        let scaleFactor = sqrt(abs(m.a * m.d - m.b * m.c))
        let deviceWidth = currentState.lineWidth * scaleFactor
        return deviceWidth / (CGFloat(resolution) / 72.0)
    }

    private func strokePath() {
        guard let path = currentPath else { return }
        defer { currentPath = nil }
        paintedPathCount += 1

        // A stroke is a cut if it is painted in a cut colour OR drawn as a
        // hairline. Both rules are needed: macOS converts the spooled document
        // to greyscale for this queue, which turns a cyan cut line white and
        // leaves width as the only surviving discriminator. Printing paths that
        // keep colour still work via the colour rule.
        let cc = cutColor(for: currentState.strokeColor)
        let width = strokeWidthInPoints()
        let isHairline = width <= Self.maxVectorLineWidth

        guard cc != nil || isHairline else { return }

        let vectorPath = convertToVectorPath(path, useFillColor: false)
        if !vectorPath.commands.isEmpty {
            paths.append(vectorPath)
            let why = cc.map { "\($0)" } ?? String(format: "hairline %.3fpt", width)
            fputs("DEBUG: Extracted stroke path (\(why)) with \(vectorPath.commands.count) commands\n", stderr)
        }
    }

    /// Fill path - extract the boundary as a vector cut when the fill is a cut
    /// color. Filled shapes in any other color are engraved, not cut.
    private func fillPath() {
        guard let path = currentPath else { return }
        defer { currentPath = nil }
        paintedPathCount += 1

        guard let cc = cutColor(for: currentState.fillColor) else { return }

        let vectorPath = convertToVectorPath(path, useFillColor: true)
        if !vectorPath.commands.isEmpty {
            paths.append(vectorPath)
            fputs("DEBUG: Extracted \(cc) fill path with \(vectorPath.commands.count) commands\n", stderr)
        }
    }

    /// Combined fill and stroke - the stroke color decides, since that is the
    /// outline the cutter would follow.
    private func fillAndStrokePath() {
        guard let path = currentPath else { return }
        defer { currentPath = nil }
        paintedPathCount += 1

        // B/b paint a stroke as well as a fill, so they get the same rule as a
        // plain stroke: cut colour or hairline. The stroke decides, since that
        // is the outline the cutter would follow.
        let cc = cutColor(for: currentState.strokeColor)
        let width = strokeWidthInPoints()
        let isHairline = width <= Self.maxVectorLineWidth
        guard cc != nil || isHairline else { return }

        let vectorPath = convertToVectorPath(path, useFillColor: false)
        if !vectorPath.commands.isEmpty {
            paths.append(vectorPath)
            let why = cc.map { "\($0)" } ?? String(format: "hairline %.3fpt", width)
            fputs("DEBUG: Extracted fill+stroke path (\(why)) with \(vectorPath.commands.count) commands\n", stderr)
        }
    }

    /// Convert a CGPath to a VectorPath for HPGL output
    /// Y coordinates are flipped because Epilog has Y=0 at top, PDF has Y=0 at bottom
    private func convertToVectorPath(_ cgPath: CGPath, useFillColor: Bool = false) -> VectorPath {
        var vectorPath = VectorPath()

        // Store color for color mapping (use fill or stroke color based on operation)
        let color = useFillColor ? currentState.fillColor : currentState.strokeColor
        vectorPath.strokeColor = (r: color.r, g: color.g, b: color.b)

        // Helper to flip Y coordinate for Epilog (Y=0 at top)
        let flipY = { (y: CGFloat) -> Int in
            return self.pageHeightPixels - Int(y)
        }

        // Track subpath start for closing paths
        var localSubpathStart: CGPoint = .zero
        var localCurrentPoint: CGPoint = .zero

        cgPath.applyWithBlock { elementPtr in
            let element = elementPtr.pointee

            switch element.type {
            case .moveToPoint:
                let point = element.points[0]
                vectorPath.moveTo(x: Int(point.x), y: flipY(point.y))
                localSubpathStart = point
                localCurrentPoint = point

            case .addLineToPoint:
                let point = element.points[0]
                vectorPath.lineTo(x: Int(point.x), y: flipY(point.y))
                localCurrentPoint = point

            case .addCurveToPoint:
                // Flatten curves into line segments
                // For laser cutting, we approximate curves with multiple line segments
                let cp1 = element.points[0]
                let cp2 = element.points[1]
                let end = element.points[2]

                // Simple curve flattening - add more segments for smoother curves
                let segments = 10
                for i in 1...segments {
                    let t = CGFloat(i) / CGFloat(segments)
                    let point = self.bezierPoint(t: t, p0: localCurrentPoint,
                                           p1: cp1, p2: cp2, p3: end)
                    vectorPath.lineTo(x: Int(point.x), y: flipY(point.y))
                }
                localCurrentPoint = end

            case .addQuadCurveToPoint:
                let cp = element.points[0]
                let end = element.points[1]

                let segments = 8
                for i in 1...segments {
                    let t = CGFloat(i) / CGFloat(segments)
                    let point = self.quadBezierPoint(t: t, p0: localCurrentPoint,
                                                p1: cp, p2: end)
                    vectorPath.lineTo(x: Int(point.x), y: flipY(point.y))
                }
                localCurrentPoint = end

            case .closeSubpath:
                // Close by drawing line back to start of subpath
                vectorPath.lineTo(x: Int(localSubpathStart.x), y: flipY(localSubpathStart.y))
                localCurrentPoint = localSubpathStart

            @unknown default:
                break
            }
        }

        return vectorPath
    }

    /// Calculate point on cubic Bezier curve
    private func bezierPoint(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let mt = 1 - t
        let mt2 = mt * mt
        let mt3 = mt2 * mt
        let t2 = t * t
        let t3 = t2 * t

        let x = mt3 * p0.x + 3 * mt2 * t * p1.x + 3 * mt * t2 * p2.x + t3 * p3.x
        let y = mt3 * p0.y + 3 * mt2 * t * p1.y + 3 * mt * t2 * p2.y + t3 * p3.y

        return CGPoint(x: x, y: y)
    }

    /// Calculate point on quadratic Bezier curve
    private func quadBezierPoint(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
        let mt = 1 - t
        let mt2 = mt * mt
        let t2 = t * t

        let x = mt2 * p0.x + 2 * mt * t * p1.x + t2 * p2.x
        let y = mt2 * p0.y + 2 * mt * t * p1.y + t2 * p2.y

        return CGPoint(x: x, y: y)
    }
}

/// Extension to read PDF from stdin for CUPS filter
extension PDFVectorExtractor {
    /// Extract vectors from PDF data
    func extractFromPDFData(_ data: Data) -> [VectorPath] {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            fputs("ERROR: Cannot parse PDF data\n", stderr)
            return []
        }

        return extractFromPDF(document: document)
    }
}
