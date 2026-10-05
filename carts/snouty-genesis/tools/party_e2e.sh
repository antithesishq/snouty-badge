#!/usr/bin/env bash
# The Genesis party end to end over the real relay, no hardware
# (docs/MULTIPLAYER.md section 6; after the root tools/party_e2e.sh):
# builds the host harness, starts the fork's `badge lobby` on this run's
# ports only and plays Mega Bomberman on N badges in one process to the
# 4-human battle and past it, one badge leaving and one rejoining. Every
# badge must log the same console at every tick.
#
#   carts/snouty-genesis/tools/party_e2e.sh            # 4 badges
#   carts/snouty-genesis/tools/party_e2e.sh 6          # 6 badges
#
# GENESIS_E2E_ROM  Mega Bomberman (default tests/roms/genesis/MegaBomberman.md,
#                  else ~/roms/genesis/MegaBomberman.md; never committed)
# SYCL_BADGE_FORK  the fork checkout with tools/badge (default
#                  /home/exedev/sycl-badge-fork; only read, run with -B)
# GENESIS_E2E_PORT first TCP port (default 27400: this cart's range is
#                  27400-27449, clear of Snoutenstein's 27341+ and the
#                  simulators' 7341-7356)
# GENESIS_E2E_SPEED updates per 33.3 ms (default 4: the battle at tick 3900
#                  comes after about 16 s)
set -euo pipefail
cd "$(dirname "$0")/../../.."

FORK=${SYCL_BADGE_FORK:-/home/exedev/sycl-badge-fork}
BASE=${GENESIS_E2E_PORT:-27400}
SPEED=${GENESIS_E2E_SPEED:-4}
ROM=${GENESIS_E2E_ROM:-carts/snouty-genesis/tests/roms/genesis/MegaBomberman.md}
[ -f "$ROM" ] || ROM="$HOME/roms/genesis/MegaBomberman.md"
[ -f "$ROM" ] || { echo "party_e2e.sh: no Mega Bomberman ROM (set GENESIS_E2E_ROM)"; exit 2; }
BADGE_PY="$FORK/tools/badge/badge.py"
[ -f "$BADGE_PY" ] || { echo "party_e2e.sh: no $BADGE_PY (set SYCL_BADGE_FORK)"; exit 2; }
python3 -c 'import serial' 2>/dev/null || { echo "party_e2e.sh: the relay needs pyserial: python3 -m pip install --user pyserial"; exit 2; }

N=${1:-4}
LAST=$((BASE + N - 1))
[ "$LAST" -le 27449 ] || { echo "party_e2e.sh: ports past 27449"; exit 2; }

zig build party-e2e-genesis -Dcart=snouty-genesis
BIN=zig-out/bin/party_e2e_genesis
LOG=$(mktemp -t genesis-lobby.XXXXXX)

python3 -B "$BADGE_PY" lobby --no-usb --sim "$BASE-$LAST" --stats 0 >"$LOG" 2>&1 &
LOBBY_PID=$!
trap 'kill $LOBBY_PID 2>/dev/null || true; wait $LOBBY_PID 2>/dev/null || true' EXIT

echo "== party_e2e (genesis): $N badges, 127.0.0.1:$BASE-$LAST, lobby log $LOG"
"$BIN" --badges "$N" --base-port "$BASE" --speed "$SPEED" --rom "$ROM"
grep -E "rejoin|not reading" "$LOG" | sed 's/^/   relay: /' || true
