#!/usr/bin/env bash
# Universal Paperclips gate (PLAN.md "Gate"): everything a milestone must
# pass before it merges. Run from anywhere; paths are relative to this
# script.
#
#   tools/check.sh                 # every step, in this order
#   tools/check.sh build preview   # only the named steps
#
# Steps:
#   build    zig build -Dcart=paperclips (ELF, UF2, wasm) at the repository root
#   test     zig build test -Dcart=paperclips (the game's and the UI's host tests)
#   gen      the committed generated files are up to date (gen_font.py,
#            gen_title.py, gen_scripts.py --check)
#   oracle   zig build paperclips-oracle, then the oracle comparison
#            (tools/compare.mjs, track O) when it is there
#   preview  headless runs of the wasm (../../tools/preview.mjs): the 10-minute
#            soak bot (tools/scripts/soak.json, no trap, the bot's presses
#            reach the game), the cheat code (cheats.json), and the tour
#            (tour.json) as PNGs in out/check/tour/ to look at
#   bench    badge-bench, calibrated: a prepared late stage-1 game
#            (--poke paperclips_bench=N, N = 1..6 for the six stage-1 pages)
#            with tools/scripts/bench.json; every run's worst `busy ms`
#            <= BENCH_MAX_MS (default 10) and mean <= BENCH_MEAN_MS (default 5)
#   size     size -A of the ELF: .text + .data + .bss (and the ARM unwind
#            tables) <= SIZE_MAX_KB (default 200)
#
# Output under out/check/ (gitignored). Exit 0 when every step passes, else 1.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart="$(dirname "$here")"
root="$(cd "$cart/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

elf="$root/zig-out/firmware/paperclips.elf"
wasm="$root/zig-out/bin/paperclips.wasm"
bench="$root/badge-bench/bench.sh"
preview="$root/tools/preview.mjs"
out="$cart/out/check"
max_ms="${BENCH_MAX_MS:-10}"
mean_ms="${BENCH_MEAN_MS:-5}"
size_kb="${SIZE_MAX_KB:-200}"

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(build test gen oracle preview bench size)
failed=()

want() { local s; for s in "${steps[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
step() { echo; echo "== $1"; }
result() { # name status
    if [ "$2" = 0 ]; then echo "-- $1: PASS"; else echo "-- $1: FAIL"; failed+=("$1"); fi
}
for s in "${steps[@]}"; do
    case "$s" in build|test|gen|oracle|preview|bench|size) ;;
        *) echo "check: unknown step '$s' (build test gen oracle preview bench size)" >&2; exit 2 ;;
    esac
done
mkdir -p "$out"

if want build; then
    step "build: zig build -Dcart=paperclips"
    (cd "$root" && zig build -Dcart=paperclips); result build $?
fi
if want test; then
    step "test: zig build test -Dcart=paperclips"
    (cd "$root" && zig build test -Dcart=paperclips --summary all 2>&1 | tail -6; exit "${PIPESTATUS[0]}"); result test $?
fi
if want gen; then
    step "gen: generated files up to date"
    status=0
    python3 "$here/gen_font.py" --check || status=1
    python3 "$here/gen_title.py" --check || status=1
    python3 "$here/gen_scripts.py" --check || status=1
    result gen $status
fi
if want oracle; then
    step "oracle: zig build paperclips-oracle + tools/compare.mjs"
    status=0
    (cd "$root" && zig build paperclips-oracle -Dcart=paperclips) || status=1
    if [ -f "$here/compare.mjs" ]; then
        (cd "$cart" && node "$here/compare.mjs") || status=1
    else
        echo "check: no tools/compare.mjs yet (track O); built the runner only"
    fi
    result oracle $status
fi
if want preview; then
    step "preview: soak (10 min), cheats, tour"
    status=0
    node "$preview" "$wasm" --frames 36000 --quiet --script "$here/scripts/soak.json" \
        --expect "debug_presses > 100" --expect "debug_frame == 36000" \
        --dump-exports debug_page,debug_msgs,debug_clips,debug_screen \
        --out "$out/soak" || status=1
    node "$preview" "$wasm" --frames 300 --quiet --script "$here/scripts/cheats.json" \
        --expect "debug_cheats == 1" --expect "debug_page == 14" \
        --out "$out/cheats" || status=1
    rm -rf "$out/tour"
    node "$preview" "$wasm" --frames 980 --every 10 --script "$here/scripts/tour.json" \
        --expect "debug_clips >= 30" --out "$out/tour" || status=1
    echo "     look at $out/tour/*.png (or tools/make_gif.py them)"
    result preview $status
fi

if want bench; then
    step "bench: badge-bench (calibrated): stage-1 pages 1..6, stage 2 (7), stage 3 battle on COMBAT (8) and SPACE (9), the game-start skirmish (10)"
    if [ ! -f "$elf" ]; then
        echo "check: no $elf (run the build step)"
        result bench 1
    else
        rm -rf "$out/bench"
        mkdir -p "$out/bench"
        "$bench" --help > /dev/null 2>&1   # create the venv once before the parallel runs
        pids=()
        # 1..6 press through the stage-1 pages (scripts/bench.json); 7..10
        # are prepared stage-2/3 states (game/prepare.zig) and a new game,
        # left to run (main.zig bench_setup).
        for n in 1 2 3 4 5 6 7 8 9 10; do
            script=()
            [ "$n" -le 6 ] && script=(--script "$here/scripts/bench.json")
            "$bench" "$elf" --no-config --poke paperclips_bench=$n --poke paperclips_seed=7 \
                "${script[@]}" --frames 400 --json --symbols \
                --out "$out/bench/page$n" > "$out/bench/page$n.txt" 2>&1 &
            pids+=($!)
        done
        status=0
        for p in "${pids[@]}"; do wait "$p" || status=1; done
        [ "$status" = 0 ] || echo "check: a badge-bench run failed (crash, hang or setup error); see $out/bench/*.txt"
        for n in 1 2 3 4 5 6 7 8 9 10; do
            j="$out/bench/page$n/bench.json"
            [ -f "$j" ] || { status=1; echo "FAIL page$n: no bench.json"; continue; }
            python3 - "$j" "$max_ms" "$mean_ms" "page$n" <<'PY' || status=1
import json, sys
j = json.load(open(sys.argv[1]))
lim, mean_lim, name = float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
s = j["summary"]
key = "busy_ms" if "busy_ms" in j["frames"][0] else "ms"
ok = s["max_ms"] <= lim and s["mean_ms"] <= mean_lim
print("%s %s: worst %.2f ms (%s) at frame %d, mean %.2f, p95 %.2f, %d frames; limits %.1f / %.1f"
      % ("ok  " if ok else "FAIL", name, s["max_ms"], key, s["worst_frame"], s["mean_ms"], s["p95_ms"], s["frames"], lim, mean_lim))
for w in j.get("warnings", []):
    print("     warning:", w)
sys.exit(0 if ok else 1)
PY
        done
        result bench "$status"
    fi
fi

if want size; then
    step "size: size -A $(basename "$elf")"
    if [ ! -f "$elf" ]; then
        echo "check: no $elf"
        result size 1
    else
        size -A "$elf" | python3 -c "
import sys
want = ('.text', '.data', '.bss', '.ARM.extab', '.ARM.exidx', '.cart_descriptor')
tot = 0
for line in sys.stdin:
    p = line.split()
    if len(p) >= 2 and p[0] in want:
        print('     %-18s %8d' % (p[0], int(p[1])))
        tot += int(p[1])
lim = int(sys.argv[1]) * 1024
print('%s total %d bytes (%.1f KB); limit %d KB' % ('ok  ' if tot <= lim else 'FAIL', tot, tot / 1024, lim // 1024))
sys.exit(0 if tot <= lim else 1)
" "$size_kb"
        result size $?
    fi
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "check: PASS (${steps[*]})"
    exit 0
fi
echo "check: FAIL (${failed[*]})"
exit 1
