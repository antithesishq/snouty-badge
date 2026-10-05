#!/usr/bin/env bash
# Snouty GC gate: everything a milestone must pass before it is tagged
# (PLAN.md "M0 gate"). Run from anywhere; paths are relative to this script.
#
#   tools/check.sh                 # every step, in this order
#   tools/check.sh test preview    # only the named steps
#
# Steps:
#   build    zig build -Dcart=snouty-gc (RAM ELF, UF2, wasm) at the repository root
#   test     zig build test (every cart's host tests and lib/'s); when that
#            fails, zig build test-gc (this cart's alone) decides, and the
#            step says which (other carts' runners are not this cart's gate)
#   float    zig build check-float -Dcart=snouty-gc (no soft-float or libm)
#   tracks   tools/build_tracks.py into a temp dir: byte-identical to the
#            committed cart/src/gen/tracks/*.bin (generator deterministic,
#            data current)
#   preview  headless preview.mjs runs on the wasm:
#            - tools/scripts/m0_race.json replayed equals the autopilot's own
#              drive (debug_world_sum): input scripts reproduce a race;
#            - a Quick Race driven by the autopilot reaches the results
#              screen with SNOUTY's 3 laps done, combat on (from M1 a car
#              may be wrecked when the results come up; from M2 pickups make
#              it about 7,300 ticks, so it gets 9,000 frames), and the World
#              under the 2,560 B cap of sim_test;
#            - the attract demo starts after 10 s idle on the title;
#            - the racer select (M1, M3 flow): Start, Start, A (QUICK RACE)
#              opens it, Right x3 shows SYSADMIN, B goes back to the main
#              menu, A, Left picks BOTNET and A races it;
#            - the main menu (M3): Down, Down, A on LINK stays on the menu,
#              Up, A opens GARBAGE COLLECTION's select, A races a GC race;
#            - a GARBAGE COLLECTION race with the autopilot reaches the
#              results with one car left;
#            - the render stress scene (debug_stress) fills the depth list
#              past its cap: 64 objects drawn of more gathered (at frame
#              200: in its first 150 frames SNOUTY's CAPTCHA card covers
#              the floor and nothing under it is drawn);
#            - the M2 gags (docs/preview_m2.gif's run): a CAPTCHA forced on
#              SNOUTY is solved by A presses on its lit cells, a KERNEL PANIC
#              shows the blue screen (frozen > 60), a FORK BOMB ahead forks;
#            - LINK (M4): the simulator's link is offline (A on LINK stays on
#              the menu), the made-up LINK screens (debug_link_view) open the
#              lobby and the link select, and a Quick Race after them is a
#              single-player race (debug_linked 0).
#   bench    badge-bench (calibrated) on badge-bench/carts/snouty-gc.toml,
#            once plain and once with --lcd, and the render stress scene
#            (--poke gc_stress=1, tools/scripts/m1_render_stress.json) plain
#            and --lcd, tools/scripts/m2_race.json (3,000 frames of an
#            autopilot race with pickups in play), m3_outflow_race.json
#            (1,500 frames on Outflow Canyon, the busiest track) and
#            m3_gc_race.json (3,600 frames of a GARBAGE COLLECTION race on
#            Monitor Dunes: marks, claws, the Sweeper), each plain and
#            --lcd: worst `busy ms` <= BENCH_MAX_MS (default 8, SPEC
#            13.1), no crash, no neopixel warning. M4: the stress scene and
#            m3_gc_race.json once more with `--poke gc_pump_probe=1` (every
#            link pump point runs, the link searching: a link race's draw
#            cost) under the same limit, and the worst gap between two pumps
#            by site from their traces (informational, PLAN M4 status).
#
# Output under out/check (gitignored). Exit 0 when every step passes, else 1.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart="$(dirname "$here")"
root="$(cd "$cart/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

wasm="$root/zig-out/bin/snouty-gc.wasm"
elf="$root/zig-out/firmware/snouty-gc.elf"
preview="$root/tools/preview.mjs"
out="$cart/out/check"
max_ms="${BENCH_MAX_MS:-8}"

steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(build test float tracks preview bench)
failed=()

want() { local s; for s in "${steps[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
step() { echo; echo "== $1"; }
result() { # name status
    if [ "$2" = 0 ]; then echo "-- $1: PASS"; else echo "-- $1: FAIL"; failed+=("$1"); fi
}
for s in "${steps[@]}"; do
    case "$s" in build|test|float|tracks|preview|bench) ;;
        *) echo "check: unknown step '$s' (build test float tracks preview bench)" >&2; exit 2 ;;
    esac
done
rm -rf "$out"
mkdir -p "$out"

if want build; then
    step "build: zig build -Dcart=snouty-gc"
    (cd "$root" && zig build -Dcart=snouty-gc); result build $?
fi

if want test; then
    step "test: zig build test"
    if (cd "$root" && zig build test > "$out/test-all.txt" 2>&1); then
        echo "every cart's host tests pass"
        result test 0
    else
        grep -E "error:|failed" "$out/test-all.txt" | head -5
        echo "zig build test failed (see $out/test-all.txt); running this cart's tests alone"
        (cd "$root" && zig build test-gc -Dcart=snouty-gc --summary all 2>&1 | tail -3; exit "${PIPESTATUS[0]}")
        st=$?
        [ "$st" = 0 ] && echo "test-gc passes: the failure is in another cart's runner"
        result test "$st"
    fi
fi

if want float; then
    step "float: zig build check-float -Dcart=snouty-gc"
    (cd "$root" && zig build check-float -Dcart=snouty-gc); result float $?
fi

if want tracks; then
    step "tracks: tools/build_tracks.py is deterministic and the committed data current"
    tmp="$out/tracks"
    mkdir -p "$tmp"
    st=0
    python3 "$here/build_tracks.py" --out "$tmp" --docs "$tmp/docs" > "$out/tracks.txt" 2>&1 || st=1
    for f in "$tmp"/*.bin; do
        cmp -s "$f" "$cart/cart/src/gen/tracks/$(basename "$f")" || { echo "differs: $(basename "$f")"; st=1; }
    done
    [ "$st" = 0 ] && echo "$(ls "$tmp"/*.bin | wc -l) files byte-identical"
    result tracks "$st"
fi

run_preview() { # name args...
    local name=$1
    shift
    node "$preview" "$wasm" --quiet --out "$out/$name" "$@" > "$out/$name.txt" 2>&1
    local st=$?
    grep -E "FAIL|exports after" "$out/$name.txt"
    return $st
}

if want preview; then
    step "preview: headless runs on $(basename "$wasm")"
    st=0
    menus="$out/menus.json"
    echo '[{"from":2,"to":2,"hold":["START"]},{"from":10,"to":10,"hold":["START"]},{"from":14,"to":14,"hold":["A"]},{"from":20,"to":20,"hold":["A"]}]' > "$menus"
    run_preview replay --frames 600 --script "$here/scripts/m0_race.json" --dump-exports debug_world_sum,debug_tick || st=1
    run_preview autopilot --frames 600 --script "$menus" --call debug_set_autopilot:1 --dump-exports debug_world_sum,debug_tick || st=1
    a=$(grep -o 'debug_world_sum=[-0-9]*' "$out/replay.txt")
    b=$(grep -o 'debug_world_sum=[-0-9]*' "$out/autopilot.txt")
    if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "ok   m0_race.json replays the autopilot's race ($a)"; else echo "FAIL m0_race.json replay '$a' != autopilot '$b'"; st=1; fi
    run_preview race --frames 9000 --call debug_start_race:0 --call debug_set_autopilot:1 \
        --until 'debug_screen == 5' --expect 'debug_screen == 5' --expect 'debug_lap == 3' \
        --expect 'debug_phase == 2' --expect 'debug_world_size < 2560' \
        --dump-exports debug_tick,debug_rank,debug_best_lap,debug_world_size || st=1
    run_preview attract --frames 760 --press START:2-2 --at '700 debug_screen == 3' --at '700 debug_mode == 1' \
        --expect 'debug_follow == 0' --dump-exports debug_screen,debug_mode,debug_tick || st=1
    run_preview select --frames 120 --press START:2-2 --press START:10-10 --press A:14-14 --press RIGHT:20-20,RIGHT:30-30,RIGHT:40-40 \
        --at '50 debug_screen == 2' --at '50 debug_select_racer == 3' --press B:60-60 --at '70 debug_screen == 6' \
        --press A:80-80 --press LEFT:90-90 --press A:100-100 --at '95 debug_select_racer == 5' \
        --expect 'debug_screen == 3' --expect 'debug_mode == 0' --expect 'debug_follow == 5' \
        --dump-exports debug_screen,debug_follow || st=1
    run_preview menu --frames 80 --press START:2-2 --press START:10-10 --press DOWN:14-14,DOWN:16-16 --press A:20-20 \
        --at '30 debug_screen == 6' --press UP:32-32 --press A:40-40 --at '50 debug_screen == 2' --press A:60-60 \
        --expect 'debug_screen == 3' --expect 'debug_mode == 3' --dump-exports debug_screen,debug_mode || st=1
    run_preview gc --frames 9000 --call debug_start_gc:0 --call debug_set_autopilot:1 --until 'debug_screen == 5' \
        --expect 'debug_screen == 5' --expect 'debug_alive == 1' --expect 'debug_gc_survivor < 6' \
        --dump-exports debug_tick,debug_gc_sweeps,debug_gc_survivor || st=1
    run_preview gags --frames 1500 --call debug_start_race:0 --call debug_set_autopilot:2 \
        --call-at '1300 debug_effect:3' --call-at '1360 debug_roll_pickup:5' --call-at '1410 debug_effect:17' \
        --call-at '1413 debug_effect:1' --press A:1307-1307,A:1312-1312,A:1332-1332,A:1337-1337 \
        --at '1301 debug_captcha > 100' --at '1360 debug_captcha == 0' --at '1420 debug_frozen > 60' \
        --at '1480 debug_forks >= 2' --dump-exports debug_forks || st=1
    run_preview link --frames 200 --press START:2-2 --press START:10-10 --press DOWN:14-14,DOWN:16-16 --press A:20-20 \
        --at '30 debug_screen == 6' --at '30 debug_link_state == 0' --call-at '40 debug_link_view:2' --at '50 debug_screen == 7' \
        --press RIGHT:60-60 --call-at '70 debug_link_view:5' --at '80 debug_screen == 2' --press A:90-90 \
        --call-at '100 debug_link_view:0' --at '110 debug_screen == 7' --press B:120-120 --at '130 debug_screen == 6' \
        --press UP:140-140,UP:142-142 --press A:150-150 --press A:170-170 \
        --expect 'debug_screen == 3' --expect 'debug_linked == 0' --dump-exports debug_screen,debug_linked || st=1
    run_preview stress --frames 200 --call debug_stress:1 --expect 'debug_mode == 2' --expect 'debug_drawn == 64' \
        --expect 'debug_gathered > 64' --dump-exports debug_drawn,debug_gathered || st=1
    result preview "$st"
fi

if want bench; then
    step "bench: badge-bench (calibrated) $(basename "$elf"), plain and --lcd"
    bench="$root/badge-bench/bench.sh"
    "$bench" --help > /dev/null 2>&1   # create the venv once before the parallel runs
    "$bench" "$elf" --json --symbols --out "$out/bench" > "$out/bench.txt" 2>&1 &
    p1=$!
    "$bench" "$elf" --json --lcd --png 100 --out "$out/bench-lcd" > "$out/bench-lcd.txt" 2>&1 &
    p2=$!
    stress=(--poke gc_stress=1 --script "$here/scripts/m1_render_stress.json")
    "$bench" "$elf" --json --symbols "${stress[@]}" --out "$out/bench-stress" > "$out/bench-stress.txt" 2>&1 &
    p3=$!
    "$bench" "$elf" --json --lcd "${stress[@]}" --out "$out/bench-stress-lcd" > "$out/bench-stress-lcd.txt" 2>&1 &
    p4=$!
    m2=(--frames 3000 --script "$here/scripts/m2_race.json")
    "$bench" "$elf" --json "${m2[@]}" --out "$out/bench-m2" > "$out/bench-m2.txt" 2>&1 &
    p5=$!
    "$bench" "$elf" --json --lcd "${m2[@]}" --out "$out/bench-m2-lcd" > "$out/bench-m2-lcd.txt" 2>&1 &
    p6=$!
    m3o=(--frames 1500 --script "$here/scripts/m3_outflow_race.json")
    "$bench" "$elf" --json "${m3o[@]}" --out "$out/bench-m3-outflow" > "$out/bench-m3-outflow.txt" 2>&1 &
    p7=$!
    "$bench" "$elf" --json --lcd "${m3o[@]}" --out "$out/bench-m3-outflow-lcd" > "$out/bench-m3-outflow-lcd.txt" 2>&1 &
    p8=$!
    m3g=(--frames 3600 --script "$here/scripts/m3_gc_race.json")
    "$bench" "$elf" --json "${m3g[@]}" --out "$out/bench-m3-gc" > "$out/bench-m3-gc.txt" 2>&1 &
    p9=$!
    "$bench" "$elf" --json --lcd "${m3g[@]}" --out "$out/bench-m3-gc-lcd" > "$out/bench-m3-gc-lcd.txt" 2>&1 &
    p10=$!
    probe=(--poke gc_pump_probe=1)
    "$bench" "$elf" --json "${probe[@]}" "${stress[@]}" --out "$out/bench-probe-stress" > "$out/bench-probe-stress.txt" 2>&1 &
    p11=$!
    "$bench" "$elf" --json "${probe[@]}" "${m3g[@]}" --out "$out/bench-probe-gc" > "$out/bench-probe-gc.txt" 2>&1 &
    p12=$!
    st=0
    wait $p11 || st=1
    wait $p12 || st=1
    wait $p1 || st=1
    wait $p2 || st=1
    wait $p3 || st=1
    wait $p4 || st=1
    wait $p5 || st=1
    wait $p6 || st=1
    wait $p7 || st=1
    wait $p8 || st=1
    wait $p9 || st=1
    wait $p10 || st=1
    for j in "$out/bench/bench.json" "$out/bench-lcd/bench.json" "$out/bench-stress/bench.json" "$out/bench-stress-lcd/bench.json" \
             "$out/bench-m2/bench.json" "$out/bench-m2-lcd/bench.json" \
             "$out/bench-m3-outflow/bench.json" "$out/bench-m3-outflow-lcd/bench.json" \
             "$out/bench-m3-gc/bench.json" "$out/bench-m3-gc-lcd/bench.json" \
             "$out/bench-probe-stress/bench.json" "$out/bench-probe-gc/bench.json"; do
        [ -f "$j" ] || { echo "FAIL no $j"; st=1; continue; }
        python3 - "$j" "$max_ms" <<'EOF' || st=1
import json, sys
j = json.load(open(sys.argv[1]))
lim = float(sys.argv[2])
s = j["summary"]
ok = s["max_ms"] <= lim and not j.get("warnings")
print("%s %s: mean %.2f ms, worst %.2f ms at frame %d, p95 %.2f, %d frames; limit %.1f"
      % ("ok  " if ok else "FAIL", sys.argv[1].split("/")[-2], s["mean_ms"], s["max_ms"], s["worst_frame"],
         s["p95_ms"], s["frames"], lim))
for w in j.get("warnings", []):
    print("     warning:", w)
sys.exit(0 if ok else 1)
EOF
    done
    for j in "$out/bench-probe-stress/bench.json" "$out/bench-probe-gc/bench.json"; do
        [ -f "$j" ] || continue
        python3 - "$j" <<'EOF'
import json, sys
j = json.load(open(sys.argv[1]))
rows = [[int(x) for x in t.split("gc gaps:")[1].split()] for t in
        (t["text"] if isinstance(t, dict) else t for t in j.get("traces", [])) if "gc gaps:" in t]
if rows:
    names = ["top", "sim", "horizon", "floor", "lines", "sprites", "hud", "after"]
    worst = [max(r[i] for r in rows) for i in range(len(names))]
    print("     %s pump gaps (us, worst by site): %s" % (sys.argv[1].split("/")[-2],
          ", ".join("%s %d" % (n, g) for n, g in zip(names[1:], worst[1:]))))
EOF
    done
    result bench "$st"
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "check: PASS (${steps[*]})"
    exit 0
fi
echo "check: FAIL (${failed[*]})"
exit 1
