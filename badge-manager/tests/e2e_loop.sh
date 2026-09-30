#!/bin/bash
# End-to-end: deploy two sets of real carts onto a 1280 KB FAT12 badge image.
#
#   badge-manager/tests/e2e_loop.sh [FIRMWARE_DIR]
#
# FIRMWARE_DIR defaults to /home/exedev/snouty-badge/zig-out/firmware (read
# only). Builds an empty image with tools/make_romfs.py, a temporary library
# (demo = snouty, snouty-bugs, snoutenstein, snouty-maze; gear = snouty-gear
# + a 512 KB "Sonic The Hedgehog (World).gg"), runs
# `sudo -n python3 -m badge_manager --fake-badge IMG deploy SET --yes` for
# demo then gear, and checks each time with `make_romfs.py --list` that
# exactly the set's files are on the drive, the label is the first root
# entry, and every file's cluster chain is complete and contiguous.
#
# The image is loop-mounted when the kernel has vfat; otherwise (this VM)
# the station's own FAT12 writer is used (device.ImageBadge). Force one with
# BADGE_STATION_IMAGE=loop|builtin.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)     # badge-manager/
repo=$(cd "$here/.." && pwd)
fw=${1:-/home/exedev/snouty-badge/zig-out/firmware}
t=$(mktemp -d "${TMPDIR:-/tmp}/badge-e2e.XXXXXX")
cleanup() {
    sudo -n umount "$t/run/badge" 2>/dev/null || true
    sudo -n rm -rf "$t" 2>/dev/null || rm -rf "$t"
}
trap cleanup EXIT

lib=$t/library
mkdir -p "$lib/carts" "$lib/roms"
for c in snouty snouty-bugs snoutenstein snouty-maze snouty-gear; do
    cp "$fw/$c.uf2" "$lib/carts/"
done
dd if=/dev/urandom of="$lib/roms/Sonic The Hedgehog (World).gg" bs=1024 count=512 status=none
cat > "$lib/manifest.toml" <<'TOML'
[carts.snouty]
title = "Snouty Run"
mode = "ram"

[carts.snouty-gear]
title = "Snouty Gear"
roms = [".gg"]

[roms.sonic]
file = "roms/Sonic The Hedgehog (World).gg"
title = "Sonic GG"

[sets.demo]
title = "Demo reel"
carts = ["snouty", "snouty-bugs", "snoutenstein", "snouty-maze"]

[sets.gear]
title = "Game Gear Sonic"
carts = ["snouty-gear"]
roms = ["sonic"]
TOML
cfg=$t/station.toml
printf 'library = "%s"\nmount_root = "%s"\nlog_file = "%s"\n' "$lib" "$t/run" "$t/station.log" > "$cfg"

img=$t/badge.img
python3 "$repo/tools/make_romfs.py" "$img"
backend=$(cd "$here" && python3 -c 'from badge_manager import device; print("loop mount" if device.kernel_has_vfat() else "built-in FAT12 writer")')
echo "e2e: image backend: ${BADGE_STATION_IMAGE:-$backend}"

check() {   # check SET FILE...
    local set=$1; shift
    python3 "$repo/tools/make_romfs.py" --list "$img" | tee "$t/list.txt"
    python3 - "$t/list.txt" "$set" "$@" <<'PY'
import re, sys
listing, set_name, want = sys.argv[1], sys.argv[2], sys.argv[3:]
rows = [l for l in open(listing) if re.match(r"\s+\[\s*\d+\]", l)]
live = [l for l in rows if "] deleted" not in l]
problems = []
if not live or " label " not in live[0] or not re.match(r"\s+\[\s*0\]", live[0]):
    problems.append("the volume label is not the first root entry")
files = []
for l in live:
    m = re.search(r"\] (file|dir) '([^']*)'(?: long '([^']*)')?", l)
    if not m:
        continue
    name = m.group(3) or m.group(2)
    files.append(name)
    if "(ok)" not in l:
        problems.append(f"{name}: cluster chain length is wrong")
    if "contiguous" not in l:
        problems.append(f"{name}: not contiguous")
if sorted(files) != sorted(want):
    problems.append(f"files {sorted(files)}, expected {sorted(want)}")
if problems:
    print(f"e2e: {set_name}: FAIL: " + "; ".join(problems))
    sys.exit(1)
print(f"e2e: {set_name}: ok, {len(files)} files, label first, every file contiguous")
PY
}

deploy() {
    (cd "$here" && sudo -n env ${BADGE_STATION_IMAGE:+BADGE_STATION_IMAGE=$BADGE_STATION_IMAGE} \
        python3 -m badge_manager --fake-badge "$img" --config "$cfg" deploy "$1" --yes)
}

deploy demo
check demo snouty.uf2 snouty-bugs.uf2 snoutenstein.uf2 snouty-maze.uf2
deploy gear
check gear snouty-gear.uf2 SONIC.GG
(cd "$here" && python3 -m badge_manager --fake-badge "$img" --config "$cfg" status)
echo "e2e: PASS"
