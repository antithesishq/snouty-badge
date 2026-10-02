#!/usr/bin/env bash
# The cart's preview gate: the render golden and the long-flight soak.
#
#   tools/check.sh [WASM]
#
# 1. tools/check_render.sh: twelve frame checksums of the 2400-update
#    attract run against tools/render_hashes.txt.
# 2. Skip soak (review 2026-10-01 G2): tools/scripts/skip_soak.json presses
#    Select every 5 updates, 130 times, which carries the camera past row
#    32768 (where an i32 Q16 y used to wrap negative and the ring stopped
#    generating). debug_cam_y must stay positive across the crossing and the
#    ring must be consistent at the end (debug_world_check == 0).
# WASM defaults to ../../zig-out/bin/snouty-flyover.wasm (zig build
# -Dcart=snouty-flyover first). Exit 0 on pass, 3 on a failed expectation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cart_dir="$(dirname "$here")"
root="$(cd "$cart_dir/../.." && pwd)"
wasm="${1:-$root/zig-out/bin/snouty-flyover.wasm}"
[ -f "$wasm" ] || { echo "check: no wasm at $wasm (zig build -Dcart=snouty-flyover first)" >&2; exit 1; }

"$here/check_render.sh" "$wasm"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
set +e
node "$root/tools/preview.mjs" "$wasm" --frames 660 --quiet \
    --script "$here/scripts/skip_soak.json" --out "$out" \
    --at '634 debug_cam_y > 0' --at '639 debug_cam_y > 0' \
    --expect 'debug_cam_y > 32768' --expect 'debug_skips == 130' \
    --expect 'debug_world_check == 0' 2>&1 | grep -E 'FAIL|error|trap' >&2
status=${PIPESTATUS[0]}
set -e
if [ "$status" = 0 ]; then
    echo "check: PASS (skip soak: 130 skips past row 32768, ring consistent)"
else
    echo "check: FAIL (skip soak, exit $status)" >&2
fi
exit "$status"
