#!/usr/bin/env python3
"""Dump PDF structure: objects, XObjects, and the operators used in content streams."""
import re, sys, zlib, collections

data = open(sys.argv[1], 'rb').read()
print(f"file: {sys.argv[1]}  ({len(data):,} bytes)")

# Find all "N 0 obj ... endobj" spans
objs = {}
for m in re.finditer(rb'(\d+)\s+(\d+)\s+obj\b', data):
    num = int(m.group(1))
    start = m.end()
    end = data.find(b'endobj', start)
    objs[num] = (start, end if end > 0 else len(data))

print(f"objects: {len(objs)}")

def body(num):
    s, e = objs[num]
    return data[s:e]

def stream_of(num):
    b = body(num)
    i = b.find(b'stream')
    if i < 0:
        return None
    j = i + 6
    while j < len(b) and b[j] in (13, 10):
        j += 1
    k = b.find(b'endstream', j)
    raw = b[j:k if k > 0 else len(b)]
    if b'/FlateDecode' in b[:i]:
        try:
            return zlib.decompress(raw)
        except Exception:
            try:
                return zlib.decompressobj().decompress(raw)
            except Exception:
                return None
    return raw

# Classify objects
kinds = collections.Counter()
forms, images, pages = [], [], []
for num in sorted(objs):
    b = body(num)
    head = b[:400]
    if b'/Subtype' in head and b'/Form' in head:
        forms.append(num); kinds['Form XObject'] += 1
    elif b'/Subtype' in head and b'/Image' in head:
        images.append(num); kinds['Image XObject'] += 1
    elif b'/Type' in head and b'/Page' in head and b'/Pages' not in head:
        pages.append(num); kinds['Page'] += 1
    elif b'stream' in b:
        kinds['other stream'] += 1
    else:
        kinds['dict'] += 1

print("\n=== object kinds ===")
for k, v in kinds.most_common():
    print(f"  {k:16s} {v}")

print(f"\nForm XObjects: {forms[:20]}{' ...' if len(forms) > 20 else ''}")
print(f"Image XObjects: {images[:20]}{' ...' if len(images) > 20 else ''}")

for num in images[:6]:
    b = body(num)
    m = re.search(rb'/Width\s+(\d+).*?/Height\s+(\d+)', b[:600], re.S)
    cs = re.search(rb'/ColorSpace\s*(/\w+|\d+ \d+ R)', b[:600])
    print(f"  image obj {num}: {m.group(1).decode()}x{m.group(2).decode() if m else '?'}"
          f"  colorspace={cs.group(1).decode() if cs else '?'}")

print("\n=== page objects ===")
for num in pages:
    print(f"  obj {num}: {body(num)[:300].decode('latin-1')}")

# Operator census across all decodable content streams
print("\n=== operator census (all streams) ===")
OPS = re.compile(rb'(?<![A-Za-z0-9])(re|m|l|c|v|y|h|S|s|f\*|f|F|B\*|B|b\*|b|n|W\*|W|'
                 rb'RG|rg|G|g|K|k|SCN|SC|scn|sc|CS|cs|Do|gs|q|Q|cm|w|BI|sh)(?![A-Za-z0-9])')
census = collections.Counter()
streams_ok = 0
for num in sorted(objs):
    s = stream_of(num)
    if not s:
        continue
    if not re.search(rb'(?<![A-Za-z0-9])(re|m|l|c|Do|rg|RG)(?![A-Za-z0-9])', s):
        continue
    streams_ok += 1
    for m in OPS.finditer(s):
        census[m.group(1).decode()] += 1
print(f"  content-bearing streams: {streams_ok}")
for k, v in census.most_common(30):
    print(f"    {k:5s} {v}")

# Look for cyan-ish color settings
print("\n=== color-setting operations found ===")
seen = collections.Counter()
for num in sorted(objs):
    s = stream_of(num)
    if not s:
        continue
    for m in re.finditer(rb'([\d.]+\s+[\d.]+\s+[\d.]+\s+[\d.]+)\s+(K|k)(?![A-Za-z0-9])', s):
        seen[f"{m.group(1).decode()} {m.group(2).decode()}"] += 1
    for m in re.finditer(rb'([\d.]+\s+[\d.]+\s+[\d.]+)\s+(RG|rg)(?![A-Za-z0-9])', s):
        seen[f"{m.group(1).decode()} {m.group(2).decode()}"] += 1
    for m in re.finditer(rb'([\d.\s]+)(SCN|SC|scn|sc)(?![A-Za-z0-9])', s):
        v = m.group(1).decode().strip()
        if v and len(v) < 40:
            seen[f"{v} {m.group(2).decode()}"] += 1
for k, v in seen.most_common(25):
    print(f"    {k:40s} x{v}")

# Line width settings
print("\n=== line widths (w) ===")
wseen = collections.Counter()
for num in sorted(objs):
    s = stream_of(num)
    if not s:
        continue
    for m in re.finditer(rb'([\d.]+)\s+w(?![A-Za-z0-9])', s):
        wseen[m.group(1).decode()] += 1
for k, v in wseen.most_common(15):
    print(f"    {k:10s} x{v}")
