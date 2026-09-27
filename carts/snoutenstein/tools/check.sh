#!/usr/bin/env bash
# Full verification (PLAN.md "Verification for M1/M2"). Run from the repo root.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
zig build
size -A zig-out/firmware/snoutenstein.elf | grep -E "^\.text|^\.data|^\.bss"
zig test cart/src/sim.zig
zig test cart/src/levels.zig
zig test cart/src/rewind.zig
W=zig-out/bin/snoutenstein.wasm
# M1: walk the long corridor, doors, pause.
node tools/preview.mjs $W --frames 2160 --every 8 --out out/walk \
  --script tools/scripts/m1_walk.json \
  --dump-exports debug_mode,debug_tick,debug_px,debug_py,debug_angle,debug_render_us,debug_sprites \
  --expect "debug_mode == 1" --expect "debug_px > 393216"
node tools/preview.mjs $W --frames 600 --quiet --out out/doors \
  --script tools/scripts/m1_doors.json \
  --dump-exports debug_mode,debug_px,debug_py --expect "debug_px > 491520"
node tools/preview.mjs $W --frames 600 --quiet --out out/pause \
  --script tools/scripts/m1_pause.json --dump-exports debug_mode,debug_px --expect "debug_mode == 1" --expect "debug_px < 425984"
# M2: zap the gnat ahead of the start, cycle weapons; walk to the exit and
# through the intermission into level 1.
node tools/preview.mjs $W --frames 240 --every 6 --out out/combat \
  --script tools/scripts/m2_combat.json \
  --dump-exports debug_mode,debug_kills,debug_weapon,debug_ammo,debug_hp,debug_state_hash,debug_nibble_ok \
  --expect "debug_nibble_ok == 1" --expect "debug_kills == 1" --expect "debug_weapon == 1" --expect "debug_ammo == 38"
node tools/preview.mjs $W --frames 1400 --every 10 --out out/exit \
  --script tools/scripts/m2_exit.json \
  --dump-exports debug_mode,debug_level,debug_tick,debug_px,debug_py \
  --expect "debug_mode == 1" --expect "debug_level == 1"
echo "check: all passed"
