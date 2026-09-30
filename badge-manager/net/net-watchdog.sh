#!/bin/bash
# Keep the station reachable: a phone hotspot when one is in range, the
# station's own access point (snouty-badge, 10.42.0.1) otherwise. One radio,
# so it is one or the other. Run by badge-net-watchdog.timer every 5 minutes.
#  - A wifi client connection is active: nothing to do.
#  - None, 45 s after boot: bring the access point up.
#  - The access point is up with nobody attached: try each hotspot profile
#    once (10 s each); if none connects, raise the access point again.
#    With somebody attached, never touch it.
set -uo pipefail

IFACE=${WIFI_IF:-wlan0}
AP=snouty-badge
BOOT_GRACE=45

say() { echo "net-watchdog: $*"; }

active_wifi() {   # names of active wifi connections, one per line
    nmcli -t -f NAME,TYPE connection show --active 2>/dev/null |
        awk -F: '$2 == "802-11-wireless" { print $1 }'
}
ap_up() { active_wifi | grep -qx "$AP"; }
client_up() { active_wifi | grep -vqx "$AP"; }
hotspot_profiles() {
    nmcli -g NAME connection show 2>/dev/null | grep '^snouty-hotspot-' | sort -t- -k3 -n
}
stations() { iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station' || true; }
raise_ap() {
    if nmcli --wait 30 connection up "$AP" >/dev/null 2>&1; then
        say "access point $AP is up (http://10.42.0.1)"
    else
        say "could not bring $AP up"
        return 1
    fi
}

command -v nmcli >/dev/null || { say "nmcli not found"; exit 1; }

if client_up; then
    say "wifi client connected: $(active_wifi | grep -vx "$AP" | head -1)"
    exit 0
fi

if ! ap_up; then
    up=$(cut -d. -f1 /proc/uptime)
    if [ "$up" -lt $BOOT_GRACE ]; then
        sleep $((BOOT_GRACE - up))
        if client_up; then
            say "wifi client connected during boot grace"
            exit 0
        fi
    fi
    say "no hotspot connected ${BOOT_GRACE}s after boot, starting the access point"
    raise_ap
    exit $?
fi

n=$(stations)
if [ "$n" -gt 0 ]; then
    say "access point up with $n station(s) attached, leaving it"
    exit 0
fi

say "access point up with nobody attached, retrying the hotspots"
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if nmcli --wait 10 connection up "$p" >/dev/null 2>&1; then
        say "joined $p"
        exit 0
    fi
    say "$p not in reach"
done < <(hotspot_profiles)
raise_ap
