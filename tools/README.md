# Diagnostic tools

Standalone utilities for debugging the driver. Nothing here is needed to build or
install it — these exist because problems in a laser pipeline are hard to see:
the job is binary, the machine gives no feedback beyond moving, and several
layers of macOS rewrite the document before the driver ever runs.

None of them require dependencies beyond a stock macOS Python 3 and Swift.

## diagnose.sh

Reports the state of an installed driver and proves whether it can extract
vector cuts. Start here when cuts are not happening on a machine.

```sh
tools/diagnose.sh
```

Needs no sudo and nothing but a stock macOS — it can be copied to another
machine on its own. It reports the installed binary's checksum and
architectures, flags a stale file shadowing the CUPS filter symlink, checks
whether each print queue's cached PPD predates the current install, then
generates a known-good PDF and runs the installed driver against it.

The last part is the useful bit: if the driver extracts cuts from a PDF known to
contain them, the driver is fine and the problem is the document being printed.
Applications that flatten their output on print — Pixelmator Pro among them —
send a bitmap with no paths in it, and no driver can cut from that.

Note that CUPS caches a copy of the PPD per queue when a printer is added.
Installing a newer PPD does not update existing queues; the script prints the
`lpadmin` command to repoint them.

## epilog_decode.py

Decodes a generated job into readable PJL/PCL/HPGL and runs sanity checks.

```sh
tools/epilog_decode.py job.prn [--max-lines N]
```

Prints every escape sequence with its meaning, then a summary: declared raster
extent, compression mode, scanline count, X/Y ranges, HPGL pen moves. The sanity
checks flag things that are individually legal but produce pathological machine
behaviour — 3D greyscale mode when bitmap was requested, a raster wider than the
bed, 8-bit data being sent as 1-bit, an HPGL section with no pen-down commands.

Start here when a job misbehaves. Most driver bugs are visible in this output.

## send_lpd.py

Sends a job straight to the laser over LPD, bypassing CUPS entirely.

```sh
EPILOG_HOST=192.168.3.4 tools/send_lpd.py job.prn
tools/send_lpd.py job.prn --host 192.168.3.4 --dry-run
```

Uses the same handshake as LibLaserCut: `\002\n` with an empty queue name, then
control file, then data file. The Epilog relies on the job's trailing 4096 NUL
pad to terminate the transfer.

This is the only way to test the driver's output in isolation. Printing through
CUPS involves the application, macOS's colour conversion, the CUPS filter chain
and the LPD backend — any of which can alter the job. If a job works here but
not through the print dialog, the driver is fine and something upstream is
rewriting the document.

## pdf_probe.py

Dumps a PDF's structure: object kinds, image and form XObjects, the operators
actually used, colour-setting operations and line widths.

```sh
tools/pdf_probe.py document.pdf
```

Use it to find out what an application really produced. Pixelmator Pro's print
output, for instance, turns out to be a single full-page image XObject with no
vector paths at all, which no amount of driver work can extract cuts from.

## sample.swift

Renders a PDF and counts chromatic versus grey pixels.

```sh
swift tools/sample.swift document.pdf [dpi]
```

Answers one question: did colour survive? macOS converts spooled documents to
greyscale for a queue it considers monochrome, which turns a cyan cut line pure
white. `NO CHROMATIC PIXELS` means colour was stripped upstream and any
colour-based routing is already lost.

## rescale.swift

Rescales a PDF page to a target page size, preserving vectors.

```sh
swift tools/rescale.swift in.pdf out.pdf 1728 864     # Zing 24 bed
swift tools/rescale.swift in.pdf out.pdf 1152 864     # Zing 16 bed
```

Pixelmator Pro exports PDFs at one point per pixel, so a 24"x12" canvas at
500dpi becomes a 12000x6000pt page — 166 inches wide. Rescaling to the bed size
first avoids the driver trying to rasterize it at that scale. Aspect ratio is
preserved and the result is centred.

## make_test_pdf.py

Generates small PDFs with known geometry for testing.

```sh
tools/make_test_pdf.py combined out.pdf
```

Variants: `design`, `vector`, `fat`, `combined`, `cmyk`. Pages are Zing 24 bed
sized. Useful for isolating driver behaviour without involving a real document —
`combined` gives a black filled square to engrave and a red hairline rectangle to
cut.
