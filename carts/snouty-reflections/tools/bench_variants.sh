#!/usr/bin/env bash
# Benchmark the M2.1 firmware variants (PLAN.md "M2.1 Perf variants") with
# badge-bench: calibrated busy ms (the default), cart default dither, one
# orbit per variant (orbit_frames = 30 * fps), then one table.
#
#   tools/bench_variants.sh                  # every variant with dist/variants/<name>.elf
#   tools/bench_variants.sh cut20 half30     # just these
#
# Run from anywhere; the ELFs come from tools/build_variants.sh. Each run's
# report.txt and bench.json land in out/bench_<name>/ under the cart
# directory. A variant without its ELF is listed as "no elf" and skipped.
# Environment: VARIANTS_DIR (default dist/variants) to bench other ELFs,
# BENCH_FRAMES=N to cut every run to N frames (smoke test only).
# Exit status: 0 when every benched variant is within budget, 3 otherwise,
# 1 when badge-bench fails.
set -euo pipefail

CART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$CART_DIR/../../badge-bench/bench.sh"
VARIANTS_DIR="${VARIANTS_DIR:-$CART_DIR/dist/variants}"

# name frames budget_ms (94% of the frame period)
VARIANTS="full20 600 47.0
cut20 600 47.0
full15 450 62.7
half30 900 31.3"

want=("$@")
rows=()
status=0
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
    row=$(python3 - "$out/bench.json" "$name" "$budget" <<'EOF'
import json, sys
j = json.load(open(sys.argv[1]))
s = j["summary"]                     # busy ms when calibrated (the default)
budget = float(sys.argv[3])
verdict = "PASS" if s["max_ms"] <= budget else "OVER"
print(f'{sys.argv[2]} {s["max_ms"]:.2f} {s["worst_frame"]} {s["mean_ms"]:.2f} {budget:.1f} {verdict}')
EOF
)
    rows+=("$row")
    [[ "$row" == *OVER ]] && status=3
done <<< "$VARIANTS"

printf '\n%-8s %10s %7s %9s %10s  %s\n' variant "worst ms" frame "mean ms" "budget ms" verdict
for r in "${rows[@]}"; do
    read -r name worst frame mean budget verdict <<< "$r"
    printf '%-8s %10s %7s %9s %10s  %s\n' "$name" "$worst" "$frame" "$mean" "$budget" "${verdict/no-elf/no elf (run tools/build_variants.sh)}"
done
exit $status
