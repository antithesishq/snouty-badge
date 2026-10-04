#!/usr/bin/env bash
# Snouty Pipes gate: everything a milestone must pass before it merges
# (PLAN.md, SPEC.md section 11). Run from anywhere; paths are relative to
# this script.
#
#   tools/check.sh                 # every step, in this order
#   tools/check.sh golden cycle    # only the named steps
#   BENCH_SEEDS="1 2 3" tools/check.sh bench   # extra timing seeds
#
# Steps:
#   build   zig build -Dcart=snouty-pipes (ELF, UF2, wasm) at the repository root
#   test    zig build test -Dcart=snouty-pipes (host tests: this cart + lib/)
#   float   zig build check-float -Dcart=snouty-pipes (no soft-float or libm)
#   teapot  tools/gen_teapot.py --check (the committed mesh is up to date)
#   golden  tools/check_golden.mjs (tests/golden/*.png, pixel exact)
#   cycle   tools/check_cycle.mjs (screensaver loop on the debug exports)
#   bench   badge-bench, calibrated, with badge-bench/carts/snouty-pipes.toml
#           (boot, growth, a forced dissolve and the next scene, 720 frames):
#           worst `busy ms` frame <= BENCH_MAX_MS (default 12, SPEC section
#           2), no crash or hang; plus one timing-only run per seed in
#           BENCH_SEEDS (default 2..10, SPEC section 11; the badge build mixes the modelled
#           clock into the seed, so --seed gives another walk).
#           Plus the steer run (M3): tools/scripts/bench_steer.json, 3100
#           frames (tools/steer_bot.mjs playing seed 1: Select at 150, a long
#           run, a crash + rewind with a ~380-cell regrow, a second crash,
#           the game-over card, A again, Select out, B's nametag over the
#           growing screensaver with a coin flip), seeded with --poke
#           snouty_pipes_seed=270369 so the firmware replays the headless run.
#   lcd     the same run twice, PNG every 10th frame: with --lcd (what the
#           badge's LCD gets: only each present's dirty rect) and without
#           (the framebuffer). Every pair must be identical. The cart draws
#           incrementally in .copy_forward, so a pixel written without
#           mark_dirty_rect never reaches the badge's screen while the
#           simulator, which shows the whole framebuffer, looks right.
#           (bench and lcd share the --lcd run.) The steer run gets the
#           same pair.
#
# Output under out/ (gitignored). Exit 0 when every step passes, else 1
# (the failing steps are listed at the end).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart="$(dirname "$here")"
root="$(cd "$cart/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

elf="$root/zig-out/firmware/snouty-pipes.elf"
bench="$root/badge-bench/bench.sh"
out="$cart/out/check"
max_ms="${BENCH_MAX_MS:-12}"
seeds="${BENCH_SEEDS-2 3 4 5 6 7 8 9 10}"
# The steer run: the script and the seed the wasm build gets from
# preview.mjs --seed 1 (cart.rand()'s first value), poked into the firmware.
steer=(--script "$cart/tools/scripts/bench_steer.json" --frames 3100 --poke snouty_pipes_seed=270369)

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(build test float teapot golden cycle bench lcd)
failed=()

want() { local s; for s in "${steps[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
step() { echo; echo "== $1"; }
result() { # name status
    if [ "$2" = 0 ]; then echo "-- $1: PASS"; else echo "-- $1: FAIL"; failed+=("$1"); fi
}
for s in "${steps[@]}"; do
    case "$s" in build|test|float|teapot|golden|cycle|bench|lcd) ;;
        *) echo "check: unknown step '$s' (build test float teapot golden cycle bench lcd)" >&2; exit 2 ;;
    esac
done

if want build; then
    step "build: zig build -Dcart=snouty-pipes"
    (cd "$root" && zig build -Dcart=snouty-pipes); result build $?
fi
if want test; then
    step "test: zig build test -Dcart=snouty-pipes"
    (cd "$root" && zig build test -Dcart=snouty-pipes --summary all 2>&1 | tail -4; exit "${PIPESTATUS[0]}"); result test $?
fi
if want float; then
    step "float: zig build check-float -Dcart=snouty-pipes"
    (cd "$root" && zig build check-float -Dcart=snouty-pipes); result float $?
fi
if want teapot; then
    step "teapot: tools/gen_teapot.py --check"
    python3 "$here/gen_teapot.py" --check; result teapot $?
fi
if want golden; then
    step "golden: tools/check_golden.mjs"
    node "$here/check_golden.mjs"; result golden $?
fi
if want cycle; then
    step "cycle: tools/check_cycle.mjs"
    node "$here/check_cycle.mjs"; result cycle $?
fi

# bench + lcd: the --lcd run doubles as the timing run (--lcd only changes
# what the PNGs show); the framebuffer run and the extra seeds run beside it.
if want bench || want lcd; then
    step "bench + lcd: badge-bench (calibrated) $(basename "$elf")"
    if [ ! -f "$elf" ]; then
        echo "check: no $elf (run the build step)"
        want bench && result bench 1
        want lcd && result lcd 1
    else
        rm -rf "$out/bench"
        mkdir -p "$out/bench"
        # Create badge-bench's venv once before the parallel runs (several
        # first runs at once race on pip and leave a broken venv).
        "$bench" --help > /dev/null 2>&1
        pids=()
        "$bench" "$elf" --json --lcd --png 10 --out "$out/bench/lcd" > "$out/bench/lcd.txt" 2>&1 &
        pids+=($!)
        "$bench" "$elf" "${steer[@]}" --json --lcd --png 10 --out "$out/bench/steer_lcd" > "$out/bench/steer_lcd.txt" 2>&1 &
        pids+=($!)
        if want lcd; then
            "$bench" "$elf" --png 10 --out "$out/bench/fb" > "$out/bench/fb.txt" 2>&1 &
            pids+=($!)
            "$bench" "$elf" "${steer[@]}" --png 10 --out "$out/bench/steer_fb" > "$out/bench/steer_fb.txt" 2>&1 &
            pids+=($!)
        fi
        if want bench; then
            for s in $seeds; do
                "$bench" "$elf" --json --seed "$s" --out "$out/bench/seed$s" > "$out/bench/seed$s.txt" 2>&1 &
                pids+=($!)
            done
        fi
        bench_status=0
        for p in "${pids[@]}"; do wait "$p" || bench_status=1; done
        grep -E "^badge-bench:|^  frames|^calibrat|^  (busy|idle) ms|^verdict|warning" "$out/bench/lcd.txt" | head -12

        if want bench; then
            status=$bench_status
            [ "$status" = 0 ] || echo "check: a badge-bench run failed (crash, hang or setup error); see $out/bench/*.txt"
            for j in "$out/bench/lcd/bench.json" "$out/bench/steer_lcd/bench.json" "$out/bench"/seed*/bench.json; do
                [ -f "$j" ] || continue
                python3 - "$j" "$max_ms" <<'EOF' || status=1
import json, sys
j = json.load(open(sys.argv[1]))
lim = float(sys.argv[2])
s = j["summary"]
key = "busy_ms" if "busy_ms" in j["frames"][0] else "ms"
seed = j.get("meta", {}).get("seed", "?")
ok = s["max_ms"] <= lim
print("%s %s: worst %.2f ms (%s) at frame %d, mean %.2f, p95 %.2f, %d frames; limit %.1f"
      % ("ok  " if ok else "FAIL", sys.argv[1].split("/")[-2], s["max_ms"], key, s["worst_frame"],
         s["mean_ms"], s["p95_ms"], s["frames"], lim))
for w in j.get("warnings", []):
    print("     warning:", w)
sys.exit(0 if ok else 1)
EOF
            done
            result bench "$status"
        fi

        if want lcd; then
            status=0
            for run in "" steer_; do
                n=0
                for f in "$out/bench/${run}fb"/frame_*.png; do
                    [ -f "$f" ] || { status=1; echo "check: no ${run}fb framebuffer PNGs"; break; }
                    g="$out/bench/${run}lcd/$(basename "$f")"
                    n=$((n + 1))
                    if ! cmp -s "$f" "$g"; then
                        echo "FAIL ${run}$(basename "$f"): the modelled LCD differs from the framebuffer (a write without mark_dirty_rect?)"
                        status=1
                    fi
                done
                echo "     ${run:-m1_}run: $n frames compared"
            done
            [ "$status" = 0 ] && echo "ok   the modelled LCD equals the framebuffer in every frame"
            result lcd "$status"
        fi
    fi
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "check: PASS (${steps[*]})"
    exit 0
fi
echo "check: FAIL (${failed[*]})"
exit 1
