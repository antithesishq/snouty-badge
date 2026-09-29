#!/usr/bin/env sh
# Fetches the 68000 SingleStepTests into tests/roms/68000/ (gitignored;
# SPEC.md section 11, docs/ROMS.md section 3).
#
#   tools/fetch_test_roms.sh        a representative subset: one or two files per
#                                   instruction family (36 files, ~50 MB gzipped)
#   tools/fetch_test_roms.sh --all  every file of 68000/v1 (124 files, ~200 MB
#                                   gzipped; the file list comes from a tree-only
#                                   clone, the blobs are streamed one by one)
#   tools/fetch_test_roms.sh --dry-run [--all]
#                                   print the file list and total size only
#
# Source: https://github.com/SingleStepTests/680x0 (68000/v1, Tom Harte's
# tests, formerly TomHarte/ProcessorTests). The repository has NO licence
# file, so the JSON is fetched for local testing only and never committed.
# Files stay gzipped (<name>.json.gz, about 1/6 of the JSON size); the M1
# harness decompresses them. The total size (from HTTP Content-Length) is
# printed before anything is downloaded; files already present are skipped.
# A plain `git clone` of the repository is never used.
set -eu
all=0
dry=0
for a in "$@"; do
  case "$a" in
    --all) all=1 ;;
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

cart=$(cd "$(dirname "$0")/.." && pwd)
repo=https://github.com/SingleStepTests/680x0.git
raw=https://raw.githubusercontent.com/SingleStepTests/680x0/main/68000/v1
dest="$cart/tests/roms/68000"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$all" = 1 ]; then
  echo "list SingleStepTests/680x0 68000/v1 (tree-only clone)"
  git clone -q --filter=blob:none --no-checkout --depth 1 "$repo" "$work/repo"
  git -C "$work/repo" ls-tree --name-only HEAD 68000/v1/ | sed 's|^68000/v1/||' \
    | grep '\.json\.gz$' > "$work/list"
  rm -rf "$work/repo"
else
  # One file per family; .b/.w/.l variants only where the size changes the
  # microcode path (MOVE, ADD/SUB, shifts). Covers BCD, the SR/CCR forms,
  # the exception-raising ones (CHK, DIVx, TRAP, TRAPV) and the bus-sensitive
  # ones (MOVEM, MOVEP, TAS, RTE).
  for f in ABCD ADD.b ADD.l ADDA.w ADDX.l AND.w ANDItoSR ASL.l ASR.w BCHG \
           BTST Bcc BSR CHK CLR.b CMP.w DBcc DIVS DIVU EORItoCCR EXG EXT.l \
           JSR LEA LINK LSR.b MOVE.b MOVE.l MOVE.w MOVE.q MOVEA.l MOVEM.l \
           MOVEP.w MOVEtoSR MULS ROXL.w; do
    echo "$f.json.gz"
  done > "$work/list"
fi

count=$(wc -l < "$work/list")
echo "$count files; sizing"
total=0
while IFS= read -r f; do
  n=$(curl -fsSIL --retry 3 "$raw/$f" | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END {print v+0}')
  total=$((total + n))
done < "$work/list"
echo "total download: $total bytes ($((total / 1048576)) MB, gzipped) into $dest"
if [ "$dry" = 1 ]; then cat "$work/list"; exit 0; fi

mkdir -p "$dest"
while IFS= read -r f; do
  [ -s "$dest/$f" ] && continue
  echo "fetch 68000/v1/$f"
  curl -fsSL --retry 3 -o "$dest/$f.part" "$raw/$f"
  mv -f "$dest/$f.part" "$dest/$f"
done < "$work/list"
echo "tests/roms/68000: $(ls "$dest" | grep -c '\.json\.gz$') files, $(du -sh "$dest" | cut -f1)"
