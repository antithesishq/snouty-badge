#!/usr/bin/env bash
# Deathmatch bench (PLAN.md M7): badge-bench has no link cable, so
# `--poke stein_dm_bench=N` starts a local match at the first update with
# both players on bot.zig, stepping once a frame as if the partner's input
# had arrived (rules byte N - 1, match.Rules: arena bits 0-1, frag limit
# bits 2-3, bugs bit 4). Both arenas with BUGS ON (the heavier case), 20
# frags so neither match ends inside the run. Gate: worst frame < 12 ms.
#
#   tools/bench_m7.sh [FRAMES]        (default 3600, one minute each)
#
# Builds nothing: run `zig build -Dcart=snoutenstein` at the repository
# root first. Runs from this cart's directory whatever the caller's cwd.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="../.."
frames="${1:-3600}"
elf="$repo/zig-out/firmware/snoutenstein.elf"
# Server Room (arena 0) and Build Farm DM (arena 1), frags 20 (3 << 2), bugs on (16).
for arena in 0 1; do
  rules=$((arena | 12 | 16))
  echo "== deathmatch bench: arena $arena, rules byte $rules, $frames frames"
  "$repo/badge-bench/bench.sh" "$elf" --no-config --frames "$frames" --every 100000 \
    --poke "stein_dm_bench=$((rules + 1))" | grep -E "worst|busy ms|verdict"
done
