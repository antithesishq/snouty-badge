#!/bin/sh
# Review EM-01 regression (wasm, headless): an A and a Left pressed on the
# update the Select hold opens the menu must not act on it (no scrub, menu
# stays up); a fresh Left after release scrubs. Run from the repository root
# after `zig build -Dcart=snouty-gear`:
#   sh carts/snouty-gear/tools/check_menu_entry.sh [zig-out/bin/snouty-gear.wasm]
# The Select hold starts at update 120 and opens the menu on update 149.
set -e
wasm=${1:-zig-out/bin/snouty-gear.wasm}
node tools/preview.mjs "$wasm" --frames 200 --quiet \
    --script carts/snouty-gear/tools/scripts/menu_entry.json \
    --at "148 debug_state == 1" --at "150 debug_state == 2" \
    --at "170 debug_state == 2" --at "170 debug_scrub_depth == 0" \
    --at "180 debug_state == 2" --at "180 debug_scrub_depth > 0"
