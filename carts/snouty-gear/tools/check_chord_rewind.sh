#!/bin/sh
# Chorded rewind against the menu scrubber (wasm, headless): the same game
# input up to update 679, then three steps back and a resume, once through
# the menu (tools/scripts/rewind_menu.json: Select held from 680, menu at
# 709, Left at 715/722/729, B at 740) and once through the chord
# (tools/scripts/rewind_chord.json: Select tapped at 680, held from 685 =
# fast forward, Left at 690 = rewind and a step, Left at 697/704, Select
# let go at 716). Both land on game frame 570 and resume there; with no
# input after, both runs must reach game frame 900 with identical console
# exports and an identical picture (rows 24..103, clear of the debug
# overlay and the report line). Run from the repository root after
# `zig build -Dcart=snouty-gear`:
#   sh carts/snouty-gear/tools/check_chord_rewind.sh [zig-out/bin/snouty-gear.wasm]
# Exit 0 when they match.
set -e
wasm=${1:-zig-out/bin/snouty-gear.wasm}
out=${TMPDIR:-/tmp}/gear-chord-rewind.$$
trap 'rm -rf "$out"' EXIT
exports=debug_frame_count,debug_pc,debug_sp,debug_iff1,debug_halted,debug_mapper,debug_vdp_regs01,debug_vdp_status,debug_vdp_line,debug_irq_frame,debug_irq_line,debug_psg_atten,debug_psg_tones,debug_history,debug_scrub_depth
# Frame 900 is update 740 + 329 (menu) and 716 + 329 (chord).
node tools/preview.mjs "$wasm" --frames 1070 --every 1 --start-skip 1069 \
    --script carts/snouty-gear/tools/scripts/rewind_menu.json --out "$out/menu" \
    --dump-exports $exports --at "739 debug_frame_count == 570" --at "1069 debug_frame_count == 900" 2>/dev/null
node tools/preview.mjs "$wasm" --frames 1046 --every 1 --start-skip 1045 \
    --script carts/snouty-gear/tools/scripts/rewind_chord.json --out "$out/chord" \
    --dump-exports $exports --at "715 debug_chord_rewind == 1" --at "715 debug_frame_count == 570" \
    --at "1045 debug_frame_count == 900" 2>/dev/null
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
if rm[24:104] != rc[24:104]:
    print("picture rows 24..103 differ"); ok = False
print("chorded rewind matches the menu path" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
PY
