# Snouty Genesis

A Sega Genesis (Mega Drive) emulator cart for the SYCL Badge V2, written in
Zig for Antithesis. The badge build plays a `.gen`/`.md`/`.bin` ROM copied
onto the badge's USB drive, read in place from flash (no reflash per game,
ROMs up to about 900 KB); with none there it shows a no-ROM screen saying
how to add one. A small test ROM is embedded only in the simulator (and
`-Dmd-rom-source=embed` builds). It is an XIP cart (code in the 256 KB cart flash
window) and presents at 30 Hz with two Genesis frames per update. The 68000 runs at full speed, the Z80 sound CPU from Snouty Gear drives a
one-voice tone, and an emulator menu sits behind a Select hold, with time
scrubbing by deterministic replay (as Snouty Boy and Snouty Gear).
Tapping Select and then holding it fast forwards up to 4x (a lone Select
tap is Genesis A, 200 ms after the release); Left during that hold
rewinds in half-second steps where the scrubber exists (the XIP cart and
the simulator; docs/RUNNING.md section 5).

Sound (2026-10-04): the show badges' firmware plays only a streamed
44.1 kHz sample ring and has no XIP, so the RAM cart now synthesises the
YM2612 (FM, six channels) and the PSG from what the 68000 writes to them
and streams it (core/sound.zig). Its Z80 is a stub, so Sonic 1 (SMPS on
the 68000) has its music without the Z80's DAC drums, and Z80-driven
games such as Miniplanets stay silent. Sound is off at boot; the menu's
Sound row turns it on. PLAN.md "Sound on the new firmware".

Two players (2026-10-05): two badges joined by the link cable run one
game in lockstep, host on pad 1, guest on pad 2 (menu row Link: 2
players; docs/LINK_PLAY.md).

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
- `docs/LINK_PLAY.md`: two players over the link cable, and its hardware check.
