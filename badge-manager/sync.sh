#!/bin/bash
# Stage and validate a build's UF2 artifacts before promoting them to the library.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${BADGE_STATION_CONFIG:-/etc/badge-station/station.toml}
conf() {
    python3 - "$CONFIG" "$1" "$2" <<'PY'
import sys, tomllib
path, key, default = sys.argv[1:]
try:
    with open(path, "rb") as f:
        c = tomllib.load(f)
except FileNotFoundError:
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
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
SSH_ID=""
[ -f /home/badge/.ssh/id_ed25519 ] && SSH_ID="-i /home/badge/.ssh/id_ed25519"
if [ "$HOST" = local ]; then
    shopt -s nullglob
    src=("$REPO"/zig-out/firmware/*.uf2)
    shopt -u nullglob
    [ ${#src[@]} -gt 0 ] || { echo "sync: no UF2 files in $REPO/zig-out/firmware" >&2; exit 1; }
    rsync -rt "${src[@]}" "$stage/"
else
    rsync -rt -e "ssh $SSH_ID -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new" \
        "$HOST:$REPO/zig-out/firmware/*.uf2" "$stage/"
fi
(cd "$here" && python3 - "$stage" "$LIBRARY" <<'PY'
import filecmp
import sys
from pathlib import Path
from badge_manager.library import Library, LibraryError, family_of, validate_uf2

stage, root = map(Path, sys.argv[1:])
files = sorted(stage.glob('*.uf2'))
if not files:
    raise SystemExit('sync: no UF2 files received')
try:
    for path in files:
        validate_uf2(path)
    lib = Library(root)
    entries = []
    for path in files:
        dst = root / 'carts' / path.name
        family, _ = family_of(path.stem)
        named = lib._tables('carts')
        registered = path.stem in named or family in named
        if not registered or not dst.exists() or not filecmp.cmp(path, dst, shallow=False):
            entries.append((path, path.stem, None, None, None))
    lib.import_uf2s(entries)
except (LibraryError, OSError) as e:
    raise SystemExit(f'sync: {e}') from e
for path, *_ in entries:
    print(f'sync: updated {path.name}')
print(f'sync: done, {len(entries)} file(s) promoted')
PY
)
