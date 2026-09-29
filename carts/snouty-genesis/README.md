# Snouty Genesis

A Sega Genesis (Mega Drive) emulator cart for the SYCL Badge V2, written in
Zig for Antithesis. The badge build plays a `.gen`/`.md`/`.bin` ROM copied
onto the badge's USB drive, read in place from flash (no reflash per game,
ROMs up to about 900 KB), with a small test ROM embedded as the fallback and
as the simulator's ROM. It is an XIP cart (code in the 256 KB cart flash
window) and presents at 30 Hz with two Genesis frames per update. Planned:
the 68000 at full speed, the Z80 sound CPU from Snouty Gear driving a
one-voice tone, an emulator menu behind a Select hold and time scrubbing by
deterministic replay, as Snouty Boy and Snouty Gear.

Status: M0 scaffold. The core holds the whole console state at its real
size but is a stub: every frame it draws a test pattern (color bars,
shadow/highlight bands, a moving block). The bottom line says which ROM was
chosen (`ROM: embedded placeholder.bin 1 KB`, or the drive file, contiguous
or fragmented, with its CRC).

```sh
(cd ../.. && zig build -Dcart=snouty-genesis -Dcart-mode=xip)  # ../../zig-out/firmware/snouty-genesis-xip.uf2, ../../zig-out/bin/snouty-genesis.wasm
(cd ../.. && zig build test-genesis -Dcart=snouty-genesis -Dcart-mode=xip)  # this cart's host tests
```

- `docs/RUNNING.md`: build options, tests, preview, bench, the ROM on the drive.
- `SPEC.md`: design. `PLAN.md`: current milestone contract.
- `docs/ROM_STREAMING.md`: why a ROM can be read from the drive in place.
