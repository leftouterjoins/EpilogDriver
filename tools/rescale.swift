// Rescale a PDF page to a target page size, preserving vectors.
// usage: swift rescale.swift <in.pdf> <out.pdf> <widthPt> <heightPt>
import Foundation
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 5,
      let outW = Double(args[3]), let outH = Double(args[4]) else {
    FileHandle.standardError.write("usage: rescale <in.pdf> <out.pdf> <wPt> <hPt>\n".data(using: .utf8)!)
    exit(1)
}

let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let doc = CGPDFDocument(inURL as CFURL), let page = doc.page(at: 1) else {
    FileHandle.standardError.write("cannot open input pdf\n".data(using: .utf8)!)
    exit(1)
}

let src = page.getBoxRect(.mediaBox)
var media = CGRect(x: 0, y: 0, width: outW, height: outH)

guard let ctx = CGContext(outURL as CFURL, mediaBox: &media, nil) else {
    FileHandle.standardError.write("cannot create output pdf\n".data(using: .utf8)!)
    exit(1)
}

// Fit the source page inside the target page, preserving aspect ratio.
let scale = min(outW / Double(src.width), outH / Double(src.height))
let dx = (outW - Double(src.width) * scale) / 2.0
let dy = (outH - Double(src.height) * scale) / 2.0

ctx.beginPage(mediaBox: &media)
ctx.saveGState()
ctx.translateBy(x: CGFloat(dx), y: CGFloat(dy))
ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
ctx.translateBy(x: -src.origin.x, y: -src.origin.y)
ctx.drawPDFPage(page)
ctx.restoreGState()
ctx.endPage()
ctx.closePDF()

print("in : \(Int(src.width)) x \(Int(src.height)) pt")
print("out: \(Int(outW)) x \(Int(outH)) pt   scale=\(String(format: "%.5f", scale))  offset=(\(Int(dx)), \(Int(dy)))")
print("wrote \(outURL.path)")
