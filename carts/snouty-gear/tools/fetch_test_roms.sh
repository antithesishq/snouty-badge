#!/usr/bin/env sh
# Fetches the test ROMs into tests/roms/ (gitignored; SPEC.md section 11).
#
#   tools/fetch_test_roms.sh                 ZEXDOC/ZEXALL (Maxim's SMS port, v0.21, GPL-2.0)
#   tools/fetch_test_roms.sh --single-step   also SingleStepTests Z80 v1/ (MIT, ~1.2 GB unpacked)
#
# The SingleStepTests clone is sparse (only v1/) and blobless, but the JSON
# files are still about 1.2 GB, so it is opt-in.
set -eu
single_step=0
for a in "$@"; do
  case "$a" in
    --single-step) single_step=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
mkdir -p tests/roms
cd tests/roms

if [ ! -f zexdoc.sms ] || [ ! -f zexall.sms ]; then
  echo "fetch ZEXALL-SMS-0.21.zip"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/zex.zip" https://github.com/maxim-zhao/zexall-sms/releases/download/v0.21/ZEXALL-SMS-0.21.zip
  unzip -o -q -j "$tmp/zex.zip" zexdoc.sms zexall.sms LICENSE -d .
  mv -f LICENSE LICENSE-zexall
fi

if [ "$single_step" = 1 ]; then
  if [ ! -d z80/.git ]; then
    echo "clone SingleStepTests/z80 (sparse, v1/ only)"
    git clone --filter=blob:none --sparse --depth 1 https://github.com/SingleStepTests/z80.git z80
    git -C z80 sparse-checkout set v1
  else
    echo "z80/ already cloned (git -C tests/roms/z80 pull to update)"
  fi
fi
ls -l
