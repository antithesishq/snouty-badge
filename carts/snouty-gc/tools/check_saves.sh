#!/usr/bin/env bash
# Snouty GCP cart saves gate (branch saves/gcp; docs/RUNNING.md "7. Saves").
# Run after tools/check.sh build (or `zig build -Dcart=snouty-gc`): the
# host tests are in `zig build test-gc` (career_save_test.zig); this runs
# badge-bench three times on the RAM ELF and checks what the saves OS saw:
#
#   race      tools/scripts/saves_circuit_race.json (a CIRCUIT race from the
#             menus to its results, A A to the standings, A the garage, B the
#             menu) against a fresh store file: the probe, one write of
#             gcp/career (181 B) on the frame after the standings come up,
#             `[save N ms]` there; B with nothing bought writes nothing;
#             every other frame under BENCH_MAX_MS
#   continue  the next boot on that store (saves_continue.json: CIRCUIT,
#             CONTINUE CAREER, A buys in the garage) with --exit-at 100: the
#             probe reads the career, the exit hook writes it once and the
#             cart answers ready
#   stock     the race again with --no-saves: no write, no save frame, the
#             probe's 250 ms on update 1 only, and every race frame costs
#             what it does with saves (the hook is free when off)
#
# Output under out/check_saves (gitignored); CHECK_ONLY=1 rechecks the last
# run without benching again. Exit 0 when all pass.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart="$(dirname "$here")"
root="$(cd "$cart/../.." && pwd)"
elf="$root/zig-out/firmware/snouty-gc.elf"
bench="$root/badge-bench/bench.sh"
out="$cart/out/check_saves"
max_ms="${BENCH_MAX_MS:-8}"
[ -f "$elf" ] || { echo "no $elf: build first"; exit 1; }
st=0
# CHECK_ONLY=1: rerun the checks on the last run's output.
if [ "${CHECK_ONLY:-0}" != 1 ]; then
rm -rf "$out"
mkdir -p "$out"

race=(--frames 6100 --script "$here/scripts/saves_circuit_race.json")
"$bench" --help > /dev/null 2>&1   # create the venv once before the parallel runs
"$bench" "$elf" --json "${race[@]}" --saves "$out/store.json" --out "$out/race" > "$out/race.txt" 2>&1 &
p1=$!
"$bench" "$elf" --json "${race[@]}" --no-saves --out "$out/stock" > "$out/stock.txt" 2>&1 &
p2=$!
wait $p1 || st=1
cp "$out/store.json" "$out/store-after-race.json" 2>/dev/null
"$bench" "$elf" --json --frames 120 --script "$here/scripts/saves_continue.json" --saves "$out/store.json" \
    --exit-at 100 --out "$out/continue" > "$out/continue.txt" 2>&1 || st=1
wait $p2 || st=1
fi

python3 - "$out" "$max_ms" <<'EOF' || st=1
import json, sys
out, lim = sys.argv[1], float(sys.argv[2])
ok = True
def check(cond, msg):
    global ok
    print(("ok   " if cond else "FAIL ") + msg)
    ok = ok and cond
race = json.load(open(out + "/race/bench.json"))
stock = json.load(open(out + "/stock/bench.json"))
cont = json.load(open(out + "/continue/bench.json"))

log = race["saves"]["log"]
writes = [e for e in log if e["op"] == "write"]
check([e["op"] for e in log[:3]] == ["probe", "exit_watch", "read"] and log[0]["frame"] == 1,
      "race: probe, exit_watch and read on update 1")
check(len(writes) == 1 and writes[0]["key"] == "gcp/career" and writes[0]["len"] == 181 and writes[0]["status"] == "ok",
      "race: one write of gcp/career, 181 B: %s" % [(e["frame"], e["len"], e["status"]) for e in writes])
saved = [f for f in race["frames"] if f.get("save_ms")]
check(len(saved) == 1 and writes and saved[0]["frame"] == writes[0]["frame"],
      "race: [save %.0f ms] at frame %s (the standings came up the frame before)"
      % (saved[0]["save_ms"] if saved else 0, saved[0]["frame"] if saved else "-"))
rest = max(f["busy_ms"] for f in race["frames"] if not f.get("save_ms"))
check(rest <= lim, "race: worst frame without the save %.2f ms (limit %.1f)" % (rest, lim))

slog = (stock.get("saves") or {}).get("log", [])
check((stock.get("saves") or {}).get("ignored") is True, "stock: the save requests went unanswered (%s)" % stock.get("saves"))
check(not any(e["op"] in ("write", "delete") for e in slog) and not any(f.get("save_ms") for f in stock["frames"]),
      "stock: no write, no save frame")
probe = stock["frames"][1]["busy_ms"]
check(probe >= 250, "stock: the probe's timeout on update 1 (%.1f ms)" % probe)
rest_stock = max(f["busy_ms"] for f in stock["frames"][2:])
check(rest_stock <= lim, "stock: worst frame after the probe %.2f ms" % rest_stock)
# Race frames (the countdown to the results): the same cycles with saves on and off.
lo, hi = 30, 5940
d = [abs(a["cyc"] - b["cyc"]) for a, b in zip(race["frames"][lo:hi], stock["frames"][lo:hi])]
mr = sum(f["busy_ms"] for f in race["frames"][lo:hi]) / (hi - lo)
ms = sum(f["busy_ms"] for f in stock["frames"][lo:hi]) / (hi - lo)
check(max(d) <= 200, "race frames %d..%d: saves on %.3f ms mean, stock %.3f ms; worst per-frame difference %d cycles"
      % (lo, hi - 1, mr, ms, max(d)))

clog = cont["saves"]["log"]
reads = [e for e in clog if e["op"] == "read"]
cw = [e for e in clog if e["op"] == "write"]
check(reads and reads[0]["status"] == "ok" and reads[0]["result"] == 181, "continue: the probe reads the saved career")
check(len(cw) == 1 and cw[0]["frame"] == 100 and cw[0]["status"] == "ok",
      "continue: the exit hook writes the changed career once: %s" % [(e["frame"], e["status"]) for e in cw])
ex = cont.get("exit") or {}
check(ex.get("watched") and ex.get("outcome") == "cart ready" and ex.get("ready_frame") == 101,
      "continue: exit requested before update 100, the cart ready before 101 (%s)" % ex.get("outcome"))
sys.exit(0 if ok else 1)
EOF
echo
if [ "$st" = 0 ]; then echo "check_saves: PASS"; exit 0; fi
echo "check_saves: FAIL"
exit 1
