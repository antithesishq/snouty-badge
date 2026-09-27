#!/usr/bin/env bash
# Validation 1 (PLAN.md section 5): badge-bench must reproduce
# snouty-reflections/tools/emu's real-ELF numbers for the m1.1 cart to the
# instruction and the cycle.
#
#   tests/test_reflections.sh [path/to/snouty-reflections.elf]
#
# Default ELF: ../snouty-reflections/zig-out/firmware/snouty-reflections.elf
# next to this repo (run `zig build` there at tag m1.1 first).
#
# Its tool (tools/emu/real.py --frames 0 25 ... 575 --mode none) runs each
# listed frame as its own window by poking main.frame and dither.mode=1
# before every window, after one discarded warm-up update. We run 576
# consecutive updates with --poke dither.mode=1 instead: update #N renders
# main.frame = N, so frames 25..575 are the same work and must match
# exactly. Update #0 is the first present() of the run: it has no in-flight
# frame to drain, so it is 7 instructions / 10 cycles cheaper than
# real.py's frame 0 (which follows a warm-up present). A second, 2-update
# run with main.frame poked to 0xffffffff makes update #1 render frame 0
# after a warm-up, exactly like real.py; that one must match too.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${1:-$HERE/../snouty-reflections/zig-out/firmware/snouty-reflections.elf}"
OUT="$HERE/out/tests/reflections"
M11_SHA=7c76be7bd522f09c800aace3120c1ea89a8e269cfc1442b411b1f87352085cce

[ -f "$ELF" ] || { echo "test_reflections: no ELF at $ELF (zig build in snouty-reflections at m1.1)" >&2; exit 1; }
mkdir -p "$OUT/sweep" "$OUT/frame0"
sha=$(sha256sum "$ELF" | cut -d' ' -f1)
if [ "$sha" != "$M11_SHA" ]; then
    echo "test_reflections: WARNING $ELF is not the m1.1 build the reference numbers came from"
    echo "  (sha256 $sha, expected $M11_SHA); expect mismatches"
fi

echo "test_reflections: 576 consecutive updates, --poke dither.mode=1 (about a minute)"
"$HERE/bench.sh" "$ELF" --no-config --frames 576 --every 25 --budget-ms 50 \
    --poke dither.mode=1 --json --out "$OUT/sweep" > "$OUT/sweep.txt"
echo "test_reflections: 2 updates, --poke dither.mode=1 --poke main.frame=0xffffffff"
"$HERE/bench.sh" "$ELF" --no-config --frames 2 --budget-ms 50 \
    --poke dither.mode=1 --poke main.frame=0xffffffff --json --out "$OUT/frame0" > "$OUT/frame0.txt"

"$HERE/.venv/bin/python" - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
# snouty-reflections tools/emu/out/sweep/result_real_FFFF.json at m1.1 (real.py, mode none)
EXPECTED = {
    0: (4121645, 5076056), 25: (4055343, 4996812), 50: (3882063, 4785116),
    75: (3819973, 4706537), 100: (3788833, 4666185), 125: (3835212, 4729130),
    150: (3846231, 4743097), 175: (3826297, 4715585), 200: (3866507, 4767819),
    225: (3845473, 4737789), 250: (3849010, 4745876), 275: (3844192, 4736455),
    300: (3850813, 4743235), 325: (3860285, 4757418), 350: (3829719, 4717103),
    375: (3868401, 4769462), 400: (3827249, 4716943), 425: (3806026, 4690131),
    450: (3848988, 4747228), 475: (3922940, 4836538), 500: (4093745, 5044928),
    525: (4137811, 5097254), 550: (4248497, 5230991), 575: (4208217, 5183304),
}
FIRST_PRESENT = (7, 10)   # update #0 skips one FIFO drain iteration in present()
sweep = {f['frame']: f for f in json.load(open(f"{out}/sweep/bench.json"))['frames']}
warm = {f['frame']: f for f in json.load(open(f"{out}/frame0/bench.json"))['frames']}
fails = 0
print(f"{'frame':>5} {'ref insns':>11} {'ref cycles':>11} {'ours insns':>11} {'ours cycles':>11}  result")
for fr, (ri, rc) in EXPECTED.items():
    got = sweep[fr]
    if fr == 0:
        rows = [('#0 of the sweep', got, (ri - FIRST_PRESENT[0], rc - FIRST_PRESENT[1])),
                ('#1 after warm-up', warm[1], (ri, rc))]
    else:
        rows = [('', got, (ri, rc))]
    for label, g, (ei, ec) in rows:
        ok = (g['insn'], g['cyc']) == (ei, ec)
        fails += not ok
        note = 'match' if ok and (ei, ec) == (ri, rc) else (
            f"match (expected -{FIRST_PRESENT[0]} insns/-{FIRST_PRESENT[1]} cyc: first present)" if ok else 'MISMATCH')
        print(f"{fr:5d} {ri:11,d} {rc:11,d} {g['insn']:11,d} {g['cyc']:11,d}  {note} {label}")
w = max(EXPECTED, key=lambda f: EXPECTED[f][1])
print(f"worst reference frame {w}: {EXPECTED[w][1] / 150e3:.2f} ms; ours {sweep[w]['ms']:.2f} ms")
st = json.load(open(f"{out}/sweep/bench.json"))['summary']
print(f"whole 576-update run: min {st['min_ms']:.2f} mean {st['mean_ms']:.2f} max {st['max_ms']:.2f} ms (frame {st['worst_frame']})")
if fails:
    print(f"test_reflections: FAIL ({fails} mismatches)")
    sys.exit(3)
print("test_reflections: PASS (all 24 reference frames reproduced exactly)")
PY
