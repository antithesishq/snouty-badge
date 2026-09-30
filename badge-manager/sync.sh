#!/bin/bash
# Pull built carts into the station library, then register new ones.
#
#   sync.sh [HOST [REPO]]
#
# HOST "local" reads REPO on this machine (tests, a checkout on the Pi).
# HOST and REPO default to build_host and build_repo in station.toml
# ($BADGE_STATION_CONFIG, else /etc/badge-station/station.toml). Copies
# REPO/zig-out/firmware/*.uf2 into LIBRARY/carts/ with rsync over ssh, gates
# each copied file with tools/uf2_info.py, and runs
# `python3 -m badge_manager add-uf2 FILE --key STEM` for every UF2 that has
# no manifest entry yet.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${BADGE_STATION_CONFIG:-/etc/badge-station/station.toml}

conf() {   # conf KEY DEFAULT
    python3 - "$CONFIG" "$1" "$2" <<'PY'
import sys, tomllib
path, key, default = sys.argv[1:]
try:
    with open(path, "rb") as f:
        c = tomllib.load(f)
except OSError:
    c = {}
print(c.get(key, default))
PY
}

HOST=${1:-$(conf build_host "")}
REPO=${2:-$(conf build_repo /home/exedev/snouty-badge)}
LIBRARY=${BADGE_STATION_LIBRARY:-$(conf library /var/lib/badge-station/library)}
if [ -z "$HOST" ]; then
    echo "sync: no build host (give HOST or set build_host in $CONFIG)" >&2
    exit 2
fi
mkdir -p "$LIBRARY/carts"

if [ "$HOST" = local ]; then
    shopt -s nullglob
    src=("$REPO"/zig-out/firmware/*.uf2)
    shopt -u nullglob
    [ ${#src[@]} -gt 0 ] || { echo "sync: no UF2 files in $REPO/zig-out/firmware" >&2; exit 1; }
    echo "sync: $REPO/zig-out/firmware/*.uf2 -> $LIBRARY/carts/"
    changes=$(rsync -rt --itemize-changes --out-format='%i %n' "${src[@]}" "$LIBRARY/carts/")
else
    echo "sync: $HOST:$REPO/zig-out/firmware/*.uf2 -> $LIBRARY/carts/"
    changes=$(rsync -rt --itemize-changes --out-format='%i %n' \
        -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
        "$HOST:$REPO/zig-out/firmware/*.uf2" "$LIBRARY/carts/")
fi
changed=$(printf '%s\n' "$changes" | awk '$1 ~ /^>f/ { print $2 }')
if [ -z "$changed" ]; then
    echo "sync: no cart changed"
else
    printf '%s\n' "$changed" | sed 's/^/sync: updated /'
fi

uf2_info=""
for t in "$here/../tools/uf2_info.py" "$here/tools/uf2_info.py"; do
    [ -f "$t" ] && uf2_info=$t && break
done
if [ -n "$uf2_info" ] && [ -n "$changed" ]; then
    while IFS= read -r f; do
        if ! python3 "$uf2_info" "$LIBRARY/carts/$f" >/dev/null; then
            echo "sync: $f failed the UF2 check:" >&2
            python3 "$uf2_info" "$LIBRARY/carts/$f" >&2 || true
        fi
    done <<< "$changed"
fi

# Keys already in the manifest.
known=$(python3 - "$LIBRARY/manifest.toml" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as f:
        m = tomllib.load(f)
except OSError:
    m = {}
for k in m.get("carts", {}):
    print(k)
PY
)

cli_ok=0
if (cd "$here" && python3 -m badge_manager add-uf2 --help) >/dev/null 2>&1; then
    cli_ok=1
fi

added=0
shopt -s nullglob
for f in "$LIBRARY"/carts/*.uf2; do
    stem=$(basename "$f" .uf2)
    family=${stem%-xip}          # snouty-xip.uf2 is the XIP variant of snouty
    if printf '%s\n' "$known" | grep -qxF -e "$stem" -e "$family"; then
        continue
    fi
    if [ $cli_ok -eq 1 ]; then
        if (cd "$here" && python3 -m badge_manager add-uf2 "$f" --key "$stem"); then
            echo "sync: added $family to the manifest"
            known=$(printf '%s\n%s' "$known" "$family")
            added=$((added + 1))
        else
            echo "sync: could not add $stem" >&2
        fi
    else
        echo "sync: badge CLI has no add-uf2 yet; run: python3 -m badge_manager add-uf2 $f --key $stem"
    fi
done
echo "sync: done, $(printf '%s' "$changed" | grep -c . || true) file(s) copied, $added cart(s) added"
