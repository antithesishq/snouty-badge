#!/usr/bin/env bash
# Render regression check (SPEC.md 10, PLAN.md M2 "Scripts, hashes, bench").
#
#   tools/check_render.sh [--update] [WASM]
#
# Runs tools/preview.mjs over tools/scripts/attract.json for 2400 frames and
# checks debug_pixel_checksum after each frame T listed in
# tools/render_hashes.txt (lines "T V": frames 0, 200, ..., 2200; V is the
# checksum as preview.mjs reads it, an i32). The cart is all-integer, so the
# frames are bit-exact and any change to the picture changes a checksum.
# --update regenerates render_hashes.txt from one run (--call-at) instead
# of checking. WASM defaults to ../../zig-out/bin/snouty-flyover.wasm; run
# from carts/snouty-flyover or anywhere (paths are relative to this script).
# Exit 0 on pass, 3 on a mismatch (preview.mjs's code), 1/2 on errors.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart_dir="$(dirname "$here")"
root="$(cd "$cart_dir/../.." && pwd)"
hashes="$here/render_hashes.txt"
frames=2400
ticks=(0 200 400 600 800 1000 1200 1400 1600 1800 2000 2200)

update=0
wasm="$root/zig-out/bin/snouty-flyover.wasm"
for arg in "$@"; do
    case "$arg" in
        --update) update=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) wasm="$arg" ;;
    esac
done
[ -f "$wasm" ] || { echo "check_render: no wasm at $wasm (zig build -Dcart=snouty-flyover first)" >&2; exit 1; }

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
preview=(node "$root/tools/preview.mjs" "$wasm" --frames "$frames" --quiet
    --script "$cart_dir/tools/scripts/attract.json" --out "$out")

if [ "$update" = 1 ]; then
    args=()
    for t in "${ticks[@]}"; do args+=(--call-at "$t debug_pixel_checksum"); done
    "${preview[@]}" "${args[@]}" 2>/dev/null
    python3 - "$out/frames.json" "$hashes" <<'PY'
import json, sys
calls = json.load(open(sys.argv[1]))["calls"]
with open(sys.argv[2], "w") as f:
    for c in calls:
        f.write(f"{c['tick']} {c['value']}\n")
print(f"check_render: wrote {len(calls)} checksums to {sys.argv[2]}")
PY
    exit 0
fi

[ -f "$hashes" ] || { echo "check_render: no $hashes (run with --update)" >&2; exit 1; }
args=()
n=0
while read -r t v; do
    [ -z "${t:-}" ] && continue
    case "$t" in \#*) continue ;; esac
    args+=(--at "$t debug_pixel_checksum == $v")
    n=$((n + 1))
done < "$hashes"
set +e
"${preview[@]}" "${args[@]}" 2>&1 | grep -E 'FAIL|expectation|error|trap' >&2
status=${PIPESTATUS[0]}
set -e
if [ "$status" = 0 ]; then
    echo "check_render: PASS ($n frames match tools/render_hashes.txt)"
else
    echo "check_render: FAIL (exit $status; tools/check_render.sh --update rebuilds the list after an intended change)" >&2
fi
exit "$status"
