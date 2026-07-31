/*
 * SVGArtworkImporter.swift - Read an SVG into the artwork model
 *
 * SVG matters here because it is the one interchange format that survives a
 * round trip through a design tool with its colours and its geometry intact.
 * A PDF exported from a drawing application has usually been through a print
 * pipeline that flattened, colour-managed and re-encoded everything; an SVG
 * says what the artist drew.
 *
 * Scope: shapes, paths, groups, transforms and presentation attributes - the
 * parts that describe geometry. Not text (no font machinery here), not
 * filters, not gradients as gradients: a gradient fill resolves to its first
 * stop so the shape still appears rather than vanishing.
 */

import Foundation
import CoreGraphics

public enum SVGArtworkImporter {

    /// Read an SVG file.
    public static func importArtwork(from url: URL) throws -> Artwork {
        guard let data = try? Data(contentsOf: url) else {
            throw ArtworkImportError.unreadableFile(url)
        }
        return try importArtwork(from: data,
                                 name: url.deletingPathExtension().lastPathComponent)
    }

    public static func importArtwork(from data: Data, name: String) throws -> Artwork {
        let parser = XMLParser(data: data)
        let delegate = SVGParserDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "malformed XML"
            throw ArtworkImportError.malformed(reason)
        }
        guard delegate.sawSVGRoot else {
            throw ArtworkImportError.malformed("no <svg> element")
        }

        let size = delegate.documentSize
        guard size.width > 0, size.height > 0 else {
            throw ArtworkImportError.malformed("the <svg> element declares no usable size")
        }

        EpilogLog.debug("Imported \(name): \(delegate.paths.count) SVG shape(s), "
                        + String(format: "canvas %.1f x %.1f pt", size.width, size.height))

        // Say so rather than quietly dropping it. Turning <text> into outlines
        // means resolving font families, weights and hinting the way a browser
        // does, and a laser file with silently missing words is worse than one
        // that says up front it cannot read them.
        if delegate.textCount > 0 {
            EpilogLog.warning("\(name) contains \(delegate.textCount) piece(s) of live text, "
                              + "which cannot be engraved from an SVG. Convert the text to "
                              + "outlines in the application that drew it, and export again.")
        }
        if delegate.imageCount > 0 {
            EpilogLog.warning("\(name) embeds \(delegate.imageCount) image(s), which are not "
                              + "read from SVG. Export the artwork as PDF if the image matters.")
        }

        return Artwork(name: name,
                       size: size,
                       paths: delegate.paths,
                       source: .pathsOnly,
                       paintedOperatorCount: delegate.shapeCount,
                       imageCount: delegate.imageCount)
    }
}

// MARK: - Parser

private final class SVGParserDelegate: NSObject, XMLParserDelegate {

    struct Style {
        var fill: RGBColor? = .black          // SVG's initial fill is black
        var stroke: RGBColor? = nil
        var strokeWidth: CGFloat = 1
        var evenOdd = false
        var hidden = false
    }

    private(set) var paths: [ArtworkPath] = []
    private(set) var shapeCount = 0
    private(set) var imageCount = 0
    private(set) var textCount = 0
    private(set) var sawSVGRoot = false
    private(set) var documentSize = CGSize.zero

    /// Transform from SVG user units to document points.
    private var rootTransform: CGAffineTransform = .identity

    private var styleStack: [Style] = [Style()]
    private var transformStack: [CGAffineTransform] = [.identity]

    /// Depth of <defs>/<clipPath>/<mask> nesting. Content inside is a template
    /// or a mask, not something drawn, so it must not become geometry.
    private var suppressedDepth = 0

    private var style: Style { styleStack.last ?? Style() }
    private var transform: CGAffineTransform { transformStack.last ?? .identity }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attrs: [String: String]) {

        let tag = name.contains(":") ? String(name.split(separator: ":").last!) : name

        if tag == "svg" && !sawSVGRoot {
            sawSVGRoot = true
            configureRoot(attrs)
        }

        if ["defs", "clipPath", "mask", "symbol", "pattern", "marker"].contains(tag) {
            suppressedDepth += 1
        }

        // Inherit, then override with whatever this element declares.
        var s = style
        applyPresentation(attrs, to: &s)
        styleStack.append(s)

        var t = transform
        if let spec = attrs["transform"], let m = SVGTransform.parse(spec) {
            t = m.concatenating(t)
        }
        transformStack.append(t)

        guard suppressedDepth == 0, !s.hidden else { return }

        if tag == "image" { imageCount += 1; return }
        if tag == "text" || tag == "tspan" { textCount += 1; return }

        if let path = geometry(for: tag, attrs: attrs) {
            shapeCount += 1
            emit(path, style: s, transform: t)
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let tag = name.contains(":") ? String(name.split(separator: ":").last!) : name
        if ["defs", "clipPath", "mask", "symbol", "pattern", "marker"].contains(tag) {
            suppressedDepth = max(0, suppressedDepth - 1)
        }
        if styleStack.count > 1 { styleStack.removeLast() }
        if transformStack.count > 1 { transformStack.removeLast() }
    }

    // MARK: Root sizing

    private func configureRoot(_ attrs: [String: String]) {
        let viewBox = attrs["viewBox"].flatMap(parseViewBox)

        // width/height may be absent, a percentage, or carry a unit. When they
        // are unusable the viewBox is the size, treated as points - which is
        // what a viewBox-only SVG from a drawing tool means in practice.
        let declaredW = attrs["width"].flatMap { SVGLength.points($0) }
        let declaredH = attrs["height"].flatMap { SVGLength.points($0) }

        if let box = viewBox, box.width > 0, box.height > 0 {
            let w = declaredW ?? box.width
            let h = declaredH ?? box.height
            documentSize = CGSize(width: w, height: h)
            // Map the viewBox onto the canvas, preserving aspect ratio the way
            // the default preserveAspectRatio="xMidYMid meet" does.
            let scale = min(w / box.width, h / box.height)
            let dx = (w - box.width * scale) / 2
            let dy = (h - box.height * scale) / 2
            rootTransform = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: dx, y: dy))
        } else if let w = declaredW, let h = declaredH, w > 0, h > 0 {
            documentSize = CGSize(width: w, height: h)
            rootTransform = .identity
        }
    }

    private func parseViewBox(_ s: String) -> CGRect? {
        let n = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
                 .compactMap { Double($0) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    // MARK: Presentation attributes

    private func applyPresentation(_ attrs: [String: String], to s: inout Style) {
        // An inline style="" wins over presentation attributes, so merge them
        // in that order.
        var props = attrs
        if let css = attrs["style"] {
            for decl in css.split(separator: ";") {
                let parts = decl.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                props[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        if let v = props["display"], v.trimmingCharacters(in: .whitespaces) == "none" {
            s.hidden = true
        }
        if let v = props["visibility"], v.trimmingCharacters(in: .whitespaces) == "hidden" {
            s.hidden = true
        }
        if let v = props["fill"] { s.fill = SVGColor.parse(v) }
        if let v = props["stroke"] { s.stroke = SVGColor.parse(v) }
        if let v = props["stroke-width"], let w = SVGLength.points(v) { s.strokeWidth = w }
        if let v = props["fill-rule"] { s.evenOdd = v.contains("evenodd") }

        // A fully transparent paint is not paint. Opacity between the two is
        // treated as painted: the laser has no notion of partial coverage, and
        // silently dropping a 90%-opaque shape would be worse than engraving it.
        if let v = props["fill-opacity"], let o = Double(v), o <= 0.01 { s.fill = nil }
        if let v = props["stroke-opacity"], let o = Double(v), o <= 0.01 { s.stroke = nil }
        if let v = props["opacity"], let o = Double(v), o <= 0.01 { s.hidden = true }
    }

    // MARK: Geometry

    private func geometry(for tag: String, attrs: [String: String]) -> CGPath? {
        func num(_ key: String, _ fallback: CGFloat = 0) -> CGFloat {
            attrs[key].flatMap { SVGLength.points($0) } ?? fallback
        }

        switch tag {
        case "path":
            guard let d = attrs["d"] else { return nil }
            return SVGPathData.parse(d)

        case "rect":
            let w = num("width"), h = num("height")
            guard w > 0, h > 0 else { return nil }
            let rect = CGRect(x: num("x"), y: num("y"), width: w, height: h)
            // rx/ry each default to the other when only one is given.
            var rx = attrs["rx"].flatMap { SVGLength.points($0) }
            var ry = attrs["ry"].flatMap { SVGLength.points($0) }
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            if let rx, let ry, rx > 0, ry > 0 {
                return CGPath(roundedRect: rect,
                              cornerWidth: min(rx, w / 2),
                              cornerHeight: min(ry, h / 2),
                              transform: nil)
            }
            return CGPath(rect: rect, transform: nil)

        case "circle":
            let r = num("r")
            guard r > 0 else { return nil }
            let c = CGPoint(x: num("cx"), y: num("cy"))
            return CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2),
                          transform: nil)

        case "ellipse":
            let rx = num("rx"), ry = num("ry")
            guard rx > 0, ry > 0 else { return nil }
            let c = CGPoint(x: num("cx"), y: num("cy"))
            return CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry,
                                            width: rx * 2, height: ry * 2),
                          transform: nil)

        case "line":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: num("x1"), y: num("y1")))
            p.addLine(to: CGPoint(x: num("x2"), y: num("y2")))
            return p

        case "polyline", "polygon":
            guard let pts = attrs["points"] else { return nil }
            let n = pts.split(whereSeparator: { " ,\n\t\r".contains($0) }).compactMap { Double($0) }
            guard n.count >= 4 else { return nil }
            let p = CGMutablePath()
            p.move(to: CGPoint(x: n[0], y: n[1]))
            var i = 2
            while i + 1 < n.count {
                p.addLine(to: CGPoint(x: n[i], y: n[i + 1]))
                i += 2
            }
            if tag == "polygon" { p.closeSubpath() }
            return p

        default:
            return nil
        }
    }

    private func emit(_ path: CGPath, style s: Style, transform t: CGAffineTransform) {
        guard s.fill != nil || s.stroke != nil else { return }

        var full = t.concatenating(rootTransform)
        guard let transformed = path.copy(using: &full) else { return }
        guard !transformed.isEmpty else { return }

        // Stroke width scales with the transform, same as it does when drawn.
        let scale = sqrt(abs(full.a * full.d - full.b * full.c))

        paths.append(ArtworkPath(path: transformed,
                                 stroke: s.stroke,
                                 strokeWidth: max(0.05, s.strokeWidth * scale),
                                 fill: s.fill,
                                 usesEvenOdd: s.evenOdd))
    }
}

// MARK: - Lengths

enum SVGLength {
    /// Convert an SVG length to points. Unitless values are user units, which
    /// at the root are points.
    static func points(_ raw: String) -> CGFloat? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let units: [(String, CGFloat)] = [
            ("px", 1), ("pt", 1), ("pc", 12),
            ("mm", 72.0 / 25.4), ("cm", 72.0 / 2.54), ("in", 72),
        ]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            guard let v = Double(s.dropLast(suffix.count)
                                  .trimmingCharacters(in: .whitespaces)) else { return nil }
            return CGFloat(v) * factor
        }
        // A percentage has no meaning without a viewport to be a percentage of.
        if s.hasSuffix("%") { return nil }
        return Double(s).map { CGFloat($0) }
    }
}

// MARK: - Colours

enum SVGColor {
    static func parse(_ raw: String) -> RGBColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty || s == "none" || s == "transparent" { return nil }

        // A gradient or pattern reference: resolve to something visible rather
        // than dropping the shape. The geometry is what matters for cutting,
        // and for engraving a mid-grey stands in better than nothing.
        if s.hasPrefix("url(") { return RGBColor(r: 0.5, g: 0.5, b: 0.5) }
        if s == "currentcolor" { return .black }

        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            if hex.count == 3, let v = Int(hex, radix: 16) {
                // #rgb expands each nibble: #1a2 -> #11aa22
                let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
                return RGBColor(r8: UInt8(r * 17), g8: UInt8(g * 17), b8: UInt8(b * 17))
            }
            if hex.count == 6, let v = Int(hex, radix: 16) {
                return RGBColor(r8: UInt8((v >> 16) & 0xFF),
                                g8: UInt8((v >> 8) & 0xFF),
                                b8: UInt8(v & 0xFF))
            }
            return nil
        }

        if s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") {
            let body = s[s.index(after: open)..<close]
            let parts = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            guard parts.count >= 3 else { return nil }
            func channel(_ t: Substring) -> Double? {
                if t.hasSuffix("%") { return Double(t.dropLast()).map { $0 / 100 } }
                return Double(t).map { $0 / 255 }
            }
            guard let r = channel(parts[0]), let g = channel(parts[1]),
                  let b = channel(parts[2]) else { return nil }
            return RGBColor(r: r, g: g, b: b)
        }

        return named[s]
    }

    /// The CSS colour keywords worth carrying. The full list is 147 entries of
    /// which these are the ones that turn up in artwork, plus every keyword
    /// that maps to one of the six the laser routes by colour.
    static let named: [String: RGBColor] = [
        "black":   RGBColor(r8: 0, g8: 0, b8: 0),
        "white":   RGBColor(r8: 255, g8: 255, b8: 255),
        "red":     RGBColor(r8: 255, g8: 0, b8: 0),
        "lime":    RGBColor(r8: 0, g8: 255, b8: 0),
        "green":   RGBColor(r8: 0, g8: 128, b8: 0),
        "blue":    RGBColor(r8: 0, g8: 0, b8: 255),
        "cyan":    RGBColor(r8: 0, g8: 255, b8: 255),
        "aqua":    RGBColor(r8: 0, g8: 255, b8: 255),
        "magenta": RGBColor(r8: 255, g8: 0, b8: 255),
        "fuchsia": RGBColor(r8: 255, g8: 0, b8: 255),
        "yellow":  RGBColor(r8: 255, g8: 255, b8: 0),
        "gray":    RGBColor(r8: 128, g8: 128, b8: 128),
        "grey":    RGBColor(r8: 128, g8: 128, b8: 128),
        "silver":  RGBColor(r8: 192, g8: 192, b8: 192),
        "maroon":  RGBColor(r8: 128, g8: 0, b8: 0),
        "olive":   RGBColor(r8: 128, g8: 128, b8: 0),
        "navy":    RGBColor(r8: 0, g8: 0, b8: 128),
        "teal":    RGBColor(r8: 0, g8: 128, b8: 128),
        "purple":  RGBColor(r8: 128, g8: 0, b8: 128),
        "orange":  RGBColor(r8: 255, g8: 165, b8: 0),
        "pink":    RGBColor(r8: 255, g8: 192, b8: 203),
        "brown":   RGBColor(r8: 165, g8: 42, b8: 42),
    ]
}

// MARK: - transform="" attribute

enum SVGTransform {
    static func parse(_ spec: String) -> CGAffineTransform? {
        var result = CGAffineTransform.identity
        var found = false

        var rest = Substring(spec)
        while let open = rest.firstIndex(of: "(") {
            let name = rest[rest.startIndex..<open]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t\r"))
            guard let close = rest[open...].firstIndex(of: ")") else { break }
            let args = rest[rest.index(after: open)..<close]
                .split(whereSeparator: { " ,\n\t\r".contains($0) })
                .compactMap { Double($0) }
                .map { CGFloat($0) }
            rest = rest[rest.index(after: close)...]

            let m: CGAffineTransform?
            switch name {
            case "matrix":
                m = args.count == 6 ? CGAffineTransform(a: args[0], b: args[1], c: args[2],
                                                        d: args[3], tx: args[4], ty: args[5]) : nil
            case "translate":
                m = args.isEmpty ? nil
                    : CGAffineTransform(translationX: args[0], y: args.count > 1 ? args[1] : 0)
            case "scale":
                m = args.isEmpty ? nil
                    : CGAffineTransform(scaleX: args[0], y: args.count > 1 ? args[1] : args[0])
            case "rotate":
                if args.count >= 3 {
                    // rotate(a, cx, cy) turns about a point rather than the origin
                    m = CGAffineTransform(translationX: -args[1], y: -args[2])
                        .concatenating(CGAffineTransform(rotationAngle: args[0] * .pi / 180))
                        .concatenating(CGAffineTransform(translationX: args[1], y: args[2]))
                } else if args.count == 1 {
                    m = CGAffineTransform(rotationAngle: args[0] * .pi / 180)
                } else { m = nil }
            case "skewX":
                m = args.count == 1
                    ? CGAffineTransform(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, tx: 0, ty: 0)
                    : nil
            case "skewY":
                m = args.count == 1
                    ? CGAffineTransform(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
                    : nil
            default:
                m = nil
            }

            if let m {
                // Listed transforms apply left to right, i.e. the leftmost is
                // outermost, so each new one is composed on the inside.
                result = m.concatenating(result)
                found = true
            }
        }

        return found ? result : nil
    }
}

// MARK: - Path data

enum SVGPathData {
    /// Parse an SVG `d` attribute into a CGPath.
    static func parse(_ d: String) -> CGPath? {
        let path = CGMutablePath()
        var scanner = Lexer(d)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // Reflection of the previous curve's second control point, for S/T.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character = " "
        var started = false

        func ensureStart() {
            if !started { path.move(to: current); started = true }
        }

        while true {
            scanner.skipSeparators()
            if scanner.atEnd { break }

            if let c = scanner.peekCommand() {
                command = c
                scanner.advance()
            } else if command == " " {
                break   // numbers before any command: malformed
            } else if command == "M" {
                command = "L"    // repeated moveto operands are implicit linetos
            } else if command == "m" {
                command = "l"
            }

            let relative = command.isLowercase
            let cmd = Character(command.uppercased())

            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch cmd {
            case "M":
                guard let p = point() else { return finish(path, started) }
                path.move(to: p)
                current = p; subpathStart = p; started = true
                lastCubicControl = nil; lastQuadControl = nil

            case "L":
                guard let p = point() else { return finish(path, started) }
                ensureStart(); path.addLine(to: p); current = p
                lastCubicControl = nil; lastQuadControl = nil

            case "H":
                guard let x = scanner.number() else { return finish(path, started) }
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                ensureStart(); path.addLine(to: p); current = p
                lastCubicControl = nil; lastQuadControl = nil

            case "V":
                guard let y = scanner.number() else { return finish(path, started) }
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                ensureStart(); path.addLine(to: p); current = p
                lastCubicControl = nil; lastQuadControl = nil

            case "C":
                guard let c1 = point(), let c2 = point(), let end = point() else {
                    return finish(path, started)
                }
                ensureStart(); path.addCurve(to: end, control1: c1, control2: c2)
                current = end; lastCubicControl = c2; lastQuadControl = nil

            case "S":
                guard let c2 = point(), let end = point() else { return finish(path, started) }
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                ensureStart(); path.addCurve(to: end, control1: c1, control2: c2)
                current = end; lastCubicControl = c2; lastQuadControl = nil

            case "Q":
                guard let c = point(), let end = point() else { return finish(path, started) }
                ensureStart(); path.addQuadCurve(to: end, control: c)
                current = end; lastQuadControl = c; lastCubicControl = nil

            case "T":
                guard let end = point() else { return finish(path, started) }
                let c = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                ensureStart(); path.addQuadCurve(to: end, control: c)
                current = end; lastQuadControl = c; lastCubicControl = nil

            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rot = scanner.number(), let largeArc = scanner.flag(),
                      let sweep = scanner.flag(), let end = point() else {
                    return finish(path, started)
                }
                ensureStart()
                appendArc(to: path, from: current, to: end, rx: rx, ry: ry,
                          rotationDegrees: rot, largeArc: largeArc, sweep: sweep)
                current = end; lastCubicControl = nil; lastQuadControl = nil

            case "Z":
                if started { path.closeSubpath() }
                current = subpathStart
                lastCubicControl = nil; lastQuadControl = nil

            default:
                return finish(path, started)
            }
        }

        return finish(path, started)
    }

    private static func finish(_ path: CGMutablePath, _ started: Bool) -> CGPath? {
        (started && !path.isEmpty) ? path.copy() : nil
    }

    /// Append an SVG elliptical arc as a series of cubic Beziers.
    ///
    /// Follows the endpoint-to-centre conversion in the SVG specification's
    /// implementation notes (appendix F.6).
    private static func appendArc(to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
                                  rx rxIn: CGFloat, ry ryIn: CGFloat,
                                  rotationDegrees: CGFloat, largeArc: Bool, sweep: Bool) {
        // Degenerate radii mean a straight line, per the spec.
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx < 1e-9 || ry < 1e-9 || (abs(p0.x - p1.x) < 1e-12 && abs(p0.y - p1.y) < 1e-12) {
            path.addLine(to: p1)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1 =  cosPhi * dx2 + sinPhi * dy2
        let y1 = -sinPhi * dx2 + cosPhi * dy2

        // Scale the radii up if they are too small to span the endpoints.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s; ry *= s
        }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = sign * sqrt(max(0, num / max(den, 1e-12)))

        let cx1 =  coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx

        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(1, max(-1, dot / max(len, 1e-12))))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let startAngle = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry,
                          (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // A cubic approximates at most a quarter turn well.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        // Control point distance for a circular arc of this sweep.
        let alpha = 4.0 / 3.0 * tan(step / 4)

        var theta = startAngle
        for _ in 0..<segments {
            let next = theta + step

            let cosA = cos(theta), sinA = sin(theta)
            let cosB = cos(next),  sinB = sin(next)

            func map(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                CGPoint(x: cx + cosPhi * rx * ex - sinPhi * ry * ey,
                        y: cy + sinPhi * rx * ex + cosPhi * ry * ey)
            }

            let end = map(cosB, sinB)
            let c1 = map(cosA - alpha * sinA, sinA + alpha * cosA)
            let c2 = map(cosB + alpha * sinB, sinB - alpha * cosB)

            path.addCurve(to: end, control1: c1, control2: c2)
            theta = next
        }
    }

    /// Minimal tokenizer for path data, which is not whitespace-delimited:
    /// "M10-20.5.3" is three numbers.
    private struct Lexer {
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        var atEnd: Bool { i >= chars.count }

        mutating func advance() { i += 1 }

        mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n"
                    || chars[i] == "\r" || chars[i] == "\t" {
                i += 1
            }
        }

        func peekCommand() -> Character? {
            guard i < chars.count else { return nil }
            let c = chars[i]
            return "MmLlHhVvCcSsQqTtAaZz".contains(c) ? c : nil
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = i
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            var digits = false
            while i < chars.count, chars[i].isNumber { i += 1; digits = true }
            if i < chars.count, chars[i] == "." {
                i += 1
                while i < chars.count, chars[i].isNumber { i += 1; digits = true }
            }
            guard digits else { i = start; return nil }
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                let mark = i
                i += 1
                if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
                var expDigits = false
                while i < chars.count, chars[i].isNumber { i += 1; expDigits = true }
                if !expDigits { i = mark }
            }
            return Double(String(chars[start..<i])).map { CGFloat($0) }
        }

        /// Arc flags are single characters and need not be separated from what
        /// follows: "a1 1 0 011 1" packs two flags and a coordinate together.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count else { return nil }
            switch chars[i] {
            case "0": i += 1; return false
            case "1": i += 1; return true
            default:  return nil
            }
        }
    }
}
