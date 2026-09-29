#!/usr/bin/env sh
# Fetches the freely redistributable test ROMs into tests/roms/ (gitignored).
# Blargg's tests via retrio/gb-test-roms, dmg-acid2 and cgb-acid2 from
# mattcurrie's releases, a few Mooneye Test Suite ROMs (MIT) from gekkio's
# prebuilt archive (MBC banking), saved as mooneye-<name>.gb.
set -eu
cd "$(dirname "$0")/../tests/roms"
get() { [ -f "$2" ] || { echo "fetch $2"; curl -fsSL -o "$2" "$1"; }; }
B=https://github.com/retrio/gb-test-roms/raw/master
get "$B/cpu_instrs/cpu_instrs.gb" cpu_instrs.gb
i=1; for n in "01-special" "02-interrupts" "03-op sp,hl" "04-op r,imm" "05-op rp" "06-ld r,r" "07-jr,jp,call,ret,rst" "08-misc instrs" "09-op r,r" "10-bit ops" "11-op a,(hl)"; do
  enc=$(printf '%s' "$n" | sed 's/ /%20/g; s/,/%2C/g; s/(/%28/g; s/)/%29/g')
  get "$B/cpu_instrs/individual/$enc.gb" "cpu_instrs_$(printf '%02d' $i).gb"; i=$((i+1))
done
get "$B/instr_timing/instr_timing.gb" instr_timing.gb
get "$B/mem_timing/mem_timing.gb" mem_timing.gb
get https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb dmg-acid2.gb
get https://raw.githubusercontent.com/mattcurrie/dmg-acid2/master/img/reference-dmg.png dmg-acid2-reference.png
get https://github.com/mattcurrie/cgb-acid2/releases/download/v1.1/cgb-acid2.gbc cgb-acid2.gbc
get https://raw.githubusercontent.com/mattcurrie/cgb-acid2/master/img/reference.png cgb-acid2-reference.png
MTS=mts-20260714-0944-31510e1
# The suite's misc/*-C CGB tests are DMG-flagged (CGB compatibility mode,
# not emulated), so only MBC tests are used.
MOONEYE="emulator-only/mbc1/ram_64kb emulator-only/mbc1/ram_256kb emulator-only/mbc5/rom_512kb emulator-only/mbc5/rom_1Mb emulator-only/mbc5/rom_2Mb"
need=
for t in $MOONEYE; do [ -f "mooneye-$(basename "$t").gb" ] || need=1; done
if [ -n "$need" ]; then
  echo "fetch $MTS.tar.gz"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/mts.tar.gz" "https://gekkio.fi/files/mooneye-test-suite/$MTS/$MTS.tar.gz"
  tar -xzf "$tmp/mts.tar.gz" -C "$tmp"
  for t in $MOONEYE; do cp "$tmp/$MTS/$t.gb" "mooneye-$(basename "$t").gb"; done
  rm -rf "$tmp"
fi
ls -l
