// Render a PDF and report the most saturated pixels found, to see whether
// colour survived the print pipeline.
// usage: swift sample.swift <pdf> [dpi]
import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else { exit(1) }
let dpi = args.count >= 3 ? Double(args[2])! : 150.0

guard let doc = CGPDFDocument(URL(fileURLWithPath: args[1]) as CFURL),
      let page = doc.page(at: 1) else { exit(1) }

let box = page.getBoxRect(.mediaBox)
let scale = dpi / 72.0
let w = Int(Double(box.width) * scale), h = Int(Double(box.height) * scale)

var buf = [UInt8](repeating: 255, count: w * h * 4)
buf.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    ctx.drawPDFPage(page)
}

// Histogram by chroma (max-min channel spread)
var chromaticCount = 0
var greyInkCount = 0
var best: [(Int, Int, Int, Int, Int)] = []   // spread, r,g,b, x,y  (approx)
for y in 0..<h {
    for x in 0..<w {
        let o = (y * w + x) * 4
        let r = Int(buf[o]), g = Int(buf[o+1]), b = Int(buf[o+2])
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        let spread = mx - mn
        if spread >= 40 {
            chromaticCount += 1
            if best.count < 5 { best.append((spread, r, g, b, y * 100000 + x)) }
        } else if mx < 200 {
            greyInkCount += 1
        }
    }
}

print("file      : \(args[1])")
print("rendered  : \(w)x\(h) @ \(Int(dpi))dpi")
print("chromatic pixels (spread>=40): \(chromaticCount)")
print("grey ink pixels  (luma<200)  : \(greyInkCount)")
if !best.isEmpty {
    print("samples:")
    for (sp, r, g, b, pos) in best {
        print("   rgb(\(r),\(g),\(b))  spread=\(sp)  at (\(pos % 100000),\(pos / 100000))")
    }
} else {
    print("NO CHROMATIC PIXELS - all colour has been stripped")
}
