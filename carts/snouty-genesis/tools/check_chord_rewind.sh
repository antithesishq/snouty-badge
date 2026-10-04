#!/bin/sh
# Chorded rewind against the menu scrubber (wasm, headless, the test ROM):
# the same game input (m2_play.json) up to update 199, then three or four
# steps back and a resume, once through the menu
# (tools/scripts/rewind_menu.json: Select held from 200, menu at 214, Left
# at 218/222/226, B at 240) and once through the chord
# (tools/scripts/rewind_chord.json: Select tapped at 200, held from 206 =
# fast forward, Left at 210 = rewind and a step, Left at 214/218/222,
# Select let go at 229; fast forward ran 32 frames further, hence the extra
# step). Both land on Genesis frame 270 and resume there; with no input
# after, both runs must reach frame 900 with identical console exports and
# an identical picture (the debug overlay is off by default). Run from the
# repository root after `zig build -Dcart=snouty-genesis`:
#   sh carts/snouty-genesis/tools/check_chord_rewind.sh [zig-out/bin/snouty-genesis.wasm]
# Exit 0 when they match.
set -e
wasm=${1:-zig-out/bin/snouty-genesis.wasm}
out=${TMPDIR:-/tmp}/genesis-chord-rewind.$$
trap 'rm -rf "$out"' EXIT
exports=debug_frame_count,debug_pc,debug_sp,debug_sr,debug_vdp_line,debug_z80_pc,debug_z80_state,debug_pad,debug_tone_hz,debug_scrub_history,debug_scrub_depth,debug_scrub_records,debug_scrub_slots
# Frame 900 is 315 updates after the resume: update 554 (menu, resumed at
# 240) and 543 (chord, resumed at 229).
node tools/preview.mjs "$wasm" --frames 555 --every 1 --start-skip 554 \
    --script carts/snouty-genesis/tools/scripts/rewind_menu.json --out "$out/menu" \
    --dump-exports $exports --at "239 debug_frame_count == 270" --at "554 debug_frame_count == 900" 2>/dev/null
node tools/preview.mjs "$wasm" --frames 544 --every 1 --start-skip 543 \
    --script carts/snouty-genesis/tools/scripts/rewind_chord.json --out "$out/chord" \
    --dump-exports $exports --at "228 debug_chord_rewind == 1" --at "228 debug_frame_count == 270" \
    --at "543 debug_frame_count == 900" 2>/dev/null
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
if rm != rc:
    print("pictures differ"); ok = False
print("chorded rewind matches the menu path" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
PY
