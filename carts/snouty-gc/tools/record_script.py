#!/usr/bin/env python3
"""Record the autopilot's drive into a preview.mjs / badge-bench input script.

    python3 tools/record_script.py --frames 600 --out tools/scripts/m0_race.json

Runs the wasm headless through the menus (M3 flow: Start at frame 2 skips
the splash, Start at 10 opens the main menu, Down at 12 for GARBAGE
COLLECTION with --gc, A at 14 opens the racer select; for --track N > 0,
Down at 16 and Right every 2 frames from 18 on the track row; then A
starts the race with SNOUTY), with `debug_set_autopilot:1` so the
autopilot drives SNOUTY, and
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


def menus(track: int, gc: bool) -> list:
    """The presses from boot to the race (main menu, select, track row)."""
    ev = [{"from": 2, "to": 2, "hold": ["START"]}, {"from": 10, "to": 10, "hold": ["START"]}]
    if gc:
        ev.append({"from": 12, "to": 12, "hold": ["DOWN"]})
    ev.append({"from": 14, "to": 14, "hold": ["A"]})
    t = 16
    if track > 0:
        ev.append({"from": t, "to": t, "hold": ["DOWN"]})
        for _ in range(track):
            t += 2
            ev.append({"from": t, "to": t, "hold": ["RIGHT"]})
    t += 4
    ev.append({"from": t, "to": t, "hold": ["A"]})
    return ev


MENUS = menus(0, False)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--frames", type=int, default=600)
    ap.add_argument("--wasm", default=str(ROOT / "zig-out" / "bin" / "snouty-gc.wasm"))
    ap.add_argument("--out", default=str(CART / "tools" / "scripts" / "m0_race.json"))
    ap.add_argument("--track", type=int, default=0, help="track index (the select's track row)")
    ap.add_argument("--gc", action="store_true", help="GARBAGE COLLECTION instead of QUICK RACE")
    args = ap.parse_args()
    presses = menus(args.track, args.gc)
    go = presses[-1]["from"]
    with tempfile.TemporaryDirectory() as tmp:
        menus_json = Path(tmp) / "menus.json"
        menus_json.write_text(json.dumps(presses))
        subprocess.run(["node", str(ROOT / "tools" / "preview.mjs"), args.wasm, "--frames", str(args.frames),
                        "--every", str(args.frames + 1), "--quiet", "--script", str(menus_json), "--out", tmp,
                        "--call", "debug_set_autopilot:1", "--sample", "debug_input,debug_screen"],
                       check=True)
        s = json.loads((Path(tmp) / "frames.json").read_text())["samples"]
    ticks, inp, scr = s["ticks"], s["values"]["debug_input"], s["values"]["debug_screen"]
    # debug_input is read after update i: the byte update i fed to the race.
    # The script must hold those buttons during update i.
    events = list(presses)
    run_start, run_bits = None, 0
    for i, b, sc in zip(ticks, inp, scr):
        b = b if sc == 3 and i > go else 0
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
