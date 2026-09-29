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
zig test cart/src/demo.zig
W="$repo/zig-out/bin/snoutenstein.wasm"
# M1: walk the long corridor, doors, pause.
node ../../tools/preview.mjs $W --frames 2160 --every 8 --out out/walk \
  --script tools/scripts/m1_walk.json \
  --dump-exports debug_mode,debug_tick,debug_px,debug_py,debug_angle,debug_render_us,debug_sprites,debug_desync \
  --expect "debug_desync == 0" --expect "debug_mode == 1" --expect "debug_px > 393216"
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
# M3: a gnat wakes and bites; death freeze, hold B, time runs back to life; Build Farm opens.
node ../../tools/preview.mjs $W --frames 360 --quiet --out out/gnat --script tools/scripts/m3_gnat.json \
  --dump-exports debug_mode,debug_hp,debug_tick --expect "debug_mode == 1" --expect "debug_hp < 100" --expect "debug_hp > 0"
node ../../tools/preview.mjs $W --frames 1100 --every 25 --out out/death --script tools/scripts/m3_death.json \
  --dump-exports debug_mode,debug_hp,debug_tick,debug_rewinds,debug_desync --at "899 debug_mode == 5" --at "1001 debug_mode == 1" --at "1001 debug_hp > 0" --at "1001 debug_tick == 541" \
  --expect "debug_rewinds == 1" --expect "debug_desync == 0"
node ../../tools/preview.mjs $W --frames 420 --every 10 --out out/buildfarm --script tools/scripts/m3_buildfarm.json \
  --dump-exports debug_mode,debug_level,debug_hp,debug_px,debug_kills \
  --expect "debug_level == 0" --expect "debug_px > 720896" --expect "debug_hp > 0"
# M4: hold B for a second while walking (time runs back 60 ticks); die at
# tick 642 and hold B until the full meter is spent (600 ticks back, forced
# commit, alive); drain the meter dry while alive (forced commit).
node ../../tools/preview.mjs $W --frames 360 --every 6 --out out/rewind --script tools/scripts/m4_rewind.json \
  --dump-exports debug_mode,debug_tick,debug_rewinds,debug_meter,debug_desync \
  --at "260 debug_mode == 6" --at "300 debug_mode == 1" --at "300 debug_tick == 169" --at "300 debug_meter == 540" \
  --expect "debug_mode == 1" --expect "debug_tick == 228" --expect "debug_meter == 550" --expect "debug_rewinds == 1" --expect "debug_desync == 0"
node ../../tools/preview.mjs $W --frames 1510 --quiet --out out/death4 --script tools/scripts/m4_death.json \
  --dump-exports debug_mode,debug_hp,debug_tick,debug_rewinds,debug_meter,debug_desync \
  --at "899 debug_mode == 5" --at "1200 debug_mode == 6" --at "1200 debug_tick == 341" \
  --at "1499 debug_mode == 6" --at "1500 debug_mode == 1" --at "1500 debug_tick == 42" --at "1500 debug_meter == 0" --at "1500 debug_hp > 0" \
  --expect "debug_rewinds == 1" --expect "debug_desync == 0"
node ../../tools/preview.mjs $W --frames 1500 --quiet --out out/empty --script tools/scripts/m4_empty.json \
  --dump-exports debug_mode,debug_tick,debug_rewinds,debug_meter,debug_desync \
  --at "1399 debug_mode == 6" --at "1399 debug_meter == 0" --at "1400 debug_mode == 1" --at "1400 debug_tick == 189" \
  --expect "debug_mode == 1" --expect "debug_tick == 288" --expect "debug_rewinds == 1" --expect "debug_desync == 0"
node tools/check_determinism.mjs $W --script tools/scripts/m3_buildfarm.json --frames 420
node tools/check_determinism.mjs $W --script tools/scripts/m2_combat.json --frames 240
node tools/check_determinism.mjs $W --script tools/scripts/m1_walk.json --frames 600 --rewind-at 200 --rewind-for 90
# M5: the demo data file matches its script (hash kept); the title idles
# 600 ticks into the demo and the demo returns to the title when its log
# ends; the embedded log replays to the recorded hash (DEMO OK); UP at
# update 700 takes the demo over without stepping and refills the meter.
demo_hash=$(grep -o 'final_hash: u32 = 0x[0-9A-F]*' cart/src/demos/build_farm.zig | sed 's/.*= //')
python3 tools/gen_demo.py tools/scripts/demo_build_farm.json --out out/demo_check.zig --hash "$demo_hash" >/dev/null
diff -q out/demo_check.zig cart/src/demos/build_farm.zig >/dev/null || { echo "check: cart/src/demos/build_farm.zig is stale; run tools/record_demo.sh and rebuild"; exit 1; }
[ "$demo_hash" != "0x00000000" ] || { echo "check: demo hash not recorded; run tools/record_demo.sh"; exit 1; }
demo_ticks=$(python3 -c 'import json; print(max(e["to"] for e in json.load(open("tools/scripts/demo_build_farm.json")))+1)')
node ../../tools/preview.mjs $W --frames $((600 + demo_ticks + 30)) --quiet --out out/attract --script tools/scripts/m5_attract.json \
  --dump-exports debug_mode,debug_demo,debug_tick,debug_demo_result,debug_desync \
  --at "598 debug_mode == 0" --at "599 debug_demo == 1" --at "600 debug_tick == 1" --at "$((599 + demo_ticks)) debug_demo == 1" --at "$((600 + demo_ticks)) debug_demo == 0" \
  --expect "debug_mode == 0" --expect "debug_demo_result == 1" --expect "debug_desync == 0"
node ../../tools/preview.mjs $W --frames $((demo_ticks + 5)) --quiet --out out/demo --call debug_start_demo \
  --dump-exports debug_mode,debug_demo,debug_demo_result,debug_tick,debug_desync \
  --expect "debug_demo_result == 1" --expect "debug_mode == 0" --expect "debug_desync == 0"
node ../../tools/preview.mjs $W --frames 900 --quiet --out out/takeover --script tools/scripts/m5_takeover.json \
  --dump-exports debug_mode,debug_demo,debug_tick,debug_meter,debug_desync \
  --call-at "699 debug_tick" --call-at "700 debug_tick" \
  --at "699 debug_demo == 1" --at "700 debug_demo == 0" --at "700 debug_mode == 1" --at "700 debug_meter == 600" \
  --expect "debug_mode == 1" --expect "debug_desync == 0"
node tools/check_determinism.mjs $W --script tools/scripts/m5_takeover.json --frames 900
echo "check: all passed"
