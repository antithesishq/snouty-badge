# Snouty Boy

A Game Boy and Game Boy Color emulator cart for the SYCL Badge V2, written
in Zig for Antithesis. It runs full screen: 144 lines squeezed onto the
badge's 160x128 display by dropping every ninth line, the D-pad and
A/B/Start/Select mapped straight through. Behind a Select long-hold: an
emulator menu with palettes (or, for Color games, raw or GBC-LCD colour),
one-voice sound, and a time scrubber that steps backwards and forwards
through keyframes, verified by deterministic replay. Keyframes live in a
page store that shares unchanged 512-byte pages, so a keyframe costs a few
KB and the scrubber holds 5 to 25 s of history.

## Getting ROMs onto the badge

1. Flash `snouty-boy.uf2` as usual (`docs/RUNNING.md` section 8).
2. With the badge connected over USB, copy one or more `.gb` or `.gbc` files
   onto the badge's USB drive, next to the UF2. Files up to 1 MB play; they
   are read in place from flash, so they cost no RAM.
3. Eject the drive before playing (the OS may write flash while the cart
   runs), then start Snouty Boy from the badge menu.
4. One playable file starts straight after the splash. Several: a picker
   lists them (Up/Down, A plays; files the cart cannot play are shown
   dimmed with the reason). Colour games are marked "Color" and play in
   colour; the header decides, not the file extension.
5. No ROM file on the drive (or no readable drive, or nothing playable):
   the cart says "No ROM on the badge drive", how to add one and why, and
   stays there (Start+Select leaves). The default UF2 has no ROM built in,
   which keeps it small on the drive (about 200 KB instead of 266 KB).

The About screen in the menu says where the running ROM came from (drive or
embedded), its CRC32 and whether it runs as a DMG or a CGB.
`tools/romcheck.py file.gbc` tells you beforehand what the cart will do with
a file. Cart RAM (saves) is not kept between runs.

## Alternative: a ROM built into the cart

For a single-game cart, embed the ROM and ignore the drive:

```sh
(cd ../.. && zig build -Dcart=snouty-boy -Drom-source=embed -Drom=carts/snouty-boy/roms/rex-runner.gb)
(cd ../.. && zig build -Dcart=snouty-boy -Drom-source=embed -Drom=carts/snouty-boy/roms/rebound.gbc -Dcart-mode=xip)
```

A ROM above roughly 64 KB (Rebound is 128 KB) needs the XIP cart
(`-Dcart-mode=xip`, `snouty-boy-xip.uf2`): code and ROM run from the 256 KB
cart flash window, so all of the RAM is scrub history. A RAM build with too
big a ROM links but shows "Not enough RAM" at start. The web simulator has
no drive and always runs the embedded ROM (`-Drom`, default
`tests/roms/dmg-acid2.gb` or `roms/2048.gb`).

Status: M1..M5 tagged; M6/M7 (Game Boy Color) and M8 (Color on the drive
loader) built, see PLAN.md. Hardware checks pending.

## Building

```sh
tools/fetch_test_roms.sh     # test ROMs into tests/roms/
(cd ../.. && zig build -Dcart=snouty-boy)   # ../../zig-out/firmware/snouty-boy.uf2, ../../zig-out/bin/snouty-boy.wasm
(cd ../.. && zig build -Dcart=snouty-boy -Drom-source=embed -Drom=carts/snouty-boy/roms/rebound.gbc -Dcart-mode=xip)   # a Color ROM embedded, XIP cart
(cd ../.. && zig build test)                # core tests on the host (plus the other carts' host tests)
node ../../tools/serve-cart.mjs    # then the web simulator from ../../sycl-badge/simulator
```

Run from this cart's directory, `carts/snouty-boy/`; `zig build` runs from
the repository root.

- `docs/RUNNING.md`: prerequisites, build options, tests, simulator,
  headless preview, flashing, ROMs from the badge drive (section 9).
- `SPEC.md`: design, architecture, milestones, decisions.
- `PLAN.md`: current milestone contract.

Companion carts: the sibling directories `../snouty-run` and
`../snouty-bugs` in this repository.
