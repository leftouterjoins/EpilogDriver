/*
 * PDFVectorExtractor.swift - Extract vector paths from PDF for laser cutting
 *
 * Uses CoreGraphics to parse PDF content streams and extract thin stroke paths
 * that should be vector cut rather than raster engraved.
 *
 * Line weight rules (from Epilog documentation):
 * - Lines ≤0.003" (0.216 points) → Vector cut
 * - Lines ≥0.006" (0.432 points) → Raster engrave
 */

import Foundation
import CoreGraphics
import ImageIO

/// Extracts vector paths from PDF documents for laser cutting
class PDFVectorExtractor {
    /// Maximum line width in points to be considered a vector cut (0.003" = 0.216pt)
    static let maxVectorLineWidth: CGFloat = 0.216

    /// Resolution for coordinate conversion (DPI)
    let resolution: Int

    /// Extracted vector paths
    private(set) var paths: [VectorPath] = []

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

    /// Graphics state for tracking stroke properties
    struct GraphicsState {
        var lineWidth: CGFloat = 1.0
        var strokeColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        var fillColor: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        var ctm: CGAffineTransform = .identity
    }

    init(resolution: Int = 500) {
        self.resolution = resolution
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
        pageHeightPixels = Int(ceil(mediaBox.height * scale))

        // Set up CTM to scale from points to pixels
        currentState.ctm = CGAffineTransform(scaleX: scale, y: scale)

        // Parse the content stream
        let contentStream = CGPDFContentStreamCreateWithPage(page)
        let operatorTable = createOperatorTable()
        let scanner = CGPDFScannerCreate(contentStream, operatorTable, Unmanaged.passUnretained(self).toOpaque())

        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contentStream)
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

        return table
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

    private func strokePath() {
        guard let path = currentPath else { return }

        // Check if line width qualifies for vector cutting
        let scaledLineWidth = currentState.lineWidth * abs(currentState.ctm.a)
        let lineWidthInPoints = scaledLineWidth / (CGFloat(resolution) / 72.0)

        if lineWidthInPoints <= Self.maxVectorLineWidth {
            // This is a vector cut path
            let vectorPath = convertToVectorPath(path, useFillColor: false)
            if !vectorPath.commands.isEmpty {
                paths.append(vectorPath)
            }
        }
        // If line width is too large, it will be rasterized instead

        currentPath = nil
    }

    /// Fill path - extract boundary as vector cut
    /// For laser cutting, filled shapes become cut outlines
    private func fillPath() {
        guard let path = currentPath else { return }

        // For filled paths, always extract the boundary as a vector cut
        // The fill operation defines the shape boundary which is what we want to cut
        let vectorPath = convertToVectorPath(path, useFillColor: true)
        if !vectorPath.commands.isEmpty {
            paths.append(vectorPath)
            fputs("DEBUG: Extracted fill path with \(vectorPath.commands.count) commands\n", stderr)
        }

        currentPath = nil
    }

    /// Combined fill and stroke - extract both as vector paths
    private func fillAndStrokePath() {
        guard let path = currentPath else { return }

        // Extract path with stroke color (stroke takes precedence for combined operations)
        let vectorPath = convertToVectorPath(path, useFillColor: false)
        if !vectorPath.commands.isEmpty {
            paths.append(vectorPath)
        }

        currentPath = nil
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
