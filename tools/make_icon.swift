#!/usr/bin/env swift
/*
 * make_icon.swift - Draw the application icon
 *
 * Generated rather than checked in, so the icon is readable, reviewable and
 * adjustable in a diff instead of being an opaque binary. Run through
 * Installer/build-app.sh, which turns the PNG into an .icns.
 *
 * usage: swift tools/make_icon.swift <out.png> [size]
 */

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <out.png> [size]\n".utf8))
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[1])
let size = arguments.count > 2 ? (Int(arguments[2]) ?? 1024) : 1024

let scale = CGFloat(size) / 1024.0
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
ctx.scaleBy(x: scale, y: scale)
ctx.setShouldAntialias(true)

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// macOS icons sit inside a rounded square with a margin all round.
let inset: CGFloat = 92
let plate = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
let plateRadius: CGFloat = 185

let plateShape = CGPath(roundedRect: plate, cornerWidth: plateRadius,
                        cornerHeight: plateRadius, transform: nil)

// Body: a dark slab, like the machine.
ctx.saveGState()
ctx.addPath(plateShape)
ctx.clip()
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [color(58, 62, 72), color(28, 30, 36)] as CFArray,
                             locations: [0, 1]) {
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY), options: [])
}

// The bed, seen from above.
let bed = CGRect(x: 250, y: 250, width: 524, height: 380)
ctx.setFillColor(color(20, 22, 26))
ctx.fill(bed)

// Honeycomb suggestion: a light grid, faint enough to read as texture.
ctx.setStrokeColor(color(255, 255, 255, 0.06))
ctx.setLineWidth(3)
var gx = bed.minX
while gx <= bed.maxX {
    ctx.move(to: CGPoint(x: gx, y: bed.minY))
    ctx.addLine(to: CGPoint(x: gx, y: bed.maxY))
    gx += 44
}
var gy = bed.minY
while gy <= bed.maxY {
    ctx.move(to: CGPoint(x: bed.minX, y: gy))
    ctx.addLine(to: CGPoint(x: bed.maxX, y: gy))
    gy += 44
}
ctx.strokePath()

// The cut line: cyan, because that is the colour this whole project routes to
// the cutter, and it is the thing the application exists to get right.
ctx.setStrokeColor(color(64, 224, 234))
ctx.setLineWidth(22)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let cut = CGMutablePath()
cut.move(to: CGPoint(x: 330, y: 340))
cut.addCurve(to: CGPoint(x: 520, y: 520),
             control1: CGPoint(x: 330, y: 470), control2: CGPoint(x: 420, y: 520))
cut.addCurve(to: CGPoint(x: 700, y: 340),
             control1: CGPoint(x: 620, y: 520), control2: CGPoint(x: 700, y: 470))
ctx.addPath(cut)
ctx.strokePath()

// The beam, coming down to where it is working.
let focus = CGPoint(x: 700, y: 340)
ctx.saveGState()
let beam = CGMutablePath()
beam.move(to: CGPoint(x: focus.x - 62, y: 780))
beam.addLine(to: CGPoint(x: focus.x + 62, y: 780))
beam.addLine(to: CGPoint(x: focus.x + 9, y: focus.y))
beam.addLine(to: CGPoint(x: focus.x - 9, y: focus.y))
beam.closeSubpath()
ctx.addPath(beam)
ctx.clip()
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [color(255, 140, 40, 0.05),
                                      color(255, 176, 74, 0.85)] as CFArray,
                             locations: [0, 1]) {
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 780),
                           end: CGPoint(x: 0, y: focus.y), options: [])
}
ctx.restoreGState()

// The glow where it lands.
if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [color(255, 236, 190, 0.95),
                                  color(255, 150, 50, 0.55),
                                  color(255, 120, 30, 0)] as CFArray,
                         locations: [0, 0.35, 1]) {
    ctx.drawRadialGradient(glow, startCenter: focus, startRadius: 0,
                           endCenter: focus, endRadius: 96, options: [])
}

ctx.restoreGState()

// A hairline rim, so the icon has an edge on a dark background too.
ctx.addPath(plateShape)
ctx.setStrokeColor(color(255, 255, 255, 0.13))
ctx.setLineWidth(4)
ctx.strokePath()

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
