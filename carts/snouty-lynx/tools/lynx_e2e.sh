#!/usr/bin/env bash
# Warbirds over the real `badge lobby` relay, no hardware
# (carts/snouty-lynx/docs/COMLYNX.md section 10): builds tools/lynx_e2e.zig,
# then per run starts the fork's `badge lobby` on that run's ports only and
# plays Warbirds on N host Lynxes into a networked game. Needs Adrian's
# local dump and pyserial (the relay's).
#
#   carts/snouty-lynx/tools/lynx_e2e.sh               # the default runs
#   carts/snouty-lynx/tools/lynx_e2e.sh 4:25 2:0      # badges:D-ms (0 = relay mode)
#   carts/snouty-lynx/tools/lynx_e2e.sh 4:25:events   # with a rejoin and an unplug
#
# SYCL_BADGE_FORK  the fork checkout with tools/badge (default /home/exedev/sycl-badge-fork)
# LYNX_E2E_PORT    first TCP port (default 27500; this cart's range is 27500-27549)
# LYNX_E2E_ROM     the ROM (default ~/roms/lynx/Warbirds.lnx)
set -euo pipefail
cd "$(dirname "$0")/../../.."

FORK=${SYCL_BADGE_FORK:-/home/exedev/sycl-badge-fork}
BASE=${LYNX_E2E_PORT:-27500}
ROM=${LYNX_E2E_ROM:-$HOME/roms/lynx/Warbirds.lnx}
LOGS=${LYNX_E2E_LOGS:-$(mktemp -d)}
BADGE_PY="$FORK/tools/badge/badge.py"
[ -f "$BADGE_PY" ] || { echo "lynx_e2e.sh: no $BADGE_PY (set SYCL_BADGE_FORK)"; exit 2; }
[ -f "$ROM" ] || { echo "lynx_e2e.sh: no $ROM (set LYNX_E2E_ROM)"; exit 2; }
python3 -c 'import serial' 2>/dev/null || { echo "lynx_e2e.sh: the relay needs pyserial"; exit 2; }

zig build lynx-e2e
BIN=zig-out/bin/lynx_e2e

runs=("$@")
[ ${#runs[@]} -eq 0 ] && runs=(2:0 2:25 4:25 4:33 4:25:events)

LOBBY_PID=
stop_lobby() {
    if [ -n "$LOBBY_PID" ]; then
        kill "$LOBBY_PID" 2>/dev/null || true
        wait "$LOBBY_PID" 2>/dev/null || true
        LOBBY_PID=
    fi
}
trap stop_lobby EXIT

failed=0
port=$BASE
for run in "${runs[@]}"; do
    IFS=: read -r n d ev <<<"$run"
    last=$((port + n - 1))
    [ "$last" -le 27549 ] || [ -n "${LYNX_E2E_PORT:-}" ] || port=$BASE last=$((BASE + n - 1))
    log="$LOGS/lobby-$n-$d${ev:+-$ev}.log"
    echo "== lynx_e2e: $n badges, D $d ms${ev:+, $ev} (127.0.0.1:$port-$last; lobby log $log)"
    python3 -B "$BADGE_PY" lobby --no-usb --sim "$port-$last" --stats 0 >"$log" 2>&1 &
    LOBBY_PID=$!
    args=(--rom "$ROM" --badges "$n" --base-port "$port" --d-ms "$d")
    [ "${ev:-}" = events ] && args+=(--events)
    if "$BIN" "${args[@]}"; then :; else failed=$((failed + 1)); fi
    stop_lobby
    port=$((last + 1))
done
if [ "$failed" -ne 0 ]; then
    echo "lynx_e2e.sh: $failed run(s) FAILED (lobby logs in $LOGS)"
    exit 1
fi
echo "lynx_e2e.sh: all runs passed (lobby logs in $LOGS)"
