# Snouty Gear

A Sega Game Gear emulator cart for the SYCL Badge V2, written in Zig for
Antithesis. On the badge it plays a `.gg` ROM copied onto the badge's USB
drive, with the MIT-licensed Waternet embedded as the fallback and as the
simulator's ROM. The 160x144 screen is squeezed onto the badge's 160x128 by
dropping every ninth line. Planned: an emulator menu behind a Select hold,
one-voice sound and time scrubbing by deterministic replay, as Snouty Boy.

Status: M1 core. The console is emulated (Z80, VDP, Sega mapper, ports,
PSG registers) with no sound, menu or rewind yet; the screen's bottom line
says which ROM was chosen (`ROM: embedded waternet.gg 64 KB`, or the drive
file with its CRC).

```sh
(cd ../.. && zig build -Dcart=snouty-gear)   # ../../zig-out/firmware/snouty-gear.uf2, ../../zig-out/bin/snouty-gear.wasm
(cd ../.. && zig build test)                 # host tests (all carts)
python3 tools/romcheck.py roms/waternet.gg   # can this ROM run here?
```

- `docs/RUNNING.md`: build options, tests, preview, the ROM on the drive.
- `SPEC.md`: design. `PLAN.md`: current milestone contract.
