#!/usr/bin/env bash
# One badge-bench run per part of the Demosnout timeline, then a table of
# worst frames (calibrated busy ms, the perf rule of SPEC.md section 2:
# every part's worst frame under 12 ms).
#
#   carts/demosnout/tools/bench_parts.sh          # every part, 0..10
#   carts/demosnout/tools/bench_parts.sh 0 1 2    # just these
#
# Run from anywhere after `zig build -Dcart=demosnout`. Each part N runs
# `badge-bench/bench.sh zig-out/firmware/demosnout.elf --poke scene_part=N
# --frames <part frames + 60> --every 1000 --json --out
# carts/demosnout/out/bench/N` from the repository root, so the run covers
# the whole part (fades included) and the first second of the next one.
# "part worst" is the worst frame over the part's own frames (read from
# bench.json), "run worst" over the whole run (it includes the next part's
# enter() and first 60 frames). Exit status 1 if any part is at or over
# 12 ms or a run fails (badge-bench exit 4 = crash, 5 = hang).
set -u
cd "$(dirname "$0")/../../.."

# Keep in step with cart/src/timeline.zig (`bars`, `entries`).
bars=(3 5 7 5 4 4 5 7 5 4 8)
names=("Intro" "Plasma" "Copper" "Rotozoomer" "Twister" "Tunnel" "Metaballs" "Voxel" "Snouty head" "Fire" "Ending")
limit=12

elf=zig-out/firmware/demosnout.elf
[ -f "$elf" ] || { echo "bench_parts: $elf missing; run zig build -Dcart=demosnout" >&2; exit 1; }

if [ $# -gt 0 ]; then parts=("$@"); else parts=(0 1 2 3 4 5 6 7 8 9 10); fi

rows=()
status=0
for n in "${parts[@]}"; do
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -ge "${#bars[@]}" ]; then
        echo "bench_parts: no part $n (0..$((${#bars[@]} - 1)))" >&2; exit 2
    fi
    len=$(( ${bars[$n]} * 120 ))
    out=carts/demosnout/out/bench/$n
    echo "bench_parts: part $n (${names[$n]}), $len frames + 60" >&2
    mkdir -p "$out"
    badge-bench/bench.sh "$elf" --poke scene_part="$n" --frames $((len + 60)) --every 1000 --json --out "$out" > "$out/stdout.txt" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
        rows+=("$(printf '| %2d | %-11s | %5s | %5s | %5s | %s |' "$n" "${names[$n]}" - - - "badge-bench exit $rc, see $out/stdout.txt")")
        status=1
        continue
    fi
    row=$(python3 - "$out/bench.json" "$len" "$limit" "$n" "${names[$n]}" <<'PY'
import json, sys
path, length, limit, n, name = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
frames = json.load(open(path))["frames"]
def busy(f): return f.get("busy_ms", f["ms"])
own = frames[:length]
worst = max(own, key=busy)
mean = sum(busy(f) for f in own) / len(own)
run_worst = max(busy(f) for f in frames)
verdict = "ok" if busy(worst) < limit else "OVER %g ms" % limit
print("| %2d | %-11s | %5.2f | %5.2f (t %d) | %5.2f | %s |" % (n, name, mean, busy(worst), worst["frame"], run_worst, verdict))
PY
)
    rows+=("$row")
    case "$row" in *OVER*) status=1 ;; esac
done

echo
echo "| # | Part | mean busy ms | part worst busy ms (frame) | run worst | verdict |"
echo "|---|---|---|---|---|---|"
printf '%s\n' "${rows[@]}"
exit $status
