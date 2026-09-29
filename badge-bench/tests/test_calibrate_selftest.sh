#!/usr/bin/env bash
# badge-calibrate gate for the Python side (calibrate/PLAN.md, work stream B).
#
#   tests/test_calibrate_selftest.sh [path/to/badge-calibrate.elf]
#
# 1. Fixture (no cart needed): tests/make_calibrate_fixture.py writes a
#    synthetic bench.json; fit.py --selftest must pass on it, and a perturbed
#    "hardware" capture (vdiv kernels 1.3x, memory cycles 1.5x in the busy
#    run) must move vdiv to about 18 and the contention factor to 1.5.
# 2. The cart: badge-bench runs the ELF with --json (carts/badge-calibrate.toml
#    supplies frames and the skip_wait poke), fit.py --selftest on its
#    bench.json must pass, and a second run with --calibrate on the selftest
#    toml must give the same ms per frame (within 0.5%) with busy == idle.
#
# Exit 0 pass, 3 fail, 2 the ELF is not built yet (after the fixture checks).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${1:-$HERE/../zig-out/firmware/badge-calibrate.elf}"
OUT="$HERE/out/tests/calibrate"
PY="$HERE/.venv/bin/python"
[ -x "$PY" ] || PY=python3
mkdir -p "$OUT"

echo "test_calibrate: fixture selftest"
"$PY" "$HERE/tests/make_calibrate_fixture.py" "$OUT/fixture" > /dev/null
"$PY" "$HERE/calibrate/fit.py" --selftest "$OUT/fixture/bench.json" --out "$OUT/fixture/selftest.toml" \
    > "$OUT/fixture/selftest.txt" || { cat "$OUT/fixture/selftest.txt"; echo "test_calibrate: FAIL (fixture selftest)"; exit 3; }
tail -1 "$OUT/fixture/selftest.txt"
echo "test_calibrate: fixture, perturbed hardware capture"
"$PY" "$HERE/tests/make_calibrate_fixture.py" "$OUT/perturbed" --perturb > /dev/null
"$PY" "$HERE/calibrate/fit.py" --hardware "$OUT/perturbed/hardware.txt" --emulator "$OUT/perturbed/bench.json" \
    --out "$OUT/perturbed/calibration.toml" > "$OUT/perturbed/fit.txt"
"$PY" - "$OUT/perturbed/calibration.toml" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
vdiv = float(re.search(r'^vdiv = (\S+)', t, re.M).group(1))
factor = float(re.search(r'^factor = (\S+)', t, re.M).group(1))
ok = 17.5 < vdiv < 19 and abs(factor - 1.5) < 0.01
print(f"  vdiv {vdiv:.3f} (expect ~18.2), factor {factor:.3f} (expect 1.500): {'ok' if ok else 'FAIL'}")
sys.exit(0 if ok else 3)
PY

if [ ! -f "$ELF" ]; then
    echo "test_calibrate: no ELF at $ELF (zig build -Dcart=badge-calibrate at the repository root); cart checks skipped" >&2
    exit 2
fi
echo "test_calibrate: badge-bench $ELF --no-calibrate --json"
"$HERE/bench.sh" "$ELF" --no-calibrate --json --symbols --out "$OUT/model" > "$OUT/model.txt"
"$PY" "$HERE/calibrate/fit.py" --selftest "$OUT/model/bench.json" --out "$OUT/selftest.toml" \
    | tee "$OUT/selftest.txt"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "test_calibrate: FAIL (fit.py --selftest)"; exit 3; }
echo "test_calibrate: badge-bench --calibrate $OUT/selftest.toml"
"$HERE/bench.sh" "$ELF" --json --calibrate "$OUT/selftest.toml" --out "$OUT/calibrated" > "$OUT/calibrated.txt"
"$PY" - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
a = {f['frame']: f for f in json.load(open(f"{out}/model/bench.json"))['frames']}
b = {f['frame']: f for f in json.load(open(f"{out}/calibrated/bench.json"))['frames']}
bad = []
if sorted(a) != sorted(b):
    bad.append(f"frame sets differ ({len(a)} vs {len(b)})")
for fr in sorted(set(a) & set(b)):
    m, i, bu = a[fr]['ms'], b[fr]['ms'], b[fr]['busy_ms']
    if abs(i - m) > 0.005 * m or abs(bu - i) > 0.005 * i:
        bad.append(f"frame {fr}: model {m:.4f} ms, calibrated idle {i:.4f}, busy {bu:.4f}")
worst = max((abs(b[f]['ms'] - a[f]['ms']) / a[f]['ms'] for f in a if f in b and a[f]['ms']), default=0)
print(f"  {len(b)} frames; largest calibrated-idle vs model difference {worst * 100:.3f}%")
for x in bad[:10]:
    print("  " + x)
if bad:
    print(f"test_calibrate: FAIL ({len(bad)} problems)")
    sys.exit(3)
print("test_calibrate: PASS (selftest ratios 1.000, defaults reproduced, --calibrate reproduces the model)")
PY
