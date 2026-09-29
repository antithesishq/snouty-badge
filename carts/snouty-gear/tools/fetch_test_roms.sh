#!/usr/bin/env sh
# Fetches the test ROMs into tests/roms/ (gitignored; SPEC.md section 11).
#
#   tools/fetch_test_roms.sh                   ZEXDOC/ZEXALL (Maxim's SMS port, v0.21, GPL-2.0)
#   tools/fetch_test_roms.sh --single-step     also a representative subset of the
#                                              SingleStepTests Z80 v1/ files (MIT, ~40
#                                              files, ~28 MB) in tests/roms/z80/v1/, which
#                                              `zig build test` runs
#   tools/fetch_test_roms.sh --single-step-all run the WHOLE SingleStepTests suite (1604
#                                              files, ~1.2 GB): streams batches of $BATCH
#                                              (default 100) files into tests/roms/z80/batch/,
#                                              runs tests/z80_single_step.zig on each batch
#                                              (GEAR_SST_DIR), deletes it, and writes one
#                                              PASS/FAIL line per file to
#                                              tests/roms/z80/results.txt
#
# The full suite does not fit on the VM's disk at once, hence the batches; a
# plain `git clone` is never used for the JSON. The file list comes from a
# tree-only (blobless, no checkout) clone. Run from anywhere; the
# --single-step-all mode needs zig on PATH and the repository checkout.
set -eu
single_step=0
single_step_all=0
for a in "$@"; do
  case "$a" in
    --single-step) single_step=1 ;;
    --single-step-all) single_step_all=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

cart=$(cd "$(dirname "$0")/.." && pwd)
raw=https://raw.githubusercontent.com/SingleStepTests/z80/main/v1
mkdir -p "$cart/tests/roms"
cd "$cart/tests/roms"

if [ ! -f zexdoc.sms ] || [ ! -f zexall.sms ]; then
  echo "fetch ZEXALL-SMS-0.21.zip"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/zex.zip" https://github.com/maxim-zhao/zexall-sms/releases/download/v0.21/ZEXALL-SMS-0.21.zip
  unzip -o -q -j "$tmp/zex.zip" zexdoc.sms zexall.sms LICENSE -d .
  mv -f LICENSE LICENSE-zexall
  rm -rf "$tmp"
fi

# fetch_one <name> <dir>: one v1 JSON file (names contain spaces).
fetch_one() {
  url="$raw/$(printf '%s' "$1" | sed 's/ /%20/g')"
  curl -fsSL --retry 3 -o "$2/$1" "$url"
}

if [ "$single_step" = 1 ]; then
  # One or more files per instruction group and prefix: loads, ALU, 16-bit
  # arithmetic, DAA/SCF/CCF, jumps/calls, I/O, the ED block and I/O
  # instructions, CB/DDCB/FDCB and IX/IY forms incl. undocumented ones.
  mkdir -p z80/v1
  for f in "00" "09" "10" "27" "37" "3f" "76" "7e" "8e" "9e" "be" "c9" "cd" "d3" "db" "e3" \
           "ed 42" "ed 4a" "ed 57" "ed 67" "ed 6f" "ed a1" "ed a2" "ed a3" "ed b0" "ed b1" "ed b2" "ed bb" \
           "cb 06" "cb 36" "cb 46" "cb 7e" "dd 00" "dd 34" "dd 7e" "dd 8c" "dd e3" \
           "dd cb __ 06" "dd cb __ 46" "fd cb __ c0"; do
    [ -f "z80/v1/$f.json" ] || { echo "fetch v1/$f.json"; fetch_one "$f.json" z80/v1; }
  done
  echo "tests/roms/z80/v1: $(ls z80/v1 | wc -l) files, $(du -sh z80/v1 | cut -f1)"
fi

if [ "$single_step_all" = 1 ]; then
  batch=${BATCH:-100}
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  echo "list SingleStepTests/z80 v1/ (tree-only clone)"
  git clone -q --filter=blob:none --no-checkout --depth 1 https://github.com/SingleStepTests/z80.git "$work/repo"
  git -C "$work/repo" ls-tree --name-only HEAD v1/ | sed 's|^v1/||' | grep '\.json$' > "$work/list"
  rm -rf "$work/repo"
  total=$(wc -l < "$work/list")
  echo "$total files; building the test binary (-O safe)"
  root=$(cd "$cart/../.." && pwd)
  (cd "$cart" && zig test -O safe --dep core -Mroot=tests/z80_single_step.zig -Mcore=core/gg.zig \
    --test-no-exec -femit-bin="$work/sst_test")
  mkdir -p z80
  : > z80/results.txt
  split -l "$batch" "$work/list" "$work/part."
  for part in "$work"/part.*; do
    rm -rf z80/batch
    mkdir -p z80/batch
    while IFS= read -r f; do fetch_one "$f" z80/batch; done < "$part"
    echo "batch $(basename "$part"): $(ls z80/batch | wc -l) files, $(du -sh z80/batch | cut -f1)"
    (cd "$root" && GEAR_SST_DIR="$cart/tests/roms/z80/batch" "$work/sst_test" 2>&1) \
      | tee -a z80/results.txt | grep -E '^(FAIL|z80:)' || true
    rm -rf z80/batch
  done
  echo "summary: $(grep -c '^PASS' z80/results.txt) files pass, $(grep -c '^FAIL' z80/results.txt) fail" | tee -a z80/results.txt
fi
ls -l
