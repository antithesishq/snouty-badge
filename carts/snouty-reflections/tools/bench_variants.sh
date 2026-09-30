#!/usr/bin/env bash
# Benchmark snouty-reflections with badge-bench (calibrated busy ms, the
# default) and print one table.
#
#   tools/bench_variants.sh                  # M2.1: one orbit per variant with dist/variants/<name>.elf
#   tools/bench_variants.sh cut20 half30     # just these
#   tools/bench_variants.sh --m3             # M3 rows 1-4 (PLAN.md M3 "Budget and bench") for cut20
#   tools/bench_variants.sh --m3 2 4         # just rows 2 and 4
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
# Run from anywhere. Each run's report.txt and bench.json land in
# out/bench_<name>/ (M2.1) or out/bench_m3_<row>/ (M3) under the cart
# directory. Environment: VARIANTS_DIR (default dist/variants) to bench
# other ELFs in M2.1 mode, BENCH_FRAMES=N to cut every run to N frames
# (smoke test only), ZIG (default zig on PATH).
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
    local out="$CART_DIR/out/bench_m3_$name"
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

if [ "${1:-}" = "--m3" ]; then
    shift
    bench_m3 "$@"
else
    bench_m21 "$@"
fi
