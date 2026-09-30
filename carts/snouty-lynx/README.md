# Snouty Lynx

An Atari Lynx emulator cart for the SYCL Badge V2, written in Zig for
Antithesis. On the badge it plays a `.lnx` (or headerless `.lyx`) ROM copied
onto the badge's USB drive, with an embedded ROM as the fallback and as the
simulator's ROM. The Lynx's 160x102 picture sits 1:1 at the top of the
badge's 160x128 screen with a 26-row status strip below it. Planned: the
65SC02, Suzy's sprite engine and math unit, Mikey's timers and palette,
time scrubbing by deterministic replay (SPEC.md).

Status: M0 scaffold. The Iris-mark splash, then a placeholder screen: the
core's test pattern in the picture area (the first four rows show the
ROM's first bytes as pixels) and the strip with "SNOUTY LYNX", where the
ROM came from and its name and size. No CPU, no sound yet; the neopixels
stay off. The embedded ROM is `roms/placeholder.lnx`, a 576-byte stand-in
(not a Lynx program) until M0 picks the shipped homebrew.

```sh
(cd ../.. && zig build -Dcart=snouty-lynx)   # ../../zig-out/firmware/snouty-lynx.uf2, ../../zig-out/bin/snouty-lynx.wasm
(cd ../.. && zig build test-lynx)            # this cart's host tests (`zig build test`: all carts)
```

## A ROM on the badge drive

The badge's USB drive (`SYCLBADGE`) holds carts and any other file. With the
default build (`-Dlynx-rom-source=drive`):

1. Plug in the badge, switch it on; the drive mounts.
2. Copy `snouty-lynx.uf2` onto it (replacing `CURRENT.UF2` as for any
   cart), and copy one `.lnx` file (or a headerless `.lyx` dump) next to it.
   Best on a freshly wiped drive, so the file is contiguous; a fragmented
   file still works through the per-cluster path and the strip says `frag`.
3. **Eject the drive before playing.** The OS writes flash while a host
   writes the drive, and a cart reading it at the same time could see torn
   data (docs/ROM_DRIVE.md section 2 at the repository root).
4. Start Snouty Lynx. The strip reads `SNOUTY LYNX drive` and
   `hard_drivin.lnx 128 KB crc 6DF63834` (plus `raw` for a headerless file
   and `(1 of N)` when several are on the drive: M0 runs the first playable
   one, the M2 menu lists them). With no Lynx file on the drive a help box
   says how to add one and the embedded ROM runs underneath; a refused file
   (rotated screen, bank 1) is named with the reason.

The ROM file also shows in the OS cart menu and fails to load if picked
there; that is cosmetic. Commercial ROMs never enter the repository
(`*.lnx`/`*.lyx` are gitignored at the root).

- `docs/RUNNING.md`: build options, tests, preview, simulator, badge-bench, flashing.
- `SPEC.md`: design. `PLAN.md`: current milestone contract. `CLAUDE.md`: layout and conventions.
