#!/usr/bin/env bash
# Party deathmatch bench (PLAN.md M8): badge-bench has no network, so
# `--poke stein_party_bench=V` starts a local match at the first update
# with every slot on bot.zig, one tick a frame as if every badge's input
# had arrived (main.zig: bit 31 on, rules bytes in bits 0-15 as
# match.Rules.encode2, players in bits 16-20 with 0 = 16, the shown slot in
# bits 24-27). The cases (BUGS ON, 25 frags so no match ends in the run):
#
#   Data Hall, 16 bots       the arena built for 16
#   Server Room, 16 bots     six spawns for sixteen: the render worst case,
#                            many rivals close up in a small room
#
# Gate: worst frame < 12 ms (busy ms, calibrated).
#
#   tools/bench_m8.sh [FRAMES]        (default 1200, 20 s each)
#
# Builds nothing: run `zig build -Dcart=snoutenstein` at the repository
# root first. Runs from this cart's directory whatever the caller's cwd.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="../.."
frames="${1:-1200}"
elf="$repo/zig-out/firmware/snoutenstein.elf"
# Rules byte 0: arena bits 0-1, frag index bits 2-3 and 5 (index 4 = 25:
# 0x20), bugs bit 4; byte 1 (team mode) 0 = FFA.
for arena in 2 0; do
  rules=$((arena | 0x20 | 0x10))
  v=$(( (1 << 31) | rules ))
  echo "== party bench: arena $arena, 16 bots, rules 0x$(printf %02x $rules), $frames frames"
  "$repo/badge-bench/bench.sh" "$elf" --no-config --frames "$frames" --every 100000 \
    --poke "stein_party_bench=$v" | grep -E "worst|busy ms|verdict"
done
