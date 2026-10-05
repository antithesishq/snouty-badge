#!/bin/sh
# Build the ComLynx test carts (tests/comlynx/*.s) with cc65's Lynx target
# (cc65 2.19 on the VM: apt install cc65). The .lnx files are committed
# (root .gitignore exception), so the host tests need no cc65.
#   sh carts/snouty-lynx/tools/make_comlynx_roms.sh   (from the repository root)
set -eu
cd "$(dirname "$0")/../tests/comlynx"
for s in *.s; do
  b=${s%.s}
  cl65 -t lynx -o "$b.lnx" "$s" lynx.lib
  rm -f "$b.o"
  echo "built tests/comlynx/$b.lnx ($(wc -c < "$b.lnx") B)"
done
