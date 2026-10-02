# Snouty Genesis

A Sega Genesis (Mega Drive) emulator cart for the SYCL Badge V2, written in
Zig for Antithesis. The badge build plays a `.gen`/`.md`/`.bin` ROM copied
onto the badge's USB drive, read in place from flash (no reflash per game,
ROMs up to about 900 KB), with a small test ROM embedded as the fallback and
as the simulator's ROM. It is an XIP cart (code in the 256 KB cart flash
window) and presents at 30 Hz with two Genesis frames per update. The 68000 runs at full speed, the Z80 sound CPU from Snouty Gear drives a
one-voice tone, and an emulator menu sits behind a Select hold, with time
scrubbing by deterministic replay (as Snouty Boy and Snouty Gear).

Status: M4 (perf) done; history in PLAN.md. M3 added the time scrubber,
M4 drive ROMs at contiguous speed even when fragmented and Smooth H40 on
by default. Up to M2: the 68000, VDP, Z80 sound side and the one tone voice run
(M1: the test ROM and Sik's Miniplanets play under the 33 ms budget on the
calibrated benchmark). M2 adds the boot splash (Iris mark), the emulator
menu behind a 500 ms Select hold (buttons remap, squeeze/crop scale,
sound, debug overlay, reset, pick ROM, about), the drive picker when
several ROMs are on the badge drive and a help screen when none is. Sound
is off at boot (`-Dsound=true` flips it; root docs/SOUND.md). Time
scrubbing came in M3 (`docs/m3_scrub.gif`). `docs/m2_splash_menu.gif`, `docs/m2_picker.png`,
`docs/m2_help.png` show it.

```sh
(cd ../.. && zig build -Dcart=snouty-genesis -Dcart-mode=xip)  # ../../zig-out/firmware/snouty-genesis-xip.uf2, ../../zig-out/bin/snouty-genesis.wasm
(cd ../.. && zig build test-genesis -Dcart=snouty-genesis -Dcart-mode=xip)  # this cart's host tests
```

- `docs/RUNNING.md`: build options, tests, preview, bench, the ROM on the drive.
- `SPEC.md`: design. `PLAN.md`: current milestone contract.
- `docs/ROM_STREAMING.md`: why a ROM can be read from the drive in place.
