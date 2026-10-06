#!/bin/sh
# Chorded rewind against the menu scrubber (wasm, headless): the same game
# input up to update 299 (m1_play's moves to 240), then two steps back and
# a resume, once through the menu (tools/scripts/rewind_menu.json: Select
# held from 300, menu at 329, Left at 345 and 352, B at 370) and once
# through the chord (tools/scripts/rewind_chord.json: Select tapped at
# 300-301, held from 305 = fast forward, Left at 310 = rewind and a step,
# Left at 317, Select let go at 336). Both park on game frame 180 (a
# 60-frame record boundary) and resume there; with no input after, both
# runs must reach game frame 510 with identical console exports and an
# identical picture (rows 26..127, the Lynx screen). Run from the
# repository root after `zig build -Dcart=snouty-lynx`:
#   sh carts/snouty-lynx/tools/check_chord_rewind.sh [zig-out/bin/snouty-lynx.wasm]
# Exit 0 when they match.
set -e
wasm=${1:-zig-out/bin/snouty-lynx.wasm}
out=${TMPDIR:-/tmp}/lynx-chord-rewind.$$
trap 'rm -rf "$out"' EXIT
exports=debug_frame_count,debug_pc,debug_ticks_lo,debug_ticks_hi,debug_instr_count,debug_irq_count,debug_sleep_ticks,debug_display_frames,debug_pixels_drawn,debug_scrub_history,debug_scrub_depth,debug_scrub_records
# Frame 510 is update 370 + 329 (menu) and 336 + 329 (chord).
node tools/preview.mjs "$wasm" --frames 700 --every 1 --start-skip 699 \
    --script carts/snouty-lynx/tools/scripts/rewind_menu.json --out "$out/menu" \
    --dump-exports $exports --at "369 debug_frame_count == 180" --at "699 debug_frame_count == 510" 2>/dev/null
node tools/preview.mjs "$wasm" --frames 666 --every 1 --start-skip 665 \
    --script carts/snouty-lynx/tools/scripts/rewind_chord.json --out "$out/chord" \
    --dump-exports $exports --at "335 debug_chord_rewind == 1" --at "335 debug_frame_count == 180" \
    --at "665 debug_frame_count == 510" 2>/dev/null
python3 - "$out" <<'PY'
import json, sys, zlib
out = sys.argv[1]
def load(n):
    d = json.load(open(f"{out}/{n}/frames.json"))
    return d["exports"], d["frames"][-1]["file"] if isinstance(d["frames"][-1], dict) else d["frames"][-1]
def rows(path):
    # Minimal PNG decode (8-bit RGB/RGBA, filter 0..4) without PIL.
    data = open(path, "rb").read()
    pos, idat, w, h, ct = 8, b"", 0, 0, 0
    while pos < len(data):
        n = int.from_bytes(data[pos:pos + 4], "big"); t = data[pos + 4:pos + 8]; c = data[pos + 8:pos + 8 + n]
        if t == b"IHDR": w, h, ct = int.from_bytes(c[0:4], "big"), int.from_bytes(c[4:8], "big"), c[9]
        if t == b"IDAT": idat += c
        pos += 12 + n
    bpp = 4 if ct == 6 else 3
    raw = zlib.decompress(idat); stride = w * bpp; prev = bytearray(stride); res = []; i = 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; cc = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - cc; pa, pb, pc = abs(p - a), abs(p - b), abs(p - cc)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else cc)) & 255
        res.append(bytes(line)); prev = line
    return res
em, fm = load("menu")
ec, fc = load("chord")
ok = True
for k in em:
    if em[k] != ec[k]:
        print(f"{k}: menu {em[k]} chord {ec[k]}"); ok = False
rm, rc = rows(f"{out}/menu/{fm}"), rows(f"{out}/chord/{fc}")
if rm[26:128] != rc[26:128]:
    print("picture rows 26..127 differ"); ok = False
print("chorded rewind matches the menu path" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
PY
