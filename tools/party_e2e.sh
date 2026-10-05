#!/usr/bin/env bash
# Party lockstep end to end over the real relay, no hardware
# (docs/LOCKSTEP_N.md section 7.1): builds tools/party_e2e, then for each
# run starts the fork's `badge lobby` on that run's ports only and plays
# Snoutenstein's party deathmatch on N badges in one process, bots on every
# slot, BUGS ON, to the frag limit. Every badge must log the same World at
# every tick.
#
#   tools/party_e2e.sh              # 2, 4, 8, 16 badges, then the events run
#   tools/party_e2e.sh 4 16         # only these plain runs
#   tools/party_e2e.sh events       # only the events run (8 badges)
#
# SYCL_BADGE_FORK  the fork checkout with tools/badge (default
#                  /home/exedev/sycl-badge-fork; only read, run with -B)
# PARTY_E2E_PORT   first TCP port (default 27341, clear of the simulators'
#                  7341-7356, so running simulators are never touched)
# PARTY_E2E_LOGS   where the lobby logs go (default a temp directory)
set -euo pipefail
cd "$(dirname "$0")/.."

FORK=${SYCL_BADGE_FORK:-/home/exedev/sycl-badge-fork}
BASE=${PARTY_E2E_PORT:-27341}
LOGS=${PARTY_E2E_LOGS:-$(mktemp -d)}
BADGE_PY="$FORK/tools/badge/badge.py"
[ -f "$BADGE_PY" ] || { echo "party_e2e.sh: no $BADGE_PY (set SYCL_BADGE_FORK)"; exit 2; }
python3 -c 'import serial' 2>/dev/null || { echo "party_e2e.sh: the relay needs pyserial: python3 -m pip install --user pyserial"; exit 2; }

zig build party-e2e
BIN=zig-out/bin/party_e2e

runs=("$@")
[ ${#runs[@]} -eq 0 ] && runs=(2 4 8 16 events)

LOBBY_PID=
stop_lobby() {
    if [ -n "$LOBBY_PID" ]; then
        kill "$LOBBY_PID" 2>/dev/null || true
        wait "$LOBBY_PID" 2>/dev/null || true
        LOBBY_PID=
    fi
}
trap stop_lobby EXIT

# start_lobby LOG PORTS [extra lobby args...]
start_lobby() {
    local log=$1 ports=$2
    shift 2
    python3 -B "$BADGE_PY" lobby --no-usb --sim "$ports" --stats 0 "$@" >"$log" 2>&1 &
    LOBBY_PID=$!
}

failed=0
port=$BASE
for run in "${runs[@]}"; do
    if [ "$run" = events ]; then
        n=8
        args=(--scenario events --frags 2)
    else
        n=$run
        args=()
        # Two bots take 3 to 5 minutes of play (10,000-18,000 ticks) to
        # frag 5 times: play them at 4x, still at delay 3 (12.5 ms here).
        # bot.zig aims from the World at submit time, so a longer delay
        # makes it miss: at delay 12 two bots did not reach 5 frags in
        # 30,000 ticks.
        [ "$n" -le 2 ] && args=(--speed 4 --delay 3)
    fi
    last=$((port + n - 1))
    log="$LOGS/lobby-$run.log"
    echo "== party_e2e: $run ($n badges, 127.0.0.1:$port-$last; lobby log $log)"
    if [ "$run" = events ]; then
        # The frozen badge sits on a pty (a tty's small buffer, as a badge's
        # USB): the relay opens it by path. A small queue limit gets it
        # removed within seconds of its tty filling up.
        ptys="$LOGS/ptys-$run.txt"
        rm -f "$ptys"
        "$BIN" --badges "$n" --base-port "$port" "${args[@]}" --pty-file "$ptys" &
        e2e=$!
        for _ in $(seq 50); do [ -s "$ptys" ] && break; sleep 0.1; done
        port_args=()
        while read -r p; do port_args+=(--port "$p"); done <"$ptys"
        start_lobby "$log" "$port-$last" --queue-limit 2048 "${port_args[@]}"
        if wait "$e2e"; then :; else failed=$((failed + 1)); fi
    else
        start_lobby "$log" "$port-$last"
        if "$BIN" --badges "$n" --base-port "$port" "${args[@]}"; then :; else failed=$((failed + 1)); fi
    fi
    stop_lobby
    if [ "$run" = events ]; then
        grep -E "not reading|rejoin" "$log" | sed 's/^/   relay: /' || true
    fi
    # A fresh range per run: no TIME_WAIT or late reconnects between runs.
    port=$((last + 1))
done

if [ "$failed" -ne 0 ]; then
    echo "party_e2e.sh: $failed run(s) FAILED (lobby logs in $LOGS)"
    exit 1
fi
echo "party_e2e.sh: all runs passed (lobby logs in $LOGS)"
