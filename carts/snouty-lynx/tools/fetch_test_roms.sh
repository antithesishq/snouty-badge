#!/usr/bin/env sh
# Fetches the CPU test data into tests/roms/ (gitignored; SPEC.md section 16).
#
#   tools/fetch_test_roms.sh          a representative subset of SingleStepTests
#                                     65x02 rockwell65c02/v1 (MIT, 24 files of
#                                     10,000 cases, ~85 MB) into tests/roms/65c02/,
#                                     which `zig build test` parses (M0) and runs
#                                     on core/cpu65.zig (M1)
#                                     plus drhelius's lynx-tests 1.4.9 (MIT, 19 small
#                                     .lnx hardware tests: cpu, page-mode, math, timers,
#                                     sprites1-5, ...) into tests/roms/lynx-tests/
#   tools/fetch_test_roms.sh --all    the WHOLE variant (256 files, ~0.9 GB): streams
#                                     batches of $BATCH (default 32) files into
#                                     tests/roms/65c02/batch/, checks each batch
#                                     (with $LYNX_SST_CMD <dir> if set, e.g. the M1
#                                     test binary; else a JSON parse and case count),
#                                     deletes it, and writes one PASS/FAIL line per
#                                     file to tests/roms/65c02/results.txt
#
# Why rockwell65c02 (SPEC.md section 16): the Lynx CPU is a 65C02 core with the
# Rockwell bit instructions (RMB/SMB/BBR/BBS) and without WAI/STP ($CB/$DB are
# 1-byte NOPs); that is exactly the Rockwell R65C02 set. The suite has no index
# file and the VM has no GitHub API, so --all walks the 256 opcode names and
# skips any that 404. Never `git clone` the suite (disk).
set -eu
all=0
for a in "$@"; do
  case "$a" in
    --all) all=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

cart=$(cd "$(dirname "$0")/.." && pwd)

# drhelius/lynx-tests (MIT): hardware test carts for M1 (SPEC.md section 16).
mkdir -p "$cart/tests/roms/lynx-tests"
if [ ! -f "$cart/tests/roms/lynx-tests/cpu.lnx" ]; then
  echo "fetch lynx-tests-1.4.9.zip"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/t.zip" https://github.com/drhelius/lynx-tests/releases/download/1.4.9/lynx-tests-1.4.9.zip
  unzip -o -q -j "$tmp/t.zip" '*.lnx' -d "$cart/tests/roms/lynx-tests"
  curl -fsSL -o "$cart/tests/roms/lynx-tests/LICENSE" https://raw.githubusercontent.com/drhelius/lynx-tests/main/LICENSE || true
  rm -rf "$tmp"
fi
raw=https://raw.githubusercontent.com/SingleStepTests/65x02/main/rockwell65c02/v1
mkdir -p "$cart/tests/roms/65c02"
cd "$cart/tests/roms/65c02"

# fetch_one <opcode hex> <dir>; returns 1 on 404.
fetch_one() {
  curl -fsSL --retry 3 -o "$2/$1.json" "$raw/$1.json" || { rm -f "$2/$1.json"; return 1; }
}

# check_dir <dir>: one "PASS name cases" / "FAIL name why" line per file.
check_dir() {
  if [ -n "${LYNX_SST_CMD:-}" ]; then
    $LYNX_SST_CMD "$1"
  else
    python3 - "$1" <<'PY'
import json, os, sys
d = sys.argv[1]
for n in sorted(os.listdir(d)):
    if not n.endswith('.json'):
        continue
    try:
        t = json.load(open(os.path.join(d, n)))
        ok = all({'initial', 'final', 'cycles'} <= set(c) for c in t)
        print(('PASS' if ok and t else 'FAIL'), n, len(t))
    except Exception as e:
        print('FAIL', n, e)
PY
  fi
}

if [ "$all" = 0 ]; then
  # Per group: BRK/JSR/RTI, JMP (abs) and (abs,x), ADC/SBC (decimal mode is in
  # the random P), (zp) and (zp),y, STZ/TRB/TSB, BRA, PHX/PLY, BIT #/abs,x,
  # INC A, RMW abs,x, RMB/SMB, BBR/BBS, and the undefined-opcode NOPs
  # ($CB is WAI on WDC parts, $5C the 3-byte NOP).
  for f in 00 20 40 6c 7c 69 f1 b2 9c 14 0c 80 da 7a 89 3c 1a 7e 07 97 0f ff cb 5c; do
    [ -f "$f.json" ] || { echo "fetch rockwell65c02/v1/$f.json"; fetch_one "$f" .; }
  done
  check_dir . | tee check.txt | grep -v '^PASS' || true
  echo "tests/roms/65c02: $(ls ./*.json | wc -l) files, $(grep -c '^PASS' check.txt) parse, $(du -sh . | cut -f1)"
  exit 0
fi

batch=${BATCH:-32}
: > results.txt
i=0
while [ "$i" -lt 256 ]; do
  rm -rf batch
  mkdir -p batch
  j=0
  while [ "$j" -lt "$batch" ] && [ "$i" -lt 256 ]; do
    op=$(printf '%02x' "$i")
    fetch_one "$op" batch || echo "MISSING $op.json" >> results.txt
    i=$((i + 1))
    j=$((j + 1))
  done
  echo "batch to $(printf '%02x' $((i - 1))): $(ls batch | wc -l) files, $(du -sh batch | cut -f1)"
  check_dir batch | tee -a results.txt | grep -v '^PASS' || true
  rm -rf batch
done
echo "summary: $(grep -c '^PASS' results.txt) pass, $(grep -c '^FAIL' results.txt) fail, $(grep -c '^MISSING' results.txt) missing" | tee -a results.txt
