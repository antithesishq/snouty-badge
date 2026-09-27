#!/usr/bin/env bash
# Full verification (PLAN.md "Verification for M1/M2"). Runs from this cart's
# directory whatever the caller's cwd; zig build runs at the repository root
# (two levels up), which is where zig-out/ lives.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."
repo="../.."
# Levels: every level solvable, and the generated data file matching the .txt sources.
python3 tools/check_level.py cart/src/levels/build_farm.txt cart/src/levels/staging.txt cart/src/levels/production.txt cart/src/levels/test.txt cart/src/levels/wolf_e1m1.txt
tools/gen_levels.sh
git diff --exit-code -- cart/src/levels/gen.zig || { echo "check: cart/src/levels/gen.zig is stale; commit the regenerated file"; exit 1; }
(cd "$repo" && zig build -Dcart=snoutenstein)
size -A "$repo/zig-out/firmware/snoutenstein.elf" | grep -E "^\.text|^\.data|^\.bss"
zig test cart/src/sim.zig
zig test cart/src/levels.zig
zig test cart/src/level_parse.zig
zig test cart/src/rewind.zig
W="$repo/zig-out/bin/snoutenstein.wasm"
# M1: walk the long corridor, doors, pause.
node ../../tools/preview.mjs $W --frames 2160 --every 8 --out out/walk \
  --script tools/scripts/m1_walk.json \
  --dump-exports debug_mode,debug_tick,debug_px,debug_py,debug_angle,debug_render_us,debug_sprites \
  --expect "debug_mode == 1" --expect "debug_px > 393216"
node ../../tools/preview.mjs $W --frames 600 --quiet --out out/doors \
  --script tools/scripts/m1_doors.json \
  --dump-exports debug_mode,debug_px,debug_py --expect "debug_px > 491520"
node ../../tools/preview.mjs $W --frames 600 --quiet --out out/pause \
  --script tools/scripts/m1_pause.json --dump-exports debug_mode,debug_px --expect "debug_mode == 1" --expect "debug_px < 425984"
# M2: zap the gnat ahead of the start, cycle weapons; walk to the exit and
# through the intermission into level 1.
node ../../tools/preview.mjs $W --frames 240 --every 6 --out out/combat \
  --script tools/scripts/m2_combat.json \
  --dump-exports debug_mode,debug_kills,debug_weapon,debug_ammo,debug_hp,debug_state_hash,debug_nibble_ok \
  --expect "debug_nibble_ok == 1" --expect "debug_kills == 1" --expect "debug_weapon == 1" --expect "debug_ammo == 38"
node ../../tools/preview.mjs $W --frames 1400 --every 10 --out out/exit \
  --script tools/scripts/m2_exit.json \
  --dump-exports debug_mode,debug_level,debug_tick,debug_px,debug_py \
  --expect "debug_mode == 1" --expect "debug_level == 4"
# M3: a gnat wakes and bites; death freeze, hold B, level restarts; Build Farm opens.
node ../../tools/preview.mjs $W --frames 360 --quiet --out out/gnat --script tools/scripts/m3_gnat.json \
  --dump-exports debug_mode,debug_hp,debug_tick --expect "debug_mode == 1" --expect "debug_hp < 100" --expect "debug_hp > 0"
node ../../tools/preview.mjs $W --frames 1100 --every 25 --out out/death --script tools/scripts/m3_death.json \
  --dump-exports debug_mode,debug_hp,debug_tick --expect "debug_mode == 1" --expect "debug_tick < 300" --expect "debug_hp > 0"
node ../../tools/preview.mjs $W --frames 420 --every 10 --out out/buildfarm --script tools/scripts/m3_buildfarm.json \
  --dump-exports debug_mode,debug_level,debug_hp,debug_px,debug_kills \
  --expect "debug_level == 0" --expect "debug_px > 720896" --expect "debug_hp > 0"
node tools/check_determinism.mjs $W --script tools/scripts/m3_buildfarm.json --frames 420
node tools/check_determinism.mjs $W --script tools/scripts/m2_combat.json --frames 240
echo "check: all passed"
