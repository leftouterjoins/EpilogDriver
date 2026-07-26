#!/usr/bin/env python3
"""
epilog_decode.py - Decode an Epilog laser job stream (PJL + PCL raster + HPGL vector)
into human-readable form, with sanity checks.

Usage:
    epilog_decode.py job.prn [--max-lines N] [--verbose]
"""
import sys, re, argparse

ESC = 0x1B


def human(n):
    return f"{n:,}"


class Decoder:
    def __init__(self, data, max_lines=40, verbose=False):
        self.d = data
        self.i = 0
        self.max_lines = max_lines
        self.verbose = verbose
        self.out = []
        self.warnings = []
        # state
        self.res = None
        self.raster_w = None
        self.raster_h = None
        self.compression = None
        self.raster_lines = 0
        self.raster_bytes = 0
        self.x = 0
        self.y = 0
        self.ys_seen = []
        self.xs_seen = []
        self.widths_seen = []
        self.mode = "PJL"
        self.hpgl_bytes = 0
        self.pd_count = 0
        self.pu_count = 0

    def emit(self, s):
        self.out.append(s)

    def warn(self, s):
        self.warnings.append(s)

    def run(self):
        d, n = self.d, len(self.d)
        shown_raster = 0
        while self.i < n:
            b = d[self.i]
            if b != ESC:
                # Non-escape run (PJL text or HPGL text)
                j = self.i
                while j < n and d[j] != ESC:
                    j += 1
                chunk = d[self.i:j]
                self.text_chunk(chunk)
                self.i = j
                continue

            # Escape sequence
            self.i += 1
            if self.i >= n:
                self.emit("ESC <truncated>")
                break
            c = d[self.i]

            # Two-char escapes
            if c == ord('E'):
                self.emit("ESC E            -> PCL reset")
                self.i += 1
                continue
            if c == ord('%'):
                # ESC %-12345X  (UEL)  or  ESC %1B (enter HPGL)
                m = re.match(rb'%(-?\d+)([A-Za-z])', d[self.i:self.i + 20])
                if m:
                    val, letter = m.group(1).decode(), m.group(2).decode()
                    if letter == 'X':
                        self.emit(f"ESC %{val}X       -> Universal Exit Language (UEL)")
                        self.mode = "PJL"
                    elif letter == 'B':
                        self.emit(f"ESC %{val}B          -> ENTER HPGL/2 VECTOR MODE")
                        self.mode = "HPGL"
                    elif letter == 'A':
                        self.emit(f"ESC %{val}A          -> return to PCL mode")
                        self.mode = "PCL"
                    self.i += m.end()
                    continue

            # Parameterized: ESC <paramchar 0x21-0x2F> <group 0x60-0x7E> (<value><term>)+
            # term: 0x40-0x5E = final (uppercase), 0x60-0x7E = continuation (lowercase)
            m = re.match(rb'([\x21-\x2F])([\x60-\x7E])((?:[+-]?[0-9]*\.?[0-9]*[\x40-\x5E\x60-\x7E])+)',
                         d[self.i:self.i + 64])
            if not m:
                self.emit(f"ESC <unparsed 0x{c:02x} {d[self.i:self.i+8]!r}>")
                self.i += 1
                continue

            pchar = m.group(1).decode()
            group = m.group(2).decode()
            body = m.group(3)
            consumed = m.end()

            # split body into (value, terminator) pairs
            for vm in re.finditer(rb'([+-]?[0-9]*\.?[0-9]*)([\x40-\x5E\x60-\x7E])', body):
                val = vm.group(1).decode()
                term = vm.group(2).decode()
                cmd = f"{pchar}{group}{term}"
                self.pcl_command(cmd, val, pchar, group, term)
                if term == 'W':
                    # binary data follows
                    nbytes = int(val) if val else 0
                    start = self.i + consumed
                    blob = d[start:start + nbytes]
                    self.raster_bytes += nbytes
                    self.raster_lines += 1
                    if shown_raster < self.max_lines:
                        prev = blob[:16].hex(' ')
                        self.emit(f"    data {nbytes} bytes: {prev}{' ...' if nbytes > 16 else ''}")
                        shown_raster += 1
                    elif shown_raster == self.max_lines:
                        self.emit("    ... (further raster lines suppressed) ...")
                        shown_raster += 1
                    consumed += nbytes
            self.i += consumed

    def pcl_command(self, cmd, val, pchar, group, term):
        v = val
        try:
            iv = int(float(val)) if val not in ('', '+', '-') else 0
        except ValueError:
            iv = 0

        names = {
            '&y#A': None,   # context-dependent
            '&y#C': "focus = %s",
            '&y#Z': "(unknown/required) = %s",
            '&y#P': "RASTER POWER = %s%%",
            '&y#O': "raster direction (0=down,1=up) = %s",
            '&z#S': "RASTER SPEED = %s%%",
            '&l#U': "left offset = %s",
            '&l#Z': "top offset = %s",
            '&u#D': "UNIT OF MEASURE = %s dpi",
            '*t#R': "raster resolution = %s dpi",
            '*r#F': "raster orientation = %s",
            '*r#T': "RASTER HEIGHT = %s px",
            '*r#S': "RASTER WIDTH = %s px",
            '*r#A': "start raster (%s)",
            '*r#C': "end raster",
            '*p#X': "move X = %s",
            '*p#Y': "move Y = %s",
            '*b#M': "compression mode = %s",
            '*b#A': "line byte count = %s",
            '*b#W': "transfer %s bytes",
        }
        key = f"{pchar}{group}#{term}"

        if key == '&y#A':
            # autofocus in header, focus in raster header - disambiguate by position
            desc = f"&y{v}A -> autofocus/focus = {v}"
            self.emit(f"ESC {desc}")
            return

        if key == '&u#D':
            self.res = iv
        elif key == '*r#T':
            self.raster_h = iv
        elif key == '*r#S':
            self.raster_w = iv
        elif key == '*b#M':
            self.compression = v
        elif key == '*p#X':
            self.x = iv
            self.xs_seen.append(iv)
        elif key == '*p#Y':
            self.y = iv
            self.ys_seen.append(iv)
        elif key == '*b#A':
            self.widths_seen.append(iv)

        tmpl = names.get(key)
        if tmpl is None:
            desc = f"{pchar}{group}{v}{term}"
        else:
            desc = f"{pchar}{group}{v}{term}   -> " + tmpl.replace("%s", str(v))

        # Suppress the per-line spam
        if key in ('*p#X', '*p#Y', '*b#A', '*b#W') and self.raster_lines > self.max_lines:
            return
        self.emit(f"ESC {desc}")

    def text_chunk(self, chunk):
        if not chunk:
            return
        if self.mode == "HPGL":
            self.hpgl_bytes += len(chunk)
            s = chunk.decode('latin-1')
            self.pd_count += s.count('PD')
            self.pu_count += s.count('PU')
            if len(s) > 600:
                s = s[:300] + f"  ...[{len(chunk)} bytes total]...  " + s[-200:]
            self.emit(f"HPGL: {s}")
        else:
            nulls = chunk.count(b'\x00')
            if nulls > 32:
                self.emit(f"<{human(nulls)} NUL padding bytes>")
                rest = chunk.replace(b'\x00', b'')
                if rest.strip():
                    self.emit(f"PJL: {rest.decode('latin-1').strip()}")
            else:
                s = chunk.decode('latin-1').strip()
                if s:
                    self.emit(f"PJL: {s}")

    def report(self):
        print("=" * 78)
        print("DECODED STREAM")
        print("=" * 78)
        for line in self.out:
            print(line)
        print()
        print("=" * 78)
        print("SUMMARY")
        print("=" * 78)
        print(f"  total bytes        : {human(len(self.d))}")
        print(f"  unit of measure    : {self.res} dpi")
        print(f"  raster declared    : {self.raster_w} x {self.raster_h} px "
              f"({(self.raster_w or 0)/(self.res or 1):.2f}\" x {(self.raster_h or 0)/(self.res or 1):.2f}\")")
        print(f"  compression mode   : *b{self.compression}M")
        print(f"  raster lines sent  : {human(self.raster_lines)}")
        print(f"  raster data bytes  : {human(self.raster_bytes)}")
        if self.ys_seen:
            print(f"  Y range            : {min(self.ys_seen)} .. {max(self.ys_seen)}  "
                  f"({len(set(self.ys_seen))} distinct)")
        if self.xs_seen:
            print(f"  X range            : {min(self.xs_seen)} .. {max(self.xs_seen)}  "
                  f"({len(set(self.xs_seen))} distinct)")
        if self.widths_seen:
            aw = sum(abs(w) for w in self.widths_seen) / len(self.widths_seen)
            print(f"  line byte counts   : min {min(map(abs,self.widths_seen))} "
                  f"max {max(map(abs,self.widths_seen))} avg {aw:.0f}")
        print(f"  HPGL payload bytes : {human(self.hpgl_bytes)}  (PU moves: {self.pu_count}, PD draws: {self.pd_count})")
        print()

        # ---- sanity checks ----
        print("=" * 78)
        print("SANITY CHECKS")
        print("=" * 78)
        probs = []
        if self.compression == '7MLT':
            probs.append("Compression is *b7MLT = 3D GREYSCALE mode. A normal engrave "
                         "must use *b2M (1-bit bitmap). 3D mode makes the head sweep every "
                         "scanline with analog power modulation.")
        if self.raster_w and self.res and self.raster_w / self.res > 25:
            probs.append(f"Declared raster width {self.raster_w}px = "
                         f"{self.raster_w/self.res:.1f}in exceeds any Zing bed (max 24in).")
        if self.raster_h and self.res and self.raster_h / self.res > 13:
            probs.append(f"Declared raster height {self.raster_h}px = "
                         f"{self.raster_h/self.res:.1f}in exceeds any Zing bed (max 12in).")
        if self.raster_lines > 2000:
            probs.append(f"{human(self.raster_lines)} scanlines emitted - at ~1 sweep each this "
                         f"is a very long job; head will appear to crawl.")
        if self.xs_seen and self.raster_w and max(self.xs_seen) > self.raster_w:
            probs.append(f"Max X position {max(self.xs_seen)} exceeds declared raster width "
                         f"{self.raster_w} - line data is being placed off the right edge.")
        if self.widths_seen and self.raster_w:
            maxbytes = max(map(abs, self.widths_seen))
            # in 1-bit mode a full-width line is width/8 bytes; in 8-bit it is width bytes
            if self.compression == '2M' and maxbytes > self.raster_w / 8 + 8:
                probs.append(f"1-bit mode declared (*b2M) but a scanline carries {maxbytes} bytes; "
                             f"a full-width 1-bit line is only {self.raster_w//8} bytes. "
                             f"The data is 8-bit greyscale being sent as 1-bit -> 8x too wide.")
        if self.pd_count == 0:
            probs.append("No HPGL PD (pen-down) commands - NOTHING will be vector cut.")
        if not probs:
            print("  no problems detected")
        for p in probs:
            print(f"  [!] {p}")
        for w in self.warnings:
            print(f"  [w] {w}")
        print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--max-lines", type=int, default=40)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    data = open(a.file, 'rb').read()
    dec = Decoder(data, max_lines=a.max_lines, verbose=a.verbose)
    dec.run()
    dec.report()


if __name__ == "__main__":
    main()
