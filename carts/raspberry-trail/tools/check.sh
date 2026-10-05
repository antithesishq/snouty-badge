#!/usr/bin/env bash
# The Raspberry Trail gate (PLAN.md "Gate"): everything a milestone must
# pass before it merges. Run from anywhere; paths are relative to this
# script.
#
#   tools/check.sh                 # every step, in this order
#   tools/check.sh preview bench   # only the named steps
#
# Steps:
#   build    zig build -Dcart=raspberry-trail (ELF, UF2, wasm) at the repository root
#   test     zig build test -Dcart=raspberry-trail (the engine's and the UI's host tests)
#   gen      the committed generated files are up to date: tools/gen_font.py
#            --check and tools/gen_art.py --check
#   oracle   zig build raspberry-trail-oracle, then tools/oracle/compare.py
#            (every named script) and tools/oracle/fuzz.py $ORACLE_FUZZ_ARGS
#            (default "--games 2000 --seed 1": the fixed fuzz set, its
#            comparison and the coverage report)
#   preview  headless runs of the wasm (../../tools/preview.mjs), none may trap:
#            game    the autoplayer (human pace) plays one whole game from the
#                    title; PNGs every 10th frame in out/check/game/ to look at
#            buttons tools/scripts/press_a.json: plain presses, A every 20
#                    frames for 6,000 frames (the instructions, then every
#                    default; shots misfire): answers reach the game
#            death   the starving autoplayer (no food, eats well): the party
#                    starves, the funeral questions, the end box
#            arrival the careful autoplayer plays games until one arrives
#            shoot   the hunting autoplayer: at least 8 shots, at least one hit
#            (with the plan commit's stub engine, death and arrival only
#            check that a game ends)
#   bench    badge-bench, calibrated, on the ELF with the autoplayer
#            (--poke raspberry_trail_autoplay=V, --poke raspberry_trail_seed=N):
#            seeds BENCH_SEEDS (default "1 2 3") at the fast pace, plus one
#            human-pace run and one hunting run with the sound on
#            (--poke raspberry_trail_sound=1), BENCH_FRAMES (default 3000)
#            frames each, the title included; every run's worst `busy ms`
#            <= BENCH_MAX_MS (default 8) and mean <= BENCH_MEAN_MS (default 3)
#   size     size -A of the ELF: .text + .data + .bss (and the ARM unwind
#            tables) <= SIZE_MAX_KB (default 160)
#
# Output under out/check/ (gitignored). Exit 0 when every step passes, else 1.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart="$(dirname "$here")"
root="$(cd "$cart/../.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"

elf="$root/zig-out/firmware/raspberry-trail.elf"
wasm="$root/zig-out/bin/raspberry-trail.wasm"
bench="$root/badge-bench/bench.sh"
preview="$root/tools/preview.mjs"
out="$cart/out/check"
max_ms="${BENCH_MAX_MS:-8}"
mean_ms="${BENCH_MEAN_MS:-3}"
bench_frames="${BENCH_FRAMES:-3000}"
bench_seeds="${BENCH_SEEDS:-1 2 3}"
size_kb="${SIZE_MAX_KB:-160}"
fuzz_args="${ORACLE_FUZZ_ARGS:---games 2000 --seed 1}"

# The plan commit's stub engine cannot starve or arrive.
stub=0
grep -q "fn stub_step" "$cart/cart/src/game/game.zig" && stub=1

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
    step "build: zig build -Dcart=raspberry-trail"
    (cd "$root" && zig build -Dcart=raspberry-trail); result build $?
fi

if want test; then
    step "test: zig build test -Dcart=raspberry-trail"
    (cd "$root" && zig build test -Dcart=raspberry-trail --summary all 2>&1 | tail -8; exit "${PIPESTATUS[0]}"); result test $?
fi

if want gen; then
    step "gen: generated files up to date"
    status=0
    python3 "$here/gen_font.py" --check || status=1
    python3 "$here/gen_art.py" --check || status=1
    result gen $status
fi

if want oracle; then
    step "oracle: zig build raspberry-trail-oracle + compare.py + fuzz.py $fuzz_args"
    status=0
    (cd "$root" && zig build raspberry-trail-oracle -Dcart=raspberry-trail) || status=1
    if [ -f "$here/oracle/compare.py" ]; then
        (cd "$here/oracle" && python3 compare.py) || status=1
    else
        echo "check: no tools/oracle/compare.py yet (track O); built the runner only"
    fi
    if [ -f "$here/oracle/fuzz.py" ]; then
        # shellcheck disable=SC2086
        (cd "$here/oracle" && python3 fuzz.py $fuzz_args) || status=1
    else
        echo "check: no tools/oracle/fuzz.py yet (track O)"
    fi
    result oracle $status
fi

if want preview; then
    step "preview: game, buttons, death, arrival, shoot"
    status=0
    [ "$stub" = 1 ] && echo "check: the stub engine is in (cart/src/game/game.zig): death and arrival only check that a game ends"
    run() { # name, preview args...
        local name="$1"; shift
        rm -rf "${out:?}/$name"
        echo "-- $name"
        node "$preview" "$wasm" --raw-colors --out "$out/$name" \
            --dump-exports debug_frame,debug_games_over,debug_outcome,debug_arrivals,debug_deaths,debug_shots,debug_shots_hit,debug_misfires,debug_shots_wrong,debug_answers,debug_turn,debug_mileage \
            "$@" 2>&1 | grep -E "^preview: exports|PASS|FAIL|trap|error"
        return "${PIPESTATUS[0]}"
    }
    # 1. One whole game by the autoplayer at a human pace, frames to look at.
    run game --seed 11 --frames 40000 --every 10 --call debug_autoplay:1 \
        --until "debug_games_over >= 1" --expect "debug_games_over >= 1" --expect "debug_answers >= 3" || status=1
    # 2. Plain presses: A every 20 frames.
    run buttons --seed 5 --frames 6100 --every 100000 --script "$here/scripts/press_a.json" \
        --expect "debug_answers >= 5" || status=1
    # 3. No food: the party starves.
    death_expect=(--expect "debug_deaths >= 1")
    [ "$stub" = 0 ] && death_expect+=(--expect "debug_outcome == 2")
    run death --seed 7 --frames 40000 --every 100000 --call debug_autoplay:34 \
        --until "debug_games_over >= 1" "${death_expect[@]}" || status=1
    # 4. The careful autoplayer (fast) until a game arrives.
    if [ "$stub" = 0 ]; then
        run arrival --seed 21 --frames 400000 --every 1000000 --quiet --call debug_autoplay:18 \
            --until "debug_arrivals >= 1" --expect "debug_arrivals >= 1" --expect "debug_outcome == 1" || status=1
    else
        run arrival --seed 21 --frames 20000 --every 1000000 --quiet --call debug_autoplay:18 \
            --until "debug_games_over >= 2" --expect "debug_games_over >= 2" || status=1
    fi
    # 5. The hunter: shots, again and again.
    run shoot --seed 31 --frames 200000 --every 1000000 --quiet --call debug_autoplay:50 \
        --until "debug_shots >= 8" --expect "debug_shots >= 8" --expect "debug_shots_hit >= 1" || status=1
    echo "     look at $out/game/*.png (or ../../tools/make_gif.py them)"
    result preview $status
fi

if want bench; then
    step "bench: badge-bench (calibrated), autoplayed games: seeds $bench_seeds fast, seed 4 human pace, seed 5 hunting with sound"
    if [ ! -f "$elf" ]; then
        echo "check: no $elf (run the build step)"
        result bench 1
    else
        rm -rf "$out/bench"
        mkdir -p "$out/bench"
        "$bench" --help > /dev/null 2>&1   # create the venv once before the parallel runs
        runs=()
        for s in $bench_seeds; do runs+=("fast$s:2:$s"); done
        runs+=("human4:1:4" "hunt5:50:5:1")
        pids=()
        for r in "${runs[@]}"; do
            IFS=: read -r name v s snd <<< "$r"
            "$bench" "$elf" --no-config --poke raspberry_trail_autoplay="$v" --poke raspberry_trail_seed="$s" \
                --poke raspberry_trail_sound="${snd:-0}" \
                --frames "$bench_frames" --every 1000 --json --symbols \
                --out "$out/bench/$name" > "$out/bench/$name.txt" 2>&1 &
            pids+=($!)
        done
        status=0
        for p in "${pids[@]}"; do wait "$p" || status=1; done
        [ "$status" = 0 ] || echo "check: a badge-bench run failed (crash, hang or setup error); see $out/bench/*.txt"
        for r in "${runs[@]}"; do
            name="${r%%:*}"
            j="$out/bench/$name/bench.json"
            [ -f "$j" ] || { status=1; echo "FAIL $name: no bench.json"; continue; }
            python3 - "$j" "$max_ms" "$mean_ms" "$name" <<'PY' || status=1
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
