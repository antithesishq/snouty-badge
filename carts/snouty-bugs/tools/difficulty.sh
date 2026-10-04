#!/usr/bin/env bash
# Difficulty probe (PLAN.md M7): build the cart, then let each bot (1 turret,
# 2 sweep, 3 dodger) play a fresh game headlessly in endless probe mode
# through the four stages and loop 2's stage 1, and print one table per bot
# and stage (hits, seconds, boss seconds, boss killed or escaped, rank,
# weapon and forks).
#
#   tools/difficulty.sh [--no-build] [--bots 1,2,3] [--stages N] [--bosses 0,1,2,3] [--json OUT.json]
#                       [--frames CAP] [--seed N]
#
# Everything but --no-build goes to tools/difficulty.mjs (see its header).
# Per-bot traces land in out/difficulty/botN/ (frames.json, preview.log).
# CART_WASM overrides the cart (default ../../zig-out/bin/snouty-bugs.wasm).
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."   # this cart's directory
repo="../.."

build=1
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) build=0 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) args+=("$1") ;;
    esac
    shift
done

wasm="${CART_WASM:-$repo/zig-out/bin/snouty-bugs.wasm}"
if [ "$build" = 1 ]; then (cd "$repo" && zig build -Dcart=snouty-bugs); fi
[ -f "$wasm" ] || { echo "difficulty: $wasm not found" >&2; exit 1; }
exec node tools/difficulty.mjs --wasm "$wasm" ${args[@]+"${args[@]}"}
