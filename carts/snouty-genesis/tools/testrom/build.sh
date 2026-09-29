#!/usr/bin/env sh
# Rebuilds carts/snouty-genesis/roms/snouty-test.bin from this directory's
# sources, byte for byte (README.md, "Building").
#
#   tools/testrom/build.sh          build and install into roms/
#   tools/testrom/build.sh --check  build and compare with the committed ROM
#
# Intermediates go to a temporary directory that is removed afterwards.
set -eu
check=0
case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
rom="$here/../../roms/snouty-test.bin"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
make -s -C "$here" BUILD="$work" "$work/snouty-test.bin"
if [ "$check" = 1 ]; then
  if cmp -s "$work/snouty-test.bin" "$rom"; then
    echo "build.sh: identical to roms/snouty-test.bin"
  else
    echo "build.sh: DIFFERS from roms/snouty-test.bin" >&2
    exit 1
  fi
else
  cp "$work/snouty-test.bin" "$rom"
  echo "build.sh: wrote roms/snouty-test.bin"
fi
sha256sum "$work/snouty-test.bin" | cut -d' ' -f1
