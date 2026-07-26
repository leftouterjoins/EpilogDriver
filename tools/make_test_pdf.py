#!/usr/bin/env python3
"""Generate small hand-built PDFs that mimic what an app sends to the print queue."""
import sys, zlib

def build_pdf(content, w, h):
    objs = []
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(f"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".encode())
    objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h}] /Contents 4 0 R /Resources << >> >>".encode())
    cs = content.encode()
    objs.append(f"<< /Length {len(cs)} >>\nstream\n".encode() + cs + b"\nendstream")

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, o in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs)+1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


# Zing 24 full bed page, as CUPS would hand it over for DefaultPageSize Zing24Bed
W, H = 1728, 864

# A "design": a 2x2in filled black square at (1in,1in), and a hairline-stroked
# 3x2in rectangle at (4in,1in) - i.e. one raster-ish shape and one cut-ish shape.
DESIGN = """
0 0 0 rg
72 72 144 144 re
f
0 0 0 RG
0.1 w
288 72 216 144 re
S
"""

# Vector-only: just the hairline rectangle
VECTOR_ONLY = """
0 0 0 RG
0.1 w
288 72 216 144 re
S
"""

# Typical Pixelmator-style: 1pt stroke (too fat for the 0.216pt vector threshold)
FAT_STROKE = """
0 0 0 RG
1 w
288 72 216 144 re
S
"""

# Realistic combined job: black 2x2in filled square to ENGRAVE,
# plus a red 1pt 3x2in rectangle to CUT (red = cut color, 1pt = normal app stroke).
COMBINED = """
0 0 0 rg
72 72 144 144 re
f
1 0 0 RG
1 w
288 72 216 144 re
S
"""

# Same, but the cut outline is drawn in CMYK red to exercise the `K` operator.
COMBINED_CMYK = """
0 0 0 rg
72 72 144 144 re
f
0 1 1 0 K
1 w
288 72 216 144 re
S
"""

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "design"
    out = sys.argv[2] if len(sys.argv) > 2 else "test.pdf"
    content = {"design": DESIGN, "vector": VECTOR_ONLY, "fat": FAT_STROKE,
               "combined": COMBINED, "cmyk": COMBINED_CMYK}[which]
    open(out, "wb").write(build_pdf(content, W, H))
    print(f"wrote {out} ({which}) page {W}x{H}pt")
