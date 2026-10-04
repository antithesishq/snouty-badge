#!/usr/bin/env python3
"""Record the autopilot's drive into a preview.mjs / badge-bench input script.

    python3 tools/record_script.py --frames 600 --out tools/scripts/m0_race.json

Runs the wasm headless through the menus (Start at frame 2 skips the
splash, Start at 10 opens the menu, A at 20 starts a Quick Race on Landfill
Loop), with `debug_set_autopilot:1` so the autopilot drives SNOUTY, and
samples `debug_input` (the race byte of the last tick) every frame. The
script it writes holds those buttons frame for frame, so playing it back
without the autopilot (badge-bench cannot make setup calls) drives the same
race: the race seed comes from the frame counter, which the script fixes.
Bits: 0 up, 1 down, 2 left, 3 right, 4 A, 5 B (world.Input).
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

CART = Path(__file__).resolve().parent.parent
ROOT = CART.parent.parent
NAMES = ["UP", "DOWN", "LEFT", "RIGHT", "A", "B"]
MENUS = [{"from": 2, "to": 2, "hold": ["START"]},
         {"from": 10, "to": 10, "hold": ["START"]},
         {"from": 20, "to": 20, "hold": ["A"]}]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--frames", type=int, default=600)
    ap.add_argument("--wasm", default=str(ROOT / "zig-out" / "bin" / "snouty-gc.wasm"))
    ap.add_argument("--out", default=str(CART / "tools" / "scripts" / "m0_race.json"))
    args = ap.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        menus = Path(tmp) / "menus.json"
        menus.write_text(json.dumps(MENUS))
        subprocess.run(["node", str(ROOT / "tools" / "preview.mjs"), args.wasm, "--frames", str(args.frames),
                        "--every", str(args.frames + 1), "--quiet", "--script", str(menus), "--out", tmp,
                        "--call", "debug_set_autopilot:1", "--sample", "debug_input,debug_screen"],
                       check=True)
        s = json.loads((Path(tmp) / "frames.json").read_text())["samples"]
    ticks, inp, scr = s["ticks"], s["values"]["debug_input"], s["values"]["debug_screen"]
    # debug_input is read after update i: the byte update i fed to the race.
    # The script must hold those buttons during update i.
    events = list(MENUS)
    run_start, run_bits = None, 0
    for i, b, sc in zip(ticks, inp, scr):
        b = b if sc == 3 and i > 20 else 0
        if b != run_bits:
            if run_bits:
                events.append({"from": run_start, "to": i - 1, "hold": [n for k, n in enumerate(NAMES) if run_bits >> k & 1]})
            run_start, run_bits = i, b
    if run_bits:
        events.append({"from": run_start, "to": ticks[-1], "hold": [n for k, n in enumerate(NAMES) if run_bits >> k & 1]})
    Path(args.out).write_text("[\n" + ",\n".join("  " + json.dumps(e) for e in events) + "\n]\n")
    print(f"{args.out}: {len(events)} events over {args.frames} frames")


if __name__ == "__main__":
    sys.exit(main())
