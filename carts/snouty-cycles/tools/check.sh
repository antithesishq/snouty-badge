#!/usr/bin/env bash
# Snouty Cycles gate: everything a milestone must pass before it merges
# (PLAN.md; SPEC.md sections 11 and 12). Run from anywhere; paths are
# relative to this script.
#
#   tools/check.sh                 # every step, in this order
#   tools/check.sh cycle bench     # only the named steps
#   BENCH_LEVELS="1 6" tools/check.sh bench    # ladder levels to time
#   tools/check.sh ladder          # the ladder bot (not in the default list)
#
# Steps:
#   build   zig build -Dcart=snouty-cycles (ELF, UF2, wasm) at the repository root
#   test    zig build test -Dcart=snouty-cycles (host tests: this cart + lib/)
#   float   zig build check-float -Dcart=snouty-cycles (no soft-float or libm)
#   font    tools/gen_font.py --check (cart/src/font8.zig matches the OS font)
#   cycle   headless runs of the wasm (../../tools/preview.mjs) on the debug
#           exports: from the title (A opens the menu, A starts GRID LADDER)
#           the slipping autopilot (debug_autopilot 2) plays 3 attempts;
#           the same seed twice gives the same World hash and screen; with
#           no input in the ladder your first life still ends (sudden death
#           ends every round by tick 3540); debug_set_level 12 starts PROD.
#   bench   badge-bench, calibrated, with badge-bench/carts/snouty-cycles.toml
#           (3600 frames: the title over the attract round, A at 60 opens
#           the menu, A at 90 starts the ladder; level 1 on autopilot 3:
#           intro, countdown, play, sudden death or a clear), plus ladder
#           levels 1, 6 and 12 (BENCH_LEVELS) poked straight in
#           (snouty_cycles_level) for 3600 frames each, so sudden death,
#           layouts and three programs are in the timing: worst `busy ms`
#           frame <= BENCH_MAX_MS (default 12, SPEC section 12) in every
#           run, no crash or hang. BENCH_SEED (default 2) seeds the level
#           runs; command-line pokes replace the toml's, so the autopilot
#           poke is repeated.
#   lcd     the toml run and the level-12 run twice each, PNG every 5th
#           frame: with --lcd (what the badge's LCD gets: only each
#           present's dirty rect) and without (the framebuffer). Every pair
#           must be identical. The cart draws incrementally in
#           .copy_forward, so a pixel written without mark_dirty_rect never
#           reaches the badge's screen while the simulator, which shows the
#           whole framebuffer, looks right.
#   ladder  (not in the default list until Track A's tiers land) the
#           content gate: tools/ladder_bot.mjs, autopilot 3, every level
#           1..12 cleared within 3 lives on at least 4 of 5 seeds.
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
levels="${BENCH_LEVELS-1 6 12}"
bench_seed="${BENCH_SEED:-2}"

all=(build test float font cycle bench lcd)
extra=(ladder)
steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=("${all[@]}")
failed=()

want() { local s; for s in "${steps[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
step() { echo; echo "== $1"; }
result() { # name status
    if [ "$2" = 0 ]; then echo "-- $1: PASS"; else echo "-- $1: FAIL"; failed+=("$1"); fi
}
for s in "${steps[@]}"; do
    case " ${all[*]} ${extra[*]} " in *" $s "*) ;;
        *) echo "check: unknown step '$s' (${all[*]} ${extra[*]})" >&2; exit 2 ;;
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
    # 1. The ladder loops: the slipping autopilot plays 3 attempts.
    node "$preview" "$wasm" --frames 30000 --every 100000 --out "$out/cycle/rounds" \
        --call debug_autopilot:2 --press A:60-61 --press A:90-91 \
        --until "debug_round >= 3" --expect "debug_round >= 3" \
        --dump-exports debug_tick,debug_level,debug_lives,debug_wins,debug_losses,debug_score 2>&1 | grep -E "exports|expect|until|FAIL" \
        || true
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    # 2. Determinism: the same seed and inputs twice, same World and screen.
    for run in a b; do
        node "$preview" "$wasm" --frames 3000 --every 100000 --out "$out/cycle/det_$run" \
            --call debug_autopilot:2 --press A:60-61 --press A:90-91 \
            --dump-exports debug_world_hash,debug_pixel_checksum,debug_round,debug_score > /dev/null 2>&1 || status=1
    done
    if python3 - "$out/cycle/det_a/frames.json" "$out/cycle/det_b/frames.json" <<'PYEOF'
import json, sys
a, b = (json.load(open(p))["exports"] for p in sys.argv[1:3])
print("     determinism:", a, "==" if a == b else "!=", b)
sys.exit(0 if a == b else 1)
PYEOF
    then :; else status=1; fi
    # 3. No input in the ladder: your first life still ends.
    node "$preview" "$wasm" --frames 4500 --every 100000 --out "$out/cycle/idle" \
        --press A:60-61 --press A:90-91 --until "debug_round >= 2" --expect "debug_round >= 2" 2>&1 | grep -E "exports|PASS|FAIL" || true
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    # 4. debug_set_level jumps into the ladder: PROD, four cycles, 3 lives.
    node "$preview" "$wasm" --frames 300 --every 100000 --out "$out/cycle/level" \
        --call debug_set_level:12 --expect "debug_level == 12" --expect "debug_lives == 3" --expect "debug_alive_mask == 15" 2>&1 | grep -E "PASS|FAIL" || true
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    result cycle "$status"
fi

# bench + lcd: the --lcd run doubles as the timing run (--lcd only changes
# what the PNGs show); the framebuffer runs and the ladder levels run beside it.
if want bench || want lcd; then
    step "bench + lcd: badge-bench (calibrated) $(basename "$elf")"
    if [ ! -f "$elf" ]; then
        echo "check: no $elf (run the build step)"
        want bench && result bench 1
        want lcd && result lcd 1
    else
        rm -rf "$out/bench"
        mkdir -p "$out/bench"
        lcd_pairs=("fb:lcd")
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
        for l in $levels; do
            lcd_flags=()
            # The last level's run doubles as the second lcd comparison.
            [ "$l" = "${levels##* }" ] && want lcd && lcd_flags=(--lcd --png 5)
            if want bench || [ ${#lcd_flags[@]} -gt 0 ]; then
                "$bench" "$elf" --json "${lcd_flags[@]}" --seed "$bench_seed" --poke snouty_cycles_autopilot=3 \
                    --poke "snouty_cycles_seed=$bench_seed" --poke "snouty_cycles_level=$l" --out "$out/bench/level$l" > "$out/bench/level$l.txt" 2>&1 &
                pids+=($!)
            fi
            if [ ${#lcd_flags[@]} -gt 0 ]; then
                "$bench" "$elf" --png 5 --seed "$bench_seed" --poke snouty_cycles_autopilot=3 \
                    --poke "snouty_cycles_seed=$bench_seed" --poke "snouty_cycles_level=$l" --out "$out/bench/fb$l" > "$out/bench/fb$l.txt" 2>&1 &
                pids+=($!)
                lcd_pairs+=("fb$l:level$l")
            fi
        done
        bench_status=0
        for p in "${pids[@]}"; do wait "$p" || bench_status=1; done
        grep -E "^badge-bench:|^  frames|^calibrat|^  (busy|idle) ms|^verdict|warning" "$out/bench/lcd.txt" | head -12

        if want bench; then
            status=$bench_status
            [ "$status" = 0 ] || echo "check: a badge-bench run failed (crash, hang or setup error); see $out/bench/*.txt"
            for j in "$out/bench/lcd/bench.json" "$out/bench"/level*/bench.json; do
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
            for pair in "${lcd_pairs[@]}"; do
                fb="${pair%%:*}"; lc="${pair##*:}"
                for f in "$out/bench/$fb"/frame_*.png; do
                    [ -f "$f" ] || { status=1; echo "check: no framebuffer PNGs in $fb"; break; }
                    g="$out/bench/$lc/$(basename "$f")"
                    n=$((n + 1))
                    if ! cmp -s "$f" "$g"; then
                        echo "FAIL $lc/$(basename "$f"): the modelled LCD differs from the framebuffer (a write without mark_dirty_rect?)"
                        status=1
                    fi
                done
            done
            echo "     $n frames compared"
            [ "$status" = 0 ] && echo "ok   the modelled LCD equals the framebuffer in every frame"
            result lcd "$status"
        fi
    fi
fi

if want ladder; then
    step "ladder: tools/ladder_bot.mjs (autopilot 3, levels 1..12, 4 of 5 seeds)"
    mkdir -p "$out"
    node "$here/ladder_bot.mjs" --wasm "$wasm" --json "$out/ladder.json"; result ladder $?
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "check: PASS (${steps[*]})"
    exit 0
fi
echo "check: FAIL (${failed[*]})"
exit 1
