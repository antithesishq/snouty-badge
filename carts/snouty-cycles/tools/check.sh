#!/usr/bin/env bash
# Snouty Cycles gate: everything a milestone must pass before it merges
# (PLAN.md; SPEC.md sections 11 and 12). Run from anywhere; paths are
# relative to this script.
#
#   tools/check.sh                 # every step, in this order
#   tools/check.sh cycle bench     # only the named steps
#   BENCH_SEEDS="1 2 3" tools/check.sh bench   # timing seeds
#
# Steps:
#   build   zig build -Dcart=snouty-cycles (ELF, UF2, wasm) at the repository root
#   test    zig build test -Dcart=snouty-cycles (host tests: this cart + lib/)
#   float   zig build check-float -Dcart=snouty-cycles (no soft-float or libm)
#   font    tools/gen_font.py --check (cart/src/font8.zig matches the OS font)
#   cycle   headless runs of the wasm (../../tools/preview.mjs) on the debug
#           exports: autopilot with slips (debug_autopilot 2) reaches round 3;
#           the same seed twice gives the same World hash and screen; with no
#           input after A the player's round still ends (round 2 starts).
#   bench   badge-bench, calibrated, with badge-bench/carts/snouty-cycles.toml
#           (1800 frames: the title over the attract round, A at 60, then
#           autopilot rounds: countdown, play, crash, round over, next round):
#           worst `busy ms` frame <= BENCH_MAX_MS (default 12, SPEC section
#           12), no crash or hang; plus one timing-only run per seed in
#           BENCH_SEEDS (default 2..6: other rounds; command-line pokes
#           replace the toml's, so the autopilot poke is repeated).
#   lcd     the same run twice, PNG every 5th frame: with --lcd (what the
#           badge's LCD gets: only each present's dirty rect) and without
#           (the framebuffer). Every pair must be identical. The cart draws
#           incrementally in .copy_forward, so a pixel written without
#           mark_dirty_rect never reaches the badge's screen while the
#           simulator, which shows the whole framebuffer, looks right.
#
# Output under out/ (gitignored). Exit 0 when every step passes, else 1
# (the failing steps are listed at the end).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart="$(dirname "$here")"
root="$(cd "$cart/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

elf="$root/zig-out/firmware/snouty-cycles.elf"
wasm="$root/zig-out/bin/snouty-cycles.wasm"
preview="$root/tools/preview.mjs"
bench="$root/badge-bench/bench.sh"
out="$cart/out/check"
max_ms="${BENCH_MAX_MS:-12}"
seeds="${BENCH_SEEDS-2 3 4 5 6}"

all=(build test float font cycle bench lcd)
steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=("${all[@]}")
failed=()

want() { local s; for s in "${steps[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
step() { echo; echo "== $1"; }
result() { # name status
    if [ "$2" = 0 ]; then echo "-- $1: PASS"; else echo "-- $1: FAIL"; failed+=("$1"); fi
}
for s in "${steps[@]}"; do
    case " ${all[*]} " in *" $s "*) ;;
        *) echo "check: unknown step '$s' (${all[*]})" >&2; exit 2 ;;
    esac
done

if want build; then
    step "build: zig build -Dcart=snouty-cycles"
    (cd "$root" && zig build -Dcart=snouty-cycles); result build $?
fi
if want test; then
    step "test: zig build test -Dcart=snouty-cycles"
    (cd "$root" && zig build test -Dcart=snouty-cycles --summary all 2>&1 | tail -6; exit "${PIPESTATUS[0]}"); result test $?
fi
if want float; then
    step "float: zig build check-float -Dcart=snouty-cycles"
    (cd "$root" && zig build check-float -Dcart=snouty-cycles); result float $?
fi
if want font; then
    step "font: tools/gen_font.py --check"
    python3 "$here/gen_font.py" --check; result font $?
fi

if want cycle; then
    step "cycle: headless runs on the debug exports"
    status=0
    mkdir -p "$out/cycle"
    # 1. Rounds loop: autopilot with slips reaches round 3.
    node "$preview" "$wasm" --frames 20000 --every 100000 --out "$out/cycle/rounds" \
        --call debug_autopilot:2 --press A:60-61 \
        --until "debug_round >= 3" --expect "debug_round >= 3" \
        --dump-exports debug_tick,debug_wins,debug_losses,debug_score 2>&1 | grep -E "exports|expect|until|FAIL" \
        || true
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    # 2. Determinism: the same seed and inputs twice, same World and screen.
    for run in a b; do
        node "$preview" "$wasm" --frames 3000 --every 100000 --out "$out/cycle/det_$run" \
            --call debug_autopilot:2 --press A:60-61 \
            --dump-exports debug_world_hash,debug_pixel_checksum,debug_round > /dev/null 2>&1 || status=1
    done
    if python3 - "$out/cycle/det_a/frames.json" "$out/cycle/det_b/frames.json" <<'PYEOF'
import json, sys
a, b = (json.load(open(p))["exports"] for p in sys.argv[1:3])
print("     determinism:", a, "==" if a == b else "!=", b)
sys.exit(0 if a == b else 1)
PYEOF
    then :; else status=1; fi
    # 3. No input after A: the player's first round still ends.
    node "$preview" "$wasm" --frames 1500 --every 100000 --out "$out/cycle/idle" \
        --press A:60-61 --expect "debug_round >= 2" 2>&1 | grep -E "exports|expect|FAIL" || true
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    result cycle "$status"
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
        "$bench" "$elf" --json --lcd --png 5 --out "$out/bench/lcd" > "$out/bench/lcd.txt" 2>&1 &
        pids+=($!)
        if want lcd; then
            "$bench" "$elf" --png 5 --out "$out/bench/fb" > "$out/bench/fb.txt" 2>&1 &
            pids+=($!)
        fi
        if want bench; then
            for s in $seeds; do
                "$bench" "$elf" --json --seed "$s" --poke snouty_cycles_autopilot=2 --poke "snouty_cycles_seed=$s" --out "$out/bench/seed$s" > "$out/bench/seed$s.txt" 2>&1 &
                pids+=($!)
            done
        fi
        bench_status=0
        for p in "${pids[@]}"; do wait "$p" || bench_status=1; done
        grep -E "^badge-bench:|^  frames|^calibrat|^  (busy|idle) ms|^verdict|warning" "$out/bench/lcd.txt" | head -12

        if want bench; then
            status=$bench_status
            [ "$status" = 0 ] || echo "check: a badge-bench run failed (crash, hang or setup error); see $out/bench/*.txt"
            for j in "$out/bench/lcd/bench.json" "$out/bench"/seed*/bench.json; do
                [ -f "$j" ] || continue
                python3 - "$j" "$max_ms" <<'PYEOF' || status=1
import json, sys
j = json.load(open(sys.argv[1]))
lim = float(sys.argv[2])
s = j["summary"]
key = "busy_ms" if "busy_ms" in j["frames"][0] else "ms"
ok = s["max_ms"] <= lim
print("%s %s: worst %.2f ms (%s) at frame %d, mean %.2f, p95 %.2f, %d frames; limit %.1f"
      % ("ok  " if ok else "FAIL", sys.argv[1].split("/")[-2], s["max_ms"], key, s["worst_frame"],
         s["mean_ms"], s["p95_ms"], s["frames"], lim))
for w in j.get("warnings", []):
    print("     warning:", w)
sys.exit(0 if ok else 1)
PYEOF
            done
            result bench "$status"
        fi

        if want lcd; then
            status=0
            n=0
            for f in "$out/bench/fb"/frame_*.png; do
                [ -f "$f" ] || { status=1; echo "check: no framebuffer PNGs"; break; }
                g="$out/bench/lcd/$(basename "$f")"
                n=$((n + 1))
                if ! cmp -s "$f" "$g"; then
                    echo "FAIL $(basename "$f"): the modelled LCD differs from the framebuffer (a write without mark_dirty_rect?)"
                    status=1
                fi
            done
            echo "     $n frames compared"
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
