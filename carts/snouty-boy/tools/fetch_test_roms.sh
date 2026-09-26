#!/usr/bin/env sh
# Fetches the freely redistributable test ROMs into tests/roms/ (gitignored).
# Blargg's tests via retrio/gb-test-roms, dmg-acid2 from mattcurrie's release.
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
ls -l
