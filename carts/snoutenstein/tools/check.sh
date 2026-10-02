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
# The dormant LED path (docs/NEOPIXELS.md) must keep compiling; build it
# first so the default build below is what lands in zig-out/.
(cd "$repo" && zig build -Dcart=snoutenstein -Dneopixels=true)
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
# M3: a gnat wakes and bites; death freeze, hold B, time runs back to life
# revived (HP >= 25, 2 s grace, the 2026-10-02 death-loop fix); Build Farm opens.
node ../../tools/preview.mjs $W --frames 360 --quiet --out out/gnat --script tools/scripts/m3_gnat.json \
  --dump-exports debug_mode,debug_hp,debug_tick --expect "debug_mode == 1" --expect "debug_hp < 100" --expect "debug_hp > 0"
node ../../tools/preview.mjs $W --frames 1300 --every 25 --out out/death --script tools/scripts/m3_death.json \
  --dump-exports debug_mode,debug_hp,debug_tick,debug_rewinds,debug_grace,debug_desync --at "1099 debug_mode == 5" --at "1201 debug_mode == 1" --at "1201 debug_hp >= 25" --at "1201 debug_tick == 933" \
  --at "1201 debug_grace == 120" --at "1299 debug_grace == 22" \
  --expect "debug_rewinds == 1" --expect "debug_desync == 0"
node ../../tools/preview.mjs $W --frames 420 --every 10 --out out/buildfarm --script tools/scripts/m3_buildfarm.json \
  --dump-exports debug_mode,debug_level,debug_hp,debug_px,debug_kills \
  --expect "debug_level == 0" --expect "debug_px > 720896" --expect "debug_hp > 0"
# M4: hold B for a second while walking (time runs back 60 ticks); die at
# tick 1034 (one gnat, 4 HP every 40 ticks since M5.1) and hold B until
# the full meter is spent (600 ticks back, forced commit, alive); drain the
# meter dry while alive (forced commit).
node ../../tools/preview.mjs $W --frames 360 --every 6 --out out/rewind --script tools/scripts/m4_rewind.json \
  --dump-exports debug_mode,debug_tick,debug_rewinds,debug_meter,debug_desync \
  --at "260 debug_mode == 6" --at "300 debug_mode == 1" --at "300 debug_tick == 169" --at "300 debug_meter == 540" \
  --expect "debug_mode == 1" --expect "debug_tick == 228" --expect "debug_meter == 550" --expect "debug_rewinds == 1" --expect "debug_desync == 0"
node ../../tools/preview.mjs $W --frames 1710 --quiet --out out/death4 --script tools/scripts/m4_death.json \
  --dump-exports debug_mode,debug_hp,debug_tick,debug_rewinds,debug_meter,debug_desync \
  --at "1099 debug_mode == 5" --at "1400 debug_mode == 6" --at "1400 debug_tick == 733" \
  --at "1699 debug_mode == 6" --at "1700 debug_mode == 1" --at "1700 debug_tick == 434" --at "1700 debug_meter == 0" --at "1700 debug_hp > 0" \
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
demo_level=$(grep -o 'level_index: u8 = [0-9]*' cart/src/demos/build_farm.zig | sed 's/.*= //')
python3 tools/gen_demo.py tools/scripts/demo_build_farm.json --out out/demo_check.zig --hash "$demo_hash" --level "$demo_level" >/dev/null
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
# Review 2026-10-01 G1: UP at update 1900 takes the demo over during its
# hold-B rewind; the rewind is committed and the meter refilled at the same
# tick, counted once (live == replay, no desync).
node ../../tools/preview.mjs $W --frames 1960 --quiet --out out/takeover_rewind --press UP:1900-1900 \
  --dump-exports debug_mode,debug_rewinds,debug_desync,debug_demo \
  --at "1899 debug_mode == 6" --at "1899 debug_rewinds == 0" --at "1900 debug_rewinds == 1" --at "1900 debug_demo == 0" \
  --expect "debug_rewinds == 1" --expect "debug_desync == 0"
# M5.2: the secret door in the test level's start room looks like the wall
# until walked into, then slides open into the corridor below (py > 8).
node ../../tools/preview.mjs $W --frames 340 --quiet --out out/secret --script tools/scripts/m5_secret.json \
  --dump-exports debug_mode,debug_px,debug_py --at "129 debug_py < 262144" --expect "debug_mode == 1" --expect "debug_py > 524288"
# M6: the cartridge at (5, 5) in the test level (reached at tick 97) selects the Debugger with 3
# charges; the first bolt bursts on the gnat (one kill at tick 202); the
# second flies 5 cells to the west wall and bursts there; the player is
# never hurt by a burst.
node ../../tools/preview.mjs $W --frames 340 --every 10 --out out/debugger --script tools/scripts/m6_debugger.json \
  --dump-exports debug_mode,debug_kills,debug_weapon,debug_ammo,debug_projectiles,debug_hp,debug_desync \
  --at "96 debug_weapon == 1" --at "97 debug_weapon == 3" --at "97 debug_ammo == 3" --at "199 debug_kills == 0" --at "202 debug_kills == 1" \
  --at "202 debug_projectiles == 1" --at "208 debug_projectiles == 0" --at "262 debug_ammo == 1" --at "300 debug_projectiles == 1" \
  --expect "debug_mode == 1" --expect "debug_kills == 1" --expect "debug_projectiles == 0" --expect "debug_hp == 88" --expect "debug_desync == 0"
node tools/check_determinism.mjs $W --script tools/scripts/m6_debugger.json --frames 340
echo "check: all passed"
