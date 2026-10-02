#!/usr/bin/env bash
# Benchmark snouty-reflections with badge-bench (calibrated busy ms, the
# default) and print one table.
#
#   tools/bench_variants.sh                  # M2.1: one orbit per variant with dist/variants/<name>.elf
#   tools/bench_variants.sh cut20 half30     # just these
#   tools/bench_variants.sh --m3             # M3 rows 1-4 (PLAN.md M3 "Budget and bench") for cut20
#   tools/bench_variants.sh --m3 2 4         # just rows 2 and 4
#   tools/bench_variants.sh --m4             # M4 rows 5, 6 (PLAN.md M4 "Reference and check") + M3 rows 1, 2
#   tools/bench_variants.sh --m4 5           # just row 5 (rows: 5 6 1 2)
#
# M2.1 mode: cart default dither, one orbit per variant (orbit_frames = 30 *
# fps), budget 94% of the frame period. A variant without its ELF (from
# tools/build_variants.sh) is listed as "no elf" and skipped.
#
# M3 mode (--m3), variant cut20 unless M3_VARIANT says otherwise, budget
# 47.0 ms on the worst frame:
#   1 step1     motion off, sunset, 1 orbit (600 frames). ELF built with
#               -Dreflections_bench=motion_off. Also prints the cost against
#               the M2.2 worst frame (45.94 ms, or BASELINE_ELF benched the
#               same way); over 1.0 ms means Track A stops and reports.
#   2 attract   default build, 4 orbits (2400 frames): attract cycles every
#               preset with motion and fades. Worst and mean per preset
#               (600-frame block) too.
#   3 height    -Dreflections_bench=height build (attract sweeps the height
#               1.0 to 1.8 and back, a table rebuild every frame), 4 orbits,
#               1 per preset, broken down per preset.
#   4 palette16 default build, dither palette16 from frame 0 (--poke
#               dither.mode=3), sunset, 1 orbit. Reported, not gated.
# ELFs come from dist/bench/<variant>-<kind>.elf (kind default, motion_off,
# height); a missing one is built at the repository root (zig build
# -Dcart=snouty-reflections -Dreflections_variant=<variant>
# [-Dreflections_bench=<kind>]; this leaves the root zig-out/ holding that
# build) and copied there. REBUILD=1 rebuilds them all. The default kind also
# accepts dist/variants/<variant>.elf when dist/bench has none.
#
# M4 mode (--m4), variant cut20 unless M3_VARIANT says otherwise, the
# default build (it must contain pt.zig; the ELF cache is the M3 one, so
# REBUILD=1 after changing the cart):
#   5 frozen    sunset, midnight, noon: tools/scripts/m4_freeze_<preset>.json
#               (preset by Select, A at update 100), 1300 updates: 1,199
#               frozen updates after the A update. Gate: every frozen
#               update's busy ms at most the frame period minus 3 ms
#               (47.0 ms at 20 fps, 30.33 ms for half30). The A update itself
#               (real-time frame + pt.begin) is shown apart ("A upd").
#               Report: passes after the run, the update at which done()
#               (passes reach 256), the seconds from A to 256 passes at 20
#               fps and busy ms per pass (the frozen updates' busy ms up to
#               done over 256; display() included).
#   6 stick     tools/scripts/m4_frozen_stick.json (stick held while frozen:
#               the real-time preview with a table rebuild), 1300 updates;
#               reported, not gated.
#   1, 2        the M3 rows again (out/bench_m4_m3row*), compared with the M3
#               numbers M3_ROW1 and M3_ROW2_<PRESET> (variables below,
#               overridable from the environment): a move of more than
#               M4_MOVE_LIMIT (0.1 ms) in either direction marks the row MOVED
#               and fails the run.
#   Passes are read from the emulated RAM after every update: rows 5 and 6
#   drive badge-bench's Python API (its venv, which bench.sh creates) with a
#   hook that reads ELF symbol PT_PASSES_SYM (default: the first of pt.n_col,
#   pt.col_passes, pt.column_passes, pt.passes_done, pt.pass_count,
#   pt.n_passes that exists; [160] per-column counts give their minimum, a
#   1, 2 or 4-byte scalar its value) into each frame of bench.json as
#   pt_passes. Without one, done() is guessed from the update times (the
#   first frozen update under half the early frozen median, marked "~").
#
# Run from anywhere. Each run's report.txt and bench.json land in
# out/bench_<name>/ (M2.1) or out/bench_m3_<row>/ (M3) under the cart
# directory. Environment: VARIANTS_DIR (default dist/variants) to bench
# other ELFs in M2.1 mode, BENCH_FRAMES=N to cut every run to N frames
# (smoke test only), ZIG (default zig on PATH), M4_SCRIPTS (default
# tools/scripts) for other M4 input scripts, PT_PASSES_SYM (see M4 mode).
# Exit status: 0 when every gated row is within budget, 3 otherwise, 1 when
# badge-bench or a build fails.
set -euo pipefail

CART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$CART_DIR/../.." && pwd)"
BENCH="$ROOT/badge-bench/bench.sh"
VARIANTS_DIR="${VARIANTS_DIR:-$CART_DIR/dist/variants}"
ZIG="${ZIG:-zig}"

# Summary of a bench.json: worst ms, worst frame, mean, and per-block
# worst/mean when BLOCK > 0 (block i = frames i*BLOCK .. (i+1)*BLOCK - 1).
summarise() {
    python3 - "$@" <<'EOF'
import json, sys
path, block = sys.argv[1], int(sys.argv[2])
j = json.load(open(path))
s = j["summary"]                     # busy ms when calibrated (the default)
line = f'{s["max_ms"]:.2f} {s["worst_frame"]} {s["mean_ms"]:.2f}'
if block > 0:
    key = "busy_ms" if "busy_ms" in j["frames"][0] else "ms"
    names = ["sunset", "midnight", "noon", "storm"]
    parts = []
    for i in range(0, len(j["frames"]), block):
        fr = j["frames"][i:i + block]
        w = max(fr, key=lambda f: f[key])
        m = sum(f[key] for f in fr) / len(fr)
        parts.append(f'{names[(i // block) % 4]}:{w[key]:.2f}@{w["frame"]}/{m:.2f}')
    line += " " + ",".join(parts)
print(line)
EOF
}

# ---------------------------------------------------------------- M2.1 mode
bench_m21() {
    # name frames budget_ms (94% of the frame period)
    local VARIANTS="full20 600 47.0
cut20 600 47.0
full15 450 62.7
half30 900 31.3"
    local want=("$@") rows=() status=0 name frames budget elf out row
    while read -r name frames budget; do
        if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
        frames="${BENCH_FRAMES:-$frames}"
        elf="$VARIANTS_DIR/$name.elf"
        if [ ! -f "$elf" ]; then
            rows+=("$name - - - $budget no-elf")
            continue
        fi
        out="$CART_DIR/out/bench_$name"
        echo "bench_variants: $name: $frames frames, budget $budget ms ($elf)" >&2
        "$BENCH" "$elf" --frames "$frames" --every "$frames" --budget-ms "$budget" --json --out "$out" >/dev/null \
            || { echo "bench_variants: badge-bench failed for $name" >&2; exit 1; }
        read -r worst frame mean < <(summarise "$out/bench.json" 0)
        local verdict=PASS
        python3 -c "import sys; sys.exit(0 if $worst <= $budget else 1)" || { verdict=OVER; status=3; }
        rows+=("$name $worst $frame $mean $budget $verdict")
    done <<< "$VARIANTS"

    printf '\n%-8s %10s %7s %9s %10s  %s\n' variant "worst ms" frame "mean ms" "budget ms" verdict
    for r in "${rows[@]}"; do
        read -r name worst frame mean budget verdict <<< "$r"
        printf '%-8s %10s %7s %9s %10s  %s\n' "$name" "$worst" "$frame" "$mean" "$budget" "${verdict/no-elf/no elf (run tools/build_variants.sh)}"
    done
    return $status
}

# ---------------------------------------------------------------- M3 mode
M3_VARIANT="${M3_VARIANT:-cut20}"
M3_BUDGET=47.0
M22_WORST=45.94          # PLAN.md M2.2 status, cut20 after the logo move
STEP1_LIMIT=1.0          # PLAN.md M3 "Budget and bench" row 1

# The ELF for build kind default|motion_off|height, built if missing.
m3_elf() {
    local kind=$1 dir="$CART_DIR/dist/bench" elf
    elf="$dir/$M3_VARIANT-$kind.elf"
    if [ "${REBUILD:-0}" != 1 ] && [ -f "$elf" ]; then echo "$elf"; return; fi
    if [ "${REBUILD:-0}" != 1 ] && [ "$kind" = default ] && [ -f "$VARIANTS_DIR/$M3_VARIANT.elf" ]; then
        echo "$VARIANTS_DIR/$M3_VARIANT.elf"; return
    fi
    local opt=()
    [ "$kind" != default ] && opt=("-Dreflections_bench=$kind")
    echo "bench_variants: building $M3_VARIANT ${opt[*]:-(default)}" >&2
    (cd "$ROOT" && "$ZIG" build -Dcart=snouty-reflections -Dreflections_variant="$M3_VARIANT" "${opt[@]}") >&2 \
        || { echo "bench_variants: build failed ($M3_VARIANT ${opt[*]:-default}); the cart must provide -Dreflections_bench=$kind (PLAN.md M3 Budget and bench)" >&2; return 1; }
    mkdir -p "$dir"
    cp "$ROOT/zig-out/firmware/snouty-reflections.elf" "$elf"
    echo "$elf"
}

# bench_row NAME ELF FRAMES BLOCK [badge-bench args...]: prints "worst frame mean [blocks]".
bench_row() {
    local name=$1 elf=$2 frames=$3 block=$4; shift 4
    frames="${BENCH_FRAMES:-$frames}"
    local out="$CART_DIR/out/${BENCH_PREFIX:-bench_m3_}$name"
    echo "bench_variants: row $name: $frames frames ($elf) $*" >&2
    "$BENCH" "$elf" --frames "$frames" --every "$frames" --budget-ms "$M3_BUDGET" --json --out "$out" "$@" >/dev/null \
        || { echo "bench_variants: badge-bench failed for row $name" >&2; return 1; }
    summarise "$out/bench.json" "$block"
}

bench_m3() {
    local want=("$@") rows=() status=0 elf res worst frame mean blocks verdict note
    [ ${#want[@]} -eq 0 ] && want=(1 2 3 4)
    for row in "${want[@]}"; do
        case "$row" in
        1)
            elf=$(m3_elf motion_off) || exit 1
            res=$(bench_row step1 "$elf" 600 0) || exit 1
            read -r worst frame mean <<< "$res"
            local base=$M22_WORST base_src="M2.2 status"
            if [ -n "${BASELINE_ELF:-}" ]; then
                res=$(bench_row baseline "$BASELINE_ELF" 600 0) || exit 1
                read -r base _ _ <<< "$res"
                base_src=$(basename "$BASELINE_ELF")
            fi
            note=$(python3 -c "d = $worst - $base; print(f'{d:+.2f} ms vs {$base:.2f} ($base_src)' + ('; over 1.0 ms: STOP and report' if d > $STEP1_LIMIT else ''))")
            verdict=PASS
            python3 -c "import sys; sys.exit(0 if $worst <= $M3_BUDGET and $worst - $base <= $STEP1_LIMIT else 1)" || { verdict=OVER; status=3; }
            rows+=("1-step1|$worst|$frame|$mean|$verdict|$note")
            ;;
        2|3)
            local kind=default name=attract
            [ "$row" = 3 ] && { kind=height; name=height; }
            elf=$(m3_elf "$kind") || exit 1
            res=$(bench_row "$name" "$elf" 2400 600) || exit 1
            read -r worst frame mean blocks <<< "$res"
            verdict=PASS
            python3 -c "import sys; sys.exit(0 if $worst <= $M3_BUDGET else 1)" || { verdict=OVER; status=3; }
            rows+=("$row-$name|$worst|$frame|$mean|$verdict|per preset worst@frame/mean: ${blocks:-}")
            ;;
        4)
            elf=$(m3_elf default) || exit 1
            if ! python3 - "$elf" <<'EOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
sys.exit(0 if b"dither.mode\0" in b else 1)
EOF
            then
                echo "bench_variants: $elf has no dither.mode symbol; the cart must keep 'pub var mode' in dither.zig (row 4 pokes it)" >&2
                exit 1
            fi
            res=$(bench_row palette16 "$elf" 600 0 --poke dither.mode=3) || exit 1
            read -r worst frame mean <<< "$res"
            rows+=("4-palette16|$worst|$frame|$mean|report|not gated; dither.mode poked to 3 before _start")
            ;;
        *) echo "bench_variants: unknown M3 row '$row' (want 1 2 3 4)" >&2; exit 2 ;;
        esac
    done

    printf '\nM3 bench, %s, calibrated busy ms, budget %s ms on the worst frame\n' "$M3_VARIANT" "$M3_BUDGET"
    printf '%-12s %9s %7s %8s  %-7s %s\n' row "worst ms" frame "mean ms" verdict notes
    for r in "${rows[@]}"; do
        IFS='|' read -r name worst frame mean verdict note <<< "$r"
        printf '%-12s %9s %7s %8s  %-7s %s\n' "$name" "$worst" "$frame" "$mean" "$verdict" "$note"
    done
    return $status
}

# ---------------------------------------------------------------- M4 mode
# The frame rate and the frozen-update gate follow the variant (review G3):
# the period minus 3 ms, 47.0 ms at 20 fps as M4 set it, 30.33 at 30 fps.
case "$M3_VARIANT" in
    full15) M4_FPS=15 ;;
    half30) M4_FPS=30 ;;
    *) M4_FPS=20 ;;
esac
M4_BUDGET=$(python3 -c "print(f'{1000 / $M4_FPS - 3:.2f}')")
M4_FRAMES=1300           # A at update 100, then 1,200 frozen updates
M4_MAX_PASSES=256        # pt.max_passes
M4_MOVE_LIMIT="${M4_MOVE_LIMIT:-0.1}"
M4_SCRIPTS="${M4_SCRIPTS:-$CART_DIR/tools/scripts}"   # where m4_freeze_*.json and m4_frozen_stick.json live
# M3 baselines (PLAN.md M3 status, cut20): row 1 worst, row 2 worst per
# preset. Update these (or set them in the environment) when M3.1 moves them.
M3_ROW1="${M3_ROW1:-45.49}"
M3_ROW2_SUNSET="${M3_ROW2_SUNSET:-46.36}"
M3_ROW2_MIDNIGHT="${M3_ROW2_MIDNIGHT:-50.30}"
M3_ROW2_NOON="${M3_ROW2_NOON:-50.62}"
M3_ROW2_STORM="${M3_ROW2_STORM:-45.45}"

# True when the ELF has path tracer symbols (an M4 build).
has_pt() {
    python3 - "$1" <<'PY'
import re, sys
b = open(sys.argv[1], "rb").read()
sys.exit(0 if re.search(rb"\0pt\.[a-z_]+\0", b) else 1)
PY
}

# bench_pt NAME ELF SCRIPT: badge-bench through its Python API with the pass
# hook; writes out/bench_m4_NAME/bench.json (frames carry pt_passes) and
# prints its path.
bench_pt() {
    local name=$1 elf=$2 script=$3 frames="${BENCH_FRAMES:-$M4_FRAMES}"
    local out="$CART_DIR/out/bench_m4_$name"
    "$BENCH" --version >/dev/null || { echo "bench_variants: badge-bench setup failed" >&2; return 1; }
    echo "bench_variants: row $name: $frames frames ($elf, $(basename "$script"))" >&2
    M4_BUDGET="$M4_BUDGET" PYTHONPATH="$ROOT/badge-bench" "$ROOT/badge-bench/.venv/bin/python" - "$elf" "$script" "$frames" "$out" \
        >/dev/null <<'PY' || { echo "bench_variants: badge-bench failed for row $name" >&2; return 1; }
import json, os, sys
import badge_bench.cli as CLI
import badge_bench.model as M
import badge_bench.run as RUN
from badge_bench.elf import CartElf

elf_path, script, frames, out = sys.argv[1:5]
elf = CartElf(elf_path)
want = os.environ.get("PT_PASSES_SYM")
names = [want] if want else ["pt.n_col", "pt.col_passes", "pt.column_passes", "pt.passes_done", "pt.pass_count",
                             "pt.n_passes"]
sym = next((n for n in names if n in elf.syms), None)
if want and sym is None:
    sys.exit(f"bench_variants: PT_PASSES_SYM={want} is not a symbol of {elf_path}")
if sym is None:
    print(f"bench_variants: no pass-count symbol ({', '.join(names)}) in {elf_path}; done() is guessed "
          "from the update times", file=sys.stderr)

# Keep the emulator so the hook can read the cart's RAM after each update.
ucs = []
make_uc = M.make_uc
def make_uc_kept():
    uc = make_uc()
    ucs.append(uc)
    return uc
M.make_uc = make_uc_kept

def read_passes():
    addr, size, _ = elf.syms[sym]
    b = bytes(ucs[-1].mem_read(addr, size))
    if size in (1, 2, 4):
        return int.from_bytes(b, "little")
    w = size // 160
    if size % 160 == 0 and w in (1, 2, 4):
        return min(int.from_bytes(b[i:i + w], "little") for i in range(0, size, w))
    sys.exit(f"bench_variants: {sym} is {size} bytes: want a 1, 2 or 4-byte scalar or [160] counts")

run = RUN.run
def run_hooked(*a, **kw):
    user = kw.get("log")
    def log(f):
        if sym:
            f["pt_passes"] = read_passes()
        if user:
            user(f)
    kw["log"] = log
    return run(*a, **kw)
RUN.run = run_hooked

rc = CLI.main([elf_path, "--script", script, "--frames", frames, "--every", frames, "--budget-ms", os.environ.get("M4_BUDGET", "47.0"),
               "--json", "--out", out])
if rc == 0:
    p = os.path.join(out, "bench.json")
    j = json.load(open(p))
    j["meta"]["pt_passes_sym"] = sym
    json.dump(j, open(p, "w"), indent=1)
sys.exit(rc)
PY
    echo "$out/bench.json"
}

# summarise_pt BENCH_JSON SCRIPT: "worst frame mean a_ms passes done secs ms_per_pass verdict".
# Frozen updates are those after the script's first A update.
summarise_pt() {
    python3 - "$1" "$2" "$M4_BUDGET" "$M4_FPS" "$M4_MAX_PASSES" <<'PY'
import json, statistics, sys
path, script, budget, fps, max_passes = sys.argv[1], sys.argv[2], float(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
j = json.load(open(path))
fr = j["frames"]
key = "busy_ms" if "busy_ms" in fr[0] else "ms"
a_upd = min((e["from"] for e in json.load(open(script)) if "A" in e.get("hold", [])), default=None)
if a_upd is None:
    sys.exit(f"bench_variants: {script} never holds A")
frozen = [f for f in fr if f["frame"] > a_upd]
a_ms = next((f"{f[key]:.2f}" for f in fr if f["frame"] == a_upd), "-")
if not frozen:
    w = max(fr, key=lambda f: f[key])
    print(f'{w[key]:.2f} {w["frame"]} {sum(f[key] for f in fr) / len(fr):.2f} {a_ms} - - - - short')
    sys.exit(0)
w = max(frozen, key=lambda f: f[key])
mean = sum(f[key] for f in frozen) / len(frozen)
if "pt_passes" in frozen[-1]:
    passes = frozen[-1]["pt_passes"]
    done = next((f["frame"] for f in frozen if f["pt_passes"] >= max_passes), None)
    mark = ""
else:
    passes = None
    early = statistics.median(f[key] for f in frozen[:50])
    done = next((f["frame"] for f in frozen if f[key] < 0.5 * early), None)
    mark = "~"
if done is not None:
    busy = sum(f[key] for f in frozen if f["frame"] <= done)
    secs, per, done_s = f"{mark}{(done - a_upd) / fps:.1f}", f"{mark}{busy / max_passes:.1f}", f"{mark}{done}"
elif passes:
    secs, per, done_s = f">{len(frozen) / fps:.1f}", f"{sum(f[key] for f in frozen) / passes:.1f}", "not-yet"
else:
    secs, per, done_s = "-", "-", "not-yet"
verdict = "PASS" if w[key] <= budget else "OVER"
print(f'{w[key]:.2f} {w["frame"]} {mean:.2f} {a_ms} {"-" if passes is None else passes} {done_s} {secs} {per} {verdict}')
PY
}

# block_worst BLOCKS PRESET: the worst ms of PRESET in a row-2 block summary
# "sunset:46.36@123/44.10,midnight:...", or "-".
block_worst() {
    python3 - "$1" "$2" <<'PY'
import sys
b = dict((p.split(":")[0], p.split(":")[1].split("@")[0]) for p in sys.argv[1].split(",") if ":" in p)
print(b.get(sys.argv[2], "-"))
PY
}

bench_m4() {
    local want=("$@") rows=() status=0 elf res worst frame mean blocks verdict note
    [ ${#want[@]} -eq 0 ] && want=(5 6 1 2)
    for row in "${want[@]}"; do
        case "$row" in
        5|6)
            elf=$(m3_elf default) || exit 1
            has_pt "$elf" || { echo "bench_variants: $elf has no pt.zig symbols (an M3 build?); rebuild with REBUILD=1" >&2; exit 1; }
            local names=() s sf json a_ms passes done secs per
            if [ "$row" = 5 ]; then names=(sunset midnight noon); else names=(stick); fi
            for s in "${names[@]}"; do
                sf="$M4_SCRIPTS/m4_freeze_$s.json"
                [ "$s" = stick ] && sf="$M4_SCRIPTS/m4_frozen_stick.json"
                [ -f "$sf" ] || { echo "bench_variants: $sf missing (the M4 input scripts, Track B)" >&2; exit 1; }
                json=$(bench_pt "$row-$s" "$elf" "$sf") || exit 1
                read -r worst frame mean a_ms passes done secs per verdict < <(summarise_pt "$json" "$sf")
                if [ "$row" = 6 ]; then
                    rows+=("6-stick|$worst|$frame|$mean|$a_ms|report|not gated; passes $passes at the end")
                else
                    [ "$verdict" = PASS ] || status=3
                    rows+=("5-$s|$worst|$frame|$mean|$a_ms|$verdict|passes $passes; done at update $done, $secs s to $M4_MAX_PASSES passes at $M4_FPS fps; $per ms/pass")
                fi
            done
            ;;
        1)
            elf=$(m3_elf motion_off) || exit 1
            has_pt "$elf" || echo "bench_variants: warning: $elf has no pt.zig symbols (an M3 build?); REBUILD=1 for M4 numbers" >&2
            res=$(BENCH_PREFIX=bench_m4_ bench_row m3row1 "$elf" 600 0) || exit 1
            read -r worst frame mean <<< "$res"
            note=$(python3 -c "d = $worst - $M3_ROW1; print(f'{d:+.2f} ms vs M3 {$M3_ROW1:.2f}' + (' MOVED' if abs(d) > $M4_MOVE_LIMIT else ''))")
            verdict=PASS
            python3 -c "import sys; sys.exit(0 if abs($worst - $M3_ROW1) <= $M4_MOVE_LIMIT else 1)" || { verdict=MOVED; status=3; }
            rows+=("1-step1|$worst|$frame|$mean|-|$verdict|$note")
            ;;
        2)
            elf=$(m3_elf default) || exit 1
            has_pt "$elf" || echo "bench_variants: warning: $elf has no pt.zig symbols (an M3 build?); REBUILD=1 for M4 numbers" >&2
            res=$(BENCH_PREFIX=bench_m4_ bench_row m3row2 "$elf" 2400 600) || exit 1
            read -r worst frame mean blocks <<< "$res"
            verdict=PASS
            note=""
            local p base got
            for p in sunset midnight noon storm; do
                base="M3_ROW2_${p^^}"
                base=${!base}
                got=$(block_worst "${blocks:-}" "$p")
                if [ "$got" = - ]; then note+="$p - "; continue; fi
                note+=$(python3 -c "d = $got - $base; print(f'$p {$got:.2f} ({d:+.2f})' + (' MOVED' if abs(d) > $M4_MOVE_LIMIT else ''), end='')")
                note+=" "
                python3 -c "import sys; sys.exit(0 if abs($got - $base) <= $M4_MOVE_LIMIT else 1)" || { verdict=MOVED; status=3; }
            done
            rows+=("2-attract|$worst|$frame|$mean|-|$verdict|per preset worst vs M3: $note")
            ;;
        *) echo "bench_variants: unknown M4 row '$row' (want 5 6 1 2)" >&2; exit 2 ;;
        esac
    done

    printf '\nM4 bench, %s, calibrated busy ms; row 5 gate %s ms on every frozen update; rows 1, 2 within %s ms of M3\n' \
        "$M3_VARIANT" "$M4_BUDGET" "$M4_MOVE_LIMIT"
    printf '%-12s %9s %7s %8s %7s  %-7s %s\n' row "worst ms" frame "mean ms" "A upd" verdict notes
    for r in "${rows[@]}"; do
        IFS='|' read -r name worst frame mean a_ms verdict note <<< "$r"
        printf '%-12s %9s %7s %8s %7s  %-7s %s\n' "$name" "$worst" "$frame" "$mean" "$a_ms" "$verdict" "$note"
    done
    return $status
}

if [ "${1:-}" = "--m4" ]; then
    shift
    bench_m4 "$@"
elif [ "${1:-}" = "--m3" ]; then
    shift
    bench_m3 "$@"
else
    bench_m21 "$@"
fi
