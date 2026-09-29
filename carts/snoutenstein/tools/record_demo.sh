#!/usr/bin/env bash
# Record the attract demo's expected hash (PLAN.md M5). The log may end with
# the player dead (the cart compares the hash either way and returns to the
# title). Runs the demo script
# in normal play with the demo seed (`--call debug_new_game_seeded`, tick 0 =
# update 0), reads sim.hash_gameplay after the last tick and regenerates
# cart/src/demos/build_farm.zig with it. Rebuild afterwards; tools/check.sh
# then proves the embedded log reproduces the hash in demo mode.
#
#   tools/record_demo.sh [SCRIPT.json] [OUT.zig]
set -euo pipefail
cd "$(dirname "$0")/.."
script="${1:-tools/scripts/demo_build_farm.json}"
out="${2:-cart/src/demos/build_farm.zig}"
# The level is whatever the current data file says (the wasm was built from
# it, and debug_new_game_seeded starts that level); change it with
# `tools/gen_demo.py --level N` plus a rebuild before recording.
level=$(grep -o 'level_index: u8 = [0-9]*' "$out" | sed 's/.*= //')
W="../../zig-out/bin/snoutenstein.wasm"
[ -f "$W" ] || { echo "record_demo: $W missing; run 'zig build -Dcart=snoutenstein' at the repository root" >&2; exit 1; }
total=$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); print(max(x["to"] for x in e)+1)' "$script")
last=$((total - 1))
mkdir -p out/record
node ../../tools/preview.mjs "$W" --frames "$total" --quiet --out out/record \
  --call debug_new_game_seeded --script "$script" \
  --call-at "$last debug_gameplay_hash" --call-at "$last debug_tick" --call-at "$last debug_hp" --call-at "$last debug_mode" \
  --dump-exports debug_desync,debug_hp,debug_mode,debug_tick,debug_level --expect "debug_desync == 0" --expect "debug_level == $level" >/dev/null
read -r hash tick hp mode < <(python3 - out/record/frames.json <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
v={c["name"]:c["value"] for c in j["calls"]}
print(v["debug_gameplay_hash"] & 0xFFFFFFFF, v["debug_tick"], v["debug_hp"], v["debug_mode"])
PY
)
if [ "$tick" != "$total" ]; then echo "record_demo: expected debug_tick == $total after update $last, got $tick (a rewind or death changed the tick count; the demo still ends at update $last)" >&2; fi
printf 'record_demo: %s ticks, final tick %s, hp %s, mode %s, hash 0x%08X\n' "$total" "$tick" "$hp" "$mode" "$hash"
[ "$mode" = 1 ] || [ "$mode" = 5 ] || { echo "record_demo: the demo must end playing (1) or dead (5), got mode $mode" >&2; exit 1; }
python3 tools/gen_demo.py "$script" --out "$out" --hash "$hash" --level "$level"
