#!/usr/bin/env python3
"""Track B's tools-side pack checks (M7): run from anywhere.

    python3 tools/packs/test_packs.py

1. make_packs.py runs clean: every track passes build_tracks.py's
   validator, every arena build_arena.py's (pads, nodes, the graph with and
   without jumps, the jumps clean at speed and short at a crawl), the
   props stay off the floor and in budget, build_pack.py packages both.
2. The generator is deterministic and the committed files are current: a
   second run in a scratch copy of the outputs is byte-identical to the
   tree (assets/packs/**, docs/packs/**, cart/src/gen/packs/DEADMALL.GCP
   and BONEYARD.GCP).
3. Each .GCP reads back: header, counts, names, the hazard mask (no
   turret), and every track's slot need under the budget.

Exits non-zero on any failure.
"""
from __future__ import annotations

import hashlib
import struct
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
CART = HERE.parent.parent
OUTS = [CART / "assets" / "packs", CART / "docs" / "packs"]
GCPS = {"DEADMALL": ("DEAD MALL", 3, 1), "BONEYARD": ("THE BONEYARD", 3, 1), "SEABED": ("THE SEABED", 3, 1), "COLDSTOR": ("COLD STORAGE", 3, 1)}
DIRS = {"DEADMALL": "dead_mall", "BONEYARD": "boneyard", "SEABED": "seabed", "COLDSTOR": "cold_storage"}


def digest():
    files = {}
    for root in OUTS:
        for p in sorted(root.rglob("*")):
            if p.is_file():
                files[str(p.relative_to(CART))] = hashlib.sha256(p.read_bytes()).hexdigest()
    for f in GCPS:
        p = CART / "cart" / "src" / "gen" / "packs" / f"{f}.GCP"
        files[str(p.relative_to(CART))] = hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else None
    return files


def main():
    fails = []
    before = digest()
    r = subprocess.run([sys.executable, str(HERE / "make_packs.py")], capture_output=True, text=True)
    if r.returncode:
        fails.append("make_packs.py failed:\n" + r.stderr)
    after = digest()
    changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
    if changed:
        fails.append("generated files differ from the tree (run tools/packs/make_packs.py and commit): "
                     + ", ".join(changed[:12]))
    for f, (name, races, arenas) in GCPS.items():
        p = CART / "cart" / "src" / "gen" / "packs" / f"{f}.GCP"
        if not p.exists():
            fails.append(f"{p.name} missing")
            continue
        b = p.read_bytes()
        tn, an, mask = b[6], b[7], b[8]
        size, crc = struct.unpack_from("<II", b, 44)
        ok = (b[:4] == b"GCPK" and b[4] == 1 and size == len(b) and zlib.crc32(b[64:size]) == crc
              and b[12:28].decode().strip() == name and (tn, an) == (races, arenas) and not mask & (1 << 3))
        if not ok:
            fails.append(f"{f}.GCP: header {b[:12]!r} size {size}/{len(b)} tracks {tn} arenas {an} mask {mask:#x}")
        if size > 64 * 1024:
            fails.append(f"{f}.GCP: {size} bytes, over the 64 KB Track B aims for")
        print(f"{f}.GCP: {size} bytes, {tn} tracks + {an} arena, hazards {mask:#04x}, crc {crc:08x}")
        same = (CART / "assets" / "packs" / DIRS[f] / f"{f}.GCP").read_bytes()
        if same != b:
            fails.append(f"{f}.GCP: the assets/packs and cart/src/gen/packs copies differ")
    for f in fails:
        print("FAIL:", f, file=sys.stderr)
    print("test_packs:", "FAIL" if fails else "PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
