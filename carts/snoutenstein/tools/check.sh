#!/usr/bin/env bash
# M1 verification (PLAN.md "Verification for M1"). Run from the repo root.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
zig build
size -A zig-out/firmware/snoutenstein.elf | grep -E "^\.text|^\.data|^\.bss"
zig test cart/src/sim.zig
zig test cart/src/levels.zig
node tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 900 --every 6 --out out/walk \
  --script tools/scripts/m1_walk.json \
  --dump-exports debug_mode,debug_tick,debug_px,debug_py,debug_angle,debug_render_us \
  --expect "debug_mode == 1" --expect "debug_px > 393216"
node tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 600 --quiet --out out/doors \
  --script tools/scripts/m1_doors.json \
  --dump-exports debug_mode,debug_px,debug_py --expect "debug_px > 491520"
node tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 600 --quiet --out out/pause \
  --script tools/scripts/m1_pause.json --dump-exports debug_mode --expect "debug_mode == 1"
echo "check: all passed"
