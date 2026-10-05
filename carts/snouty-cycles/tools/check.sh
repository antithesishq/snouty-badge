#!/usr/bin/env bash
# Snouty Cycles gate: everything a milestone must pass before it merges
# (PLAN.md; SPEC.md sections 11 and 12). Run from anywhere; paths are
# relative to this script.
#
#   tools/check.sh                 # every step, in this order
#   tools/check.sh cycle bench     # only the named steps
#   BENCH_LEVELS="1 6" tools/check.sh bench    # ladder levels to time
#   tools/check.sh ladder          # only the ladder bot
#
# Steps:
#   build   zig build -Dcart=snouty-cycles (ELF, UF2, wasm) at the repository root
#   test    zig build test -Dcart=snouty-cycles (host tests: this cart + lib/)
#   float   zig build check-float -Dcart=snouty-cycles (no soft-float or libm)
#   font    tools/gen_font.py --check (cart/src/font8.zig matches the OS font)
#   cycle   headless runs of the wasm (../../tools/preview.mjs) on the debug
#           exports: from the title (A opens the menu, A starts GRID LADDER)
#           the slipping autopilot (debug_autopilot 2) reaches level 3;
#           the same seed twice gives the same World hash and screen; with
#           no input in the ladder 3 derezzes rewind and the 4th is CORE
#           DUMPED (sudden death ends every round by tick 3540);
#           debug_set_level 12 starts PROD; a forced derez (debug_force_crash)
#           rewinds 2 s and resumes on the World hash a straight run had at
#           that tick (levels 8 and 12, the second with the OPTIONS
#           modifiers on); a SKIRMISH match reaches its card.
#   bench   badge-bench, calibrated, with badge-bench/carts/snouty-cycles.toml
#           (3600 frames: the title over the attract round, A at 60 opens
#           the menu, A at 90 starts the ladder; level 1 on autopilot 3:
#           intro, countdown, play, sudden death or a clear), plus ladder
#           levels 1, 6 and 12 (BENCH_LEVELS) poked straight in
#           (snouty_cycles_level) for 3600 frames each, each with a derez
#           forced at World tick BENCH_CRASH_AT (1500) so a rewind (freeze,
#           retraction, replay, repaint) is in the timing, and a SKIRMISH
#           match of 3 ASM programs (BENCH_SKIRMISH): so sudden death,
#           layouts, rewinds and three programs are in the timing: worst `busy ms`
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
#   ladder  the content gate: tools/ladder_bot.mjs, autopilot 3, every
#           level 1..12 cleared with its 3 snapshots (rewinds) on at least
#           4 of 5 seeds.
#   link    LINK DUEL (M3): the lockstep host tests (zig build test
#           -Dtest-filter="LINK DUEL", cart/src/net_test.zig: two Games on
#           lib/link_virtual.zig play 50 rounds with random riders and
#           modifiers in sync at every tick; 50 more with ~5% packet loss
#           and random delay, in sync or a clean NO CONTEST; a corrupted
#           World is NO CONTEST on both, then a new race in sync; unplugged
#           in mid-round the program rides the partner's cycle, then the
#           menu; pause on one badge pauses both); headless: LINK DUEL from
#           the menu says NO LINK IN SIMULATOR (debug_link_status 0), a demo
#           duel (the T2 program in the partner's slot) plays to round 3;
#           badge-bench with no cable: the link costs < LINK_MAX_MS (0.3) a
#           frame (mean busy ms with and without the snouty_cycles_link_off
#           poke, on the toml run and on LINK DUEL's cable screen), and the
#           demo duel holds BENCH_MAX_MS.
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
# Every level run derezzes you at this World tick (a rewind in the timing).
crash_at="${BENCH_CRASH_AT:-1500}"
# The SKIRMISH run: game.Skirmish.from_bits + 1 (15 = 3 ASM programs, OPEN).
skirmish="${BENCH_SKIRMISH:-15}"

all=(build test float font cycle bench lcd ladder link)
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
    # run NAME PREVIEW-ARGS...: a headless run; its summary lines shown,
    # its exit status kept (3 on a failed --expect).
    run() {
        local name="$1"; shift
        local log; log="$(node "$preview" "$wasm" --out "$out/cycle/$name" "$@" 2>&1)"
        local st=$?
        echo "$log" | grep -E "exports|expect|until|PASS|FAIL" | sed "s/^/     [$name] /"
        [ "$st" = 0 ] || { echo "     [$name] exit $st"; status=1; }
    }
    # 1. The ladder goes on: the slipping autopilot clears 2 levels
    #    (rewinds on its derezzes).
    run rounds --frames 40000 --every 100000 --call debug_autopilot:2 --press A:60-61 --press A:90-91 \
        --until "debug_round >= 3" --expect "debug_round >= 3" \
        --dump-exports debug_tick,debug_level,debug_snapshots,debug_rewinds,debug_wins,debug_losses,debug_score
    # 2. Determinism: the same seed and inputs twice, same World and screen.
    for r in a b; do
        node "$preview" "$wasm" --frames 3000 --every 100000 --out "$out/cycle/det_$r" \
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
    # 3. No input in the ladder: three derezzes rewind, the fourth is
    #    CORE DUMPED (sudden death ends every round by tick 3540).
    run idle --frames 16000 --every 100000 --press A:60-61 --press A:90-91 \
        --until "debug_state == 8" --expect "debug_state == 8" --expect "debug_rewinds == 3" --expect "debug_snapshots == 0"
    # 4. debug_set_level jumps into the ladder: PROD, four cycles, 3 snapshots.
    run level --frames 300 --every 100000 \
        --call debug_set_level:12 --expect "debug_level == 12" --expect "debug_snapshots == 3" --expect "debug_alive_mask == 15"
    # 5. Time travel is exact: a forced derez at update 1300 rewinds 2 s
    #    and the round resumes on the World hash a straight run had at
    #    that tick (levels 8 and 12, the second with every OPTIONS
    #    modifier: speed FAST, SNAKE, GAPS, WRAP).
    for spec in "8:0" "12:30"; do
        lv="${spec%%:*}"; opt="${spec##*:}"
        for r in straight rewind; do
            extra=()
            [ "$r" = rewind ] && extra=(--call-at "1300 debug_force_crash")
            node "$preview" "$wasm" --frames 1700 --every 100000 --quiet --seed 4 --out "$out/cycle/tt_${lv}_$r" \
                --call "debug_options:$opt" --call debug_autopilot:3 --call "debug_set_level:$lv" "${extra[@]}" \
                --sample debug_state,debug_world_tick,debug_world_hash,debug_rewinds,debug_rewind_target > /dev/null 2>&1 || status=1
        done
        python3 - "$out/cycle/tt_${lv}_straight/frames.json" "$out/cycle/tt_${lv}_rewind/frames.json" "$lv" <<'PYEOF' || status=1
import json, sys
a, b = (json.load(open(p))["samples"] for p in sys.argv[1:3])
va, vb = a["values"], b["values"]
straight = {}
for st, t, h in zip(va["debug_state"], va["debug_world_tick"], va["debug_world_hash"]):
    if st == 5 and t not in straight: straight[t] = h
# The first countdown after the rewind (state 4, one rewind done).
for i, (st, rw) in enumerate(zip(vb["debug_state"], vb["debug_rewinds"])):
    if st == 4 and rw == 1:
        t, h, tgt = vb["debug_world_tick"][i], vb["debug_world_hash"][i], vb["debug_rewind_target"][i]
        crash = [vb["debug_world_tick"][k] for k in range(i) if vb["debug_state"][k] == 10][0]
        ok = t == tgt == max(0, crash - 120) and straight.get(t) == h
        print("     %s rewind level %s: derez at tick %d, resumed at %d, hash %08x %s straight run's %s"
              % ("ok  " if ok else "FAIL", sys.argv[3], crash, t, h & 0xffffffff, "==" if ok else "!=",
                 "%08x" % (straight[t] & 0xffffffff) if t in straight else "(none)"))
        sys.exit(0 if ok else 1)
print("     FAIL rewind level %s: no rewind seen" % sys.argv[3])
sys.exit(1)
PYEOF
    done
    # 6. SKIRMISH: a match to its card (3 programs of PASCAL on PILLARS).
    run skirmish --frames 20000 --every 100000 --call debug_autopilot:2 --call debug_skirmish:22 \
        --until "debug_state == 15" --expect "debug_state == 15" --expect "debug_mode == 1" --dump-exports debug_match
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
                    --poke "snouty_cycles_seed=$bench_seed" --poke "snouty_cycles_level=$l" --poke "snouty_cycles_crash_at=$crash_at" \
                    --out "$out/bench/level$l" > "$out/bench/level$l.txt" 2>&1 &
                pids+=($!)
            fi
            if [ ${#lcd_flags[@]} -gt 0 ]; then
                "$bench" "$elf" --png 5 --seed "$bench_seed" --poke snouty_cycles_autopilot=3 \
                    --poke "snouty_cycles_seed=$bench_seed" --poke "snouty_cycles_level=$l" --poke "snouty_cycles_crash_at=$crash_at" \
                    --out "$out/bench/fb$l" > "$out/bench/fb$l.txt" 2>&1 &
                pids+=($!)
                lcd_pairs+=("fb$l:level$l")
            fi
        done
        if want bench && [ -n "$skirmish" ]; then
            "$bench" "$elf" --json --seed "$bench_seed" --poke snouty_cycles_autopilot=3 \
                --poke "snouty_cycles_seed=$bench_seed" --poke "snouty_cycles_skirmish=$skirmish" \
                --out "$out/bench/skirmish" > "$out/bench/skirmish.txt" 2>&1 &
            pids+=($!)
        fi
        bench_status=0
        for p in "${pids[@]}"; do wait "$p" || bench_status=1; done
        grep -E "^badge-bench:|^  frames|^calibrat|^  (busy|idle) ms|^verdict|warning" "$out/bench/lcd.txt" | head -12

        if want bench; then
            status=$bench_status
            [ "$status" = 0 ] || echo "check: a badge-bench run failed (crash, hang or setup error); see $out/bench/*.txt"
            for j in "$out/bench/lcd/bench.json" "$out/bench"/level*/bench.json "$out/bench"/skirmish/bench.json; do
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

if want link; then
    step "link: LINK DUEL (lockstep host tests, simulator, badge-bench with no cable)"
    status=0
    (cd "$root" && zig build test -Dcart=snouty-cycles -Dtest-filter="LINK DUEL" --summary all 2>&1 | grep -E "link gate|error|pass|fail" | tail -12; exit "${PIPESTATUS[0]}") || status=1
    mkdir -p "$out/link"
    log="$(node "$preview" "$wasm" --frames 200 --every 100000 --out "$out/link/nolink" \
        --press A:30-31 --press DOWN:50-51 --press DOWN:70-71 --press A:90-91 \
        --expect "debug_state == 16" --expect "debug_link_status == 0" 2>&1)" || status=1
    echo "$log" | grep -E "expect|PASS|FAIL" | sed "s/^/     [nolink] /"
    log="$(node "$preview" "$wasm" --frames 9000 --every 100000 --out "$out/link/demo" \
        --call debug_autopilot:3 --call debug_link_demo:1 \
        --until "debug_link_round >= 3" --expect "debug_link_round >= 3" --dump-exports debug_link_round,debug_link_wins,debug_state 2>&1)" || status=1
    echo "$log" | grep -E "exports|expect|until|PASS|FAIL" | sed "s/^/     [demo] /"
    if [ -f "$elf" ]; then
        b="$out/link/bench"
        rm -rf "$b"; mkdir -p "$b"
        "$bench" --help > /dev/null 2>&1
        pids=()
        for r in on off; do
            extra=(); [ "$r" = off ] && extra=(--poke snouty_cycles_link_off=1)
            "$bench" "$elf" --json --poke snouty_cycles_autopilot=3 --poke snouty_cycles_crash_at=900 "${extra[@]}" \
                --out "$b/toml_$r" > "$b/toml_$r.txt" 2>&1 &
            pids+=($!)
            "$bench" "$elf" --json --frames 1200 --poke snouty_cycles_link=1 "${extra[@]}" \
                --out "$b/cable_$r" > "$b/cable_$r.txt" 2>&1 &
            pids+=($!)
        done
        "$bench" "$elf" --json --frames 3600 --seed "$bench_seed" --poke "snouty_cycles_seed=$bench_seed" \
            --poke snouty_cycles_autopilot=3 --poke snouty_cycles_link=2 --poke snouty_cycles_link_layout=1 \
            --out "$b/duel" > "$b/duel.txt" 2>&1 &
        pids+=($!)
        for p in "${pids[@]}"; do wait "$p" || status=1; done
        python3 - "$b" "${LINK_MAX_MS:-0.3}" "$max_ms" <<'PYEOF' || status=1
import json, sys
b, lim, worst_lim = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
ok = True
def load(n):
    return json.load(open("%s/%s/bench.json" % (b, n)))["summary"]
for run in ("toml", "cable"):
    on, off = load(run + "_on"), load(run + "_off")
    d = on["mean_ms"] - off["mean_ms"]
    good = d < lim and on["max_ms"] <= worst_lim
    ok &= good
    print("%s link cost [%s, no cable]: mean busy %.3f ms with the link, %.3f without: %+.3f ms a frame (limit %.2f); worst %.2f / %.2f"
          % ("ok  " if good else "FAIL", run, on["mean_ms"], off["mean_ms"], d, lim, on["max_ms"], off["max_ms"]))
d = load("duel")
good = d["max_ms"] <= worst_lim
ok &= good
print("%s demo duel (PILLARS, autopilot vs T2): worst %.2f ms at frame %d, mean %.2f, p95 %.2f; limit %.1f"
      % ("ok  " if good else "FAIL", d["max_ms"], d["worst_frame"], d["mean_ms"], d["p95_ms"], worst_lim))
sys.exit(0 if ok else 1)
PYEOF
    else
        echo "check: no $elf (run the build step)"; status=1
    fi
    result link "$status"
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
