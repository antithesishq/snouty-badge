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
#            committed assets/gen/*.bin (generator deterministic, data current)
#   preview  headless preview.mjs runs on the wasm:
#            - tools/scripts/m0_race.json replayed equals the autopilot's own
#              drive (debug_world_sum): input scripts reproduce a race;
#            - a Quick Race driven by the autopilot reaches the results
#              screen with SNOUTY's 3 laps done, combat on (from M1 a car
#              may be wrecked when the results come up), and the World
#              under the 2,560 B cap of sim_test;
#            - the attract demo starts after 10 s idle on the title;
#            - the racer select (M1): Start, Right x3 shows SYSADMIN, B goes
#              back to the title, Start, Left picks BOTNET and A races it;
#            - the render stress scene (debug_stress) fills the depth list
#              past its cap: 64 objects drawn of more gathered.
#   bench    badge-bench (calibrated) on badge-bench/carts/snouty-gc.toml,
#            once plain and once with --lcd, and the render stress scene
#            (--poke gc_stress=1, tools/scripts/m1_render_stress.json) plain
#            and --lcd: worst `busy ms` <= BENCH_MAX_MS (default 8, SPEC
#            13.1), no crash, no neopixel warning.
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
        cmp -s "$f" "$cart/assets/gen/$(basename "$f")" || { echo "differs: $(basename "$f")"; st=1; }
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
    echo '[{"from":2,"to":2,"hold":["START"]},{"from":10,"to":10,"hold":["START"]},{"from":20,"to":20,"hold":["A"]}]' > "$menus"
    run_preview replay --frames 600 --script "$here/scripts/m0_race.json" --dump-exports debug_world_sum,debug_tick || st=1
    run_preview autopilot --frames 600 --script "$menus" --call debug_set_autopilot:1 --dump-exports debug_world_sum,debug_tick || st=1
    a=$(grep -o 'debug_world_sum=[-0-9]*' "$out/replay.txt")
    b=$(grep -o 'debug_world_sum=[-0-9]*' "$out/autopilot.txt")
    if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "ok   m0_race.json replays the autopilot's race ($a)"; else echo "FAIL m0_race.json replay '$a' != autopilot '$b'"; st=1; fi
    run_preview race --frames 6000 --call debug_start_race:0 --call debug_set_autopilot:1 \
        --until 'debug_screen == 5' --expect 'debug_screen == 5' --expect 'debug_lap == 3' \
        --expect 'debug_phase == 2' --expect 'debug_world_size < 2560' \
        --dump-exports debug_tick,debug_rank,debug_best_lap,debug_world_size || st=1
    run_preview attract --frames 760 --press START:2-2 --at '700 debug_screen == 3' --at '700 debug_mode == 1' \
        --expect 'debug_follow == 0' --dump-exports debug_screen,debug_mode,debug_tick || st=1
    run_preview select --frames 120 --press START:2-2 --press START:10-10 --press RIGHT:20-20,RIGHT:30-30,RIGHT:40-40 \
        --at '50 debug_screen == 2' --at '50 debug_select_racer == 3' --press B:60-60 --at '70 debug_screen == 1' \
        --press START:80-80 --press LEFT:90-90 --press A:100-100 --at '95 debug_select_racer == 5' \
        --expect 'debug_screen == 3' --expect 'debug_follow == 5' \
        --dump-exports debug_screen,debug_follow || st=1
    run_preview stress --frames 120 --call debug_stress:1 --expect 'debug_mode == 2' --expect 'debug_drawn == 64' \
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
    st=0
    wait $p1 || st=1
    wait $p2 || st=1
    wait $p3 || st=1
    wait $p4 || st=1
    for j in "$out/bench/bench.json" "$out/bench-lcd/bench.json" "$out/bench-stress/bench.json" "$out/bench-stress-lcd/bench.json"; do
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
    result bench "$st"
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo "check: PASS (${steps[*]})"
    exit 0
fi
echo "check: FAIL (${failed[*]})"
exit 1
