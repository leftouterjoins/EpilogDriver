#!/bin/bash
#
# diagnose.sh - Report the installed Epilog driver's state and prove whether it
# can extract vector cuts. Run on any machine where cuts are not happening.
#
# Uses only what stock macOS ships. In particular it does NOT need python3,
# lipo, swift or the Xcode Command Line Tools: macOS has not shipped a usable
# python3 since 12.3, and on a machine without developer tools a python-based
# check silently produces nothing and looks like a driver fault.
#
# No sudo required.
#
FILTER=/Library/Printers/Epilog/Filters/rastertoepiloz
LINK=/usr/libexec/cups/filter/rastertoepiloz
PPDDIR=/Library/Printers/PPDs/Contents/Resources
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# macOS base64 spells decode -D on older releases and -d on newer ones.
b64decode() {
    base64 -d -i "$1" -o "$2" 2>/dev/null || base64 -D -i "$1" -o "$2" 2>/dev/null
}

# Report a Mach-O binary's architectures by reading its header, since lipo and
# file both belong to the developer tools.
cpuName() {
    case "$1" in
        01000007) echo "x86_64" ;;
        0100000c) echo "arm64" ;;
        00000007) echo "i386" ;;
        0000000c) echo "arm" ;;
        *)        echo "cputype:$1" ;;
    esac
}

archOf() {
    local f="$1" magic hex n i off cpu list=""
    magic=$(od -An -N4 -tx1 "$f" 2>/dev/null | tr -d ' \n')
    case "$magic" in
        cafebabe)
            # Fat header is big-endian: nfat_arch at offset 4, then an array of
            # fat_arch structs (20 bytes each) whose first word is the cputype.
            hex=$(od -An -j4 -N4 -tx1 "$f" 2>/dev/null | tr -d ' \n')
            n=$((16#$hex))
            [ "$n" -gt 16 ] && { echo "universal (unreadable arch count)"; return; }
            i=0
            while [ "$i" -lt "$n" ]; do
                off=$((8 + i * 20))
                cpu=$(od -An -j$off -N4 -tx1 "$f" 2>/dev/null | tr -d ' \n')
                list="$list $(cpuName "$cpu")"
                i=$((i + 1))
            done
            echo "universal:$list"
            ;;
        cffaedfe)
            # 64-bit Mach-O, little-endian: cputype at offset 4, byte-swapped
            hex=$(od -An -j4 -N4 -tx1 "$f" 2>/dev/null | tr -d ' \n')
            cpu="${hex:6:2}${hex:4:2}${hex:2:2}${hex:0:2}"
            echo "single arch ($(cpuName "$cpu"))"
            ;;
        feedfacf)
            hex=$(od -An -j4 -N4 -tx1 "$f" 2>/dev/null | tr -d ' \n')
            echo "single arch ($(cpuName "$hex"))"
            ;;
        *) echo "not a Mach-O binary (magic $magic)" ;;
    esac
}

echo "==================================================================="
echo " INSTALLED DRIVER"
echo "==================================================================="
if [ -f "$FILTER" ]; then
    ls -l "$FILTER"
    echo "  md5 : $(md5 -q "$FILTER" 2>/dev/null)"
    echo "  arch: $(archOf "$FILTER")"
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
pkgutil --pkgs 2>/dev/null | grep -i epilog | while read -r p; do
    echo "  $p  version $(pkgutil --pkg-info "$p" 2>/dev/null | awk '/^version:/{print $2}')"
done

echo
echo "==================================================================="
echo " PPDs"
echo "==================================================================="
for f in "$PPDDIR"/EpilogZing*.ppd; do
    [ -f "$f" ] || continue
    echo "$(basename "$f"):"
    grep -E "^\*ColorDevice|^\*DefaultColorModel|^\*DefaultTestFrame" "$f" | sed 's/^/    /'
    grep -q "TestFrame" "$f" && echo "    has TestFrame option: yes" \
                             || echo "    has TestFrame option: NO (pre-1.6 PPD)"
done

echo
echo "Print queues using this driver:"
found_queue=0
for q in $(lpstat -v 2>/dev/null | sed -n 's/^device for \([^:]*\):.*/\1/p'); do
    qppd="/etc/cups/ppd/$q.ppd"
    if [ -r "$qppd" ] && grep -qi epilog "$qppd" 2>/dev/null; then
        found_queue=1
        echo "  $q"
        grep -E "^\*ColorDevice|^\*DefaultColorModel" "$qppd" | sed 's/^/      /'
        # What the print dialog is actually offered. This is the signal that
        # matters: the file on disk can be current while CUPS still serves
        # something else.
        if [ -x /usr/bin/lpoptions ]; then
            if /usr/bin/lpoptions -p "$queue" -l 2>/dev/null | grep -qi "TestFrame"; then
                echo "      print dialog IS offered Test Frame"
            else
                echo "      [!] print dialog is NOT offered Test Frame"
            fi
        fi

        if grep -q "TestFrame" "$qppd"; then
            echo "      queue PPD is current"
        else
            echo "      [!] queue PPD is STALE - it predates the current install."
            echo "          CUPS caches a copy per queue; installing a new PPD does"
            echo "          not update it, so this queue is still on the old one."
            echo "          Fix: sudo lpadmin -p $q -P $PPDDIR/EpilogZing24.ppd"
        fi
    fi
done
[ "$found_queue" = "0" ] && echo "  (none found)"

echo
echo "==================================================================="
echo " FUNCTIONAL TEST - can this driver extract vector cuts?"
echo "==================================================================="

if [ ! -f "$FILTER" ]; then
    echo "  cannot test - driver not installed"
    exit 1
fi

# A 1in black filled square (engrave) plus a 1in cyan hairline square (cut),
# on a Zing 24 bed page. Embedded rather than generated so this needs no tools.
cat > "$TMP/test.b64" <<'PDFEOF'
JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4K
ZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4K
ZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAg
MCAxNzI4IDg2NF0gL0NvbnRlbnRzIDQgMCBSIC9SZXNvdXJjZXMgPDwgPj4gPj4KZW5kb2JqCjQg
MCBvYmoKPDwgL0xlbmd0aCA2MSA+PgpzdHJlYW0KCjAgMCAwIHJnCjE0NCA0MzIgNzIgNzIgcmUK
ZgowIDEgMSBSRwoxIHcKMTQ0IDY0OCA3MiA3MiByZQpTCgplbmRzdHJlYW0KZW5kb2JqCnhyZWYK
MCA1CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAwMDY0IDAw
MDAwIG4gCjAwMDAwMDAxMjEgMDAwMDAgbiAKMDAwMDAwMDIyNiAwMDAwMCBuIAp0cmFpbGVyCjw8
IC9TaXplIDUgL1Jvb3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjMzNwolJUVPRgo=
PDFEOF

b64decode "$TMP/test.b64" "$TMP/test.pdf"
if [ ! -s "$TMP/test.pdf" ]; then
    echo "  [!] could not decode the embedded test PDF - cannot run the test."
    echo "      This is a fault in this script, not in the driver."
    exit 1
fi

"$FILTER" 1 "$USER" DiagTest 1 \
    "Resolution=500dpi RasterPower=50 RasterSpeed=50 VectorPower=50 VectorSpeed=50 VectorFrequency=2500 JobType=Combined RasterMode=Bitmap" \
    "$TMP/test.pdf" > "$TMP/out.prn" 2> "$TMP/err.txt"
rc=$?

paths=$(sed -n 's/.*Extracted \([0-9][0-9]*\) vector paths.*/\1/p' "$TMP/err.txt" | tail -1)
paths=${paths:-0}
size=$(wc -c < "$TMP/out.prn" | tr -d ' ')
# Count pen-down commands. 'PD' followed by a digit is specific enough that
# raster bytes are very unlikely to match.
pd=$(LC_ALL=C grep -oa 'PD[0-9]' "$TMP/out.prn" 2>/dev/null | wc -l | tr -d ' ')

echo "  filter exit code  : $rc"
echo "  job size          : $size bytes"
echo "  vector paths found: $paths"
echo "  HPGL pen-downs    : $pd"
grep -E "Extracted|Has vector|WARNING|ERROR" "$TMP/err.txt" | sed 's/^/    /'
echo

if [ "$paths" -ge 1 ] && [ "$pd" -ge 1 ]; then
    echo "  RESULT: this driver extracts cuts correctly."
    echo
    echo "  If your real job still does not cut, the problem is the DOCUMENT,"
    echo "  not the driver. Printing straight from an application that flattens"
    echo "  its output - Pixelmator Pro does - sends a bitmap with no paths in"
    echo "  it, and nothing can cut from that. Export to PDF, rescale to the bed"
    echo "  size, and print that instead."
    echo
    echo "  Also check the queue PPD above: a stale one means the print dialog"
    echo "  is still showing the old settings."
else
    echo "  RESULT: [!] this driver did NOT extract cuts from a known-good PDF."
    echo "          Either the installed binary predates v1.5.0, or something is"
    echo "          shadowing it - check the CUPS filter link above."
fi
