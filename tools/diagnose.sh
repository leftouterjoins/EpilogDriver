#!/bin/bash
#
# diagnose.sh - Report the installed Epilog driver's state and prove whether it
# can extract vector cuts. Run on any machine where cuts are not happening.
#
# Self-contained: needs only a stock macOS. No sudo required.
#
FILTER=/Library/Printers/Epilog/Filters/rastertoepiloz
LINK=/usr/libexec/cups/filter/rastertoepiloz
PPDDIR=/Library/Printers/PPDs/Contents/Resources
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==================================================================="
echo " INSTALLED DRIVER"
echo "==================================================================="
if [ -f "$FILTER" ]; then
    ls -l "$FILTER"
    echo "  md5 : $(md5 -q "$FILTER" 2>/dev/null)"
    echo "  arch: $(lipo -archs "$FILTER" 2>/dev/null)"
else
    echo "  MISSING: $FILTER"
fi
echo
echo "CUPS filter link:"
ls -l "$LINK" 2>&1 | sed 's/^/  /'
if [ -f "$LINK" ] && [ ! -L "$LINK" ]; then
    echo "  [!] This is a REAL FILE, not a symlink to the installed driver."
    echo "      A stale binary here shadows the installed one. md5: $(md5 -q "$LINK")"
fi
echo
echo "Installed package receipts:"
pkgutil --pkgs | grep -i epilog | while read -r p; do
    echo "  $p  version $(pkgutil --pkg-info "$p" | awk '/^version:/{print $2}')"
done

echo
echo "==================================================================="
echo " PPDs"
echo "==================================================================="
for f in "$PPDDIR"/EpilogZing*.ppd; do
    [ -f "$f" ] || continue
    echo "$(basename "$f"):"
    grep -E "^\*ColorDevice|^\*DefaultColorModel|^\*DefaultTestFrame" "$f" | sed 's/^/    /'
    grep -q "TestFrame" "$f" && echo "    has TestFrame option: yes" || echo "    has TestFrame option: NO (pre-1.6 PPD)"
done

echo
echo "Print queues using this driver:"
for q in $(lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\):.*/\1/p'); do
    qppd="/etc/cups/ppd/$q.ppd"
    if [ -r "$qppd" ] && grep -qi epilog "$qppd" 2>/dev/null; then
        echo "  $q"
        grep -E "^\*ColorDevice|^\*DefaultColorModel" "$qppd" | sed 's/^/      /'
        grep -q "TestFrame" "$qppd" \
            && echo "      queue PPD is current" \
            || echo "      [!] queue PPD is STALE - it predates the current install."
        echo "          CUPS caches a copy per queue; installing a new PPD does"
        echo "          not update it. Fix: sudo lpadmin -p $q -P $PPDDIR/EpilogZing24.ppd"
    fi
done

echo
echo "==================================================================="
echo " FUNCTIONAL TEST - can this driver extract vector cuts?"
echo "==================================================================="
python3 - "$TMP/test.pdf" <<'PYEOF'
import sys, zlib
# 1in black filled square (engrave) + 1in cyan hairline square (cut), bed page
content = b"""
0 0 0 rg
144 432 72 72 re
f
0 1 1 RG
1 w
144 648 72 72 re
S
"""
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1728 864] /Contents 4 0 R /Resources << >> >>",
    b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
]
out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offs = []
for i, o in enumerate(objs, 1):
    offs.append(len(out))
    out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
x = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for o in offs:
    out += b"%010d 00000 n \n" % o
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
open(sys.argv[1], "wb").write(bytes(out))
PYEOF

if [ ! -f "$FILTER" ]; then
    echo "  cannot test - driver not installed"
    exit 1
fi

"$FILTER" 1 "$USER" DiagTest 1 \
    "Resolution=500dpi RasterPower=50 RasterSpeed=50 VectorPower=50 VectorSpeed=50 VectorFrequency=2500 JobType=Combined RasterMode=Bitmap" \
    "$TMP/test.pdf" > "$TMP/out.prn" 2> "$TMP/err.txt"

paths=$(sed -n 's/.*Extracted \([0-9][0-9]*\) vector paths.*/\1/p' "$TMP/err.txt" | tail -1)
paths=${paths:-0}
hpgl=$(python3 -c "
d=open('$TMP/out.prn','rb').read()
i=d.find(b'\x1b%1B')
seg=d[i:d.find(b'\x1bE',i)] if i>=0 else b''
import re
print(len(re.findall(rb'PD', seg)))
" 2>/dev/null)

echo "  job size          : $(wc -c < "$TMP/out.prn" | tr -d ' ') bytes"
echo "  vector paths found: $paths"
echo "  HPGL pen-downs    : $hpgl"
grep -E "Extracted|Has vector|WARNING" "$TMP/err.txt" | sed 's/^/    /'
echo
if [ "$paths" -ge 1 ] && [ "$hpgl" -ge 1 ]; then
    echo "  RESULT: driver extracts cuts correctly."
    echo "          If your real job still does not cut, the problem is the"
    echo "          DOCUMENT, not the driver. Printing straight from an app that"
    echo "          flattens its output (Pixelmator Pro does) sends a bitmap with"
    echo "          no paths in it. Export to PDF, rescale to the bed, print that."
else
    echo "  RESULT: [!] this driver did NOT extract cuts from a known-good PDF."
    echo "          The installed binary is older than v1.5.0, or something is"
    echo "          shadowing it. Check the CUPS filter link above."
fi
