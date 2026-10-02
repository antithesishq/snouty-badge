#!/bin/bash
# Create or update the station's NetworkManager profiles from station.toml:
#   snouty-hotspot-N  one wifi client profile per [[hotspots]] entry, priority 100
#   snouty-badge      the station's own access point, 10.42.0.1, not autoconnected
# Usage: nm-profiles.sh [station.toml]   (run as root; safe to re-run)
set -euo pipefail

CONFIG=${1:-${BADGE_STATION_CONFIG:-/etc/badge-station/station.toml}}
IFACE=${WIFI_IF:-wlan0}
AP=snouty-badge

if ! command -v nmcli >/dev/null; then
    echo "nm-profiles: nmcli not found, install network-manager" >&2
    exit 1
fi
if [ ! -r "$CONFIG" ]; then
    echo "nm-profiles: cannot read $CONFIG" >&2
    exit 1
fi

# Records separated by NUL: "ap" ssid password, then "hotspot" ssid password ...
read_config() {
    python3 - "$CONFIG" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    c = tomllib.load(f)
hs = c.get("hotspots", [])
if not isinstance(hs, list) or any(not isinstance(h, dict) for h in hs):
    raise ValueError("hotspots must be an array of tables")
last = hs[-1] if hs else {}
# Tolerate ap_* keys written after a [[hotspots]] header (they land in that table).
ssid = c.get("ap_ssid", last.get("ap_ssid", "snouty-badge"))
pw = c.get("ap_password", last.get("ap_password", "snoutysnouty"))
if not isinstance(ssid, str) or not ssid or not isinstance(pw, str) or len(pw) < 8:
    raise ValueError("access point needs a nonempty SSID and an 8-character password")
if "\0" in ssid or "\0" in pw:
    raise ValueError("access point credentials cannot contain NUL")
out = ["ap", str(ssid), str(pw)]
for h in hs:
    name, password = h.get("ssid"), h.get("password", "")
    if not isinstance(name, str) or not name or not isinstance(password, str):
        raise ValueError("each hotspot needs an SSID and a string password")
    if "\0" in name or "\0" in password:
        raise ValueError("hotspot credentials cannot contain NUL")
    out += ["hotspot", name, password]
sys.stdout.write("\0".join(out) + "\0")
PY
}

exists() { nmcli -g connection.id connection show "$1" >/dev/null 2>&1; }

upsert() {   # upsert NAME SETTINGS...
    local name=$1; shift
    if exists "$name"; then
        nmcli connection modify "$name" "$@"
        echo "updated $name"
    else
        nmcli connection add type wifi ifname "$IFACE" con-name "$name" "$@"
        echo "created $name"
    fi
}

parsed=$(mktemp)
trap 'rm -f "$parsed"' EXIT
if ! read_config > "$parsed"; then
    echo "nm-profiles: invalid $CONFIG; no profiles changed" >&2
    exit 1
fi
records=()
while IFS= read -r -d '' field; do records+=("$field"); done < "$parsed"

n=0
i=0
while [ $i -lt ${#records[@]} ]; do
    kind=${records[$i]} ssid=${records[$((i + 1))]} pw=${records[$((i + 2))]}
    i=$((i + 3))
    if [ "$kind" = ap ]; then
        if [ ${#pw} -lt 8 ]; then
            echo "nm-profiles: ap_password must be at least 8 characters" >&2
            exit 1
        fi
        upsert "$AP" \
            connection.interface-name "$IFACE" \
            802-11-wireless.ssid "$ssid" \
            802-11-wireless.mode ap \
            802-11-wireless.band bg \
            ipv4.method shared \
            ipv4.addresses 10.42.0.1/24 \
            ipv6.method disabled \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.proto rsn \
            wifi-sec.pairwise ccmp \
            wifi-sec.group ccmp \
            wifi-sec.psk "$pw" \
            connection.autoconnect no
        continue
    fi
    n=$((n + 1))
    if [ -n "$pw" ]; then
        upsert "snouty-hotspot-$n" \
            connection.interface-name "$IFACE" \
            802-11-wireless.ssid "$ssid" \
            802-11-wireless.mode infrastructure \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$pw" \
            connection.autoconnect yes \
            connection.autoconnect-priority 100
    else
        exists "snouty-hotspot-$n" && nmcli connection delete "snouty-hotspot-$n" >/dev/null
        upsert "snouty-hotspot-$n" \
            connection.interface-name "$IFACE" \
            802-11-wireless.ssid "$ssid" \
            802-11-wireless.mode infrastructure \
            connection.autoconnect yes \
            connection.autoconnect-priority 100
    fi
done

# Drop profiles for hotspots removed from station.toml.
nmcli -g NAME connection show | while IFS= read -r name; do
    case $name in
        snouty-hotspot-*)
            k=${name#snouty-hotspot-}
            if [[ $k =~ ^[0-9]+$ ]] && [ "$k" -gt "$n" ]; then
                nmcli connection delete "$name" >/dev/null && echo "deleted $name"
            fi
            ;;
    esac
done
echo "nm-profiles: $n hotspot profile(s), access point $AP"
