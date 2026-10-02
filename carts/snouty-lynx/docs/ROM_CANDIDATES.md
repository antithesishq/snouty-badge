# Shipped ROM candidates (M0, 2026-09-30)

SPEC.md section 11 and 18.3: the embedded fallback / simulator ROM must be
redistributable. Only an explicit licence counts: a LICENSE file in the
source repository or the author's written grant. "Freeware" without terms
is a no. Checked by web search and by fetching the files; `tools/romcheck.py`
numbers for the downloaded ones. The AtariAge forum blocks scripted
fetches, so licence statements posted only there were not checked.

| Title | Author | Size | Licence (source) | Headered? | Rotation / EEPROM | 3D? | Verdict |
|---|---|---|---|---|---|---|---|
| **raycast.lnx** | 42Bastian (Bastian Schick) | 27,765 B (1 KB pages, image shorter than its 256 KB bank) | Apache-2.0, repository LICENSE: https://raw.githubusercontent.com/42Bastian/lynx_hacking/master/LICENSE (moved to https://codeberg.org/42Bastian/lynx_hacking) | yes, "RAYCAST" / "42Bastian" | none / none | textured raycaster, doors, monster and smiley sprites, joystick | **ship** (in `roms/`) |
| lniccc2000_tsc.lnx (ST-NICCC 2000 port) | 42Bastian | 524,352 B (512 KB, 2 KB pages) | Apache-2.0 on the repo, but the scene data is Leonard^Oxygene's ("Leonard^Oxygene who did the orignial demo and the data set", its readme) with no stated licence | yes | none / none | yes: 1,800 frames of real-time filled polygons | no (data licence unclear); local stress target only |
| lynx-tests 1.4.9 (19 carts: cpu, page-mode, math, timers, sprites1-5, uart, audio, ...) | drhelius (Ignacio Sanchez Gines) | 2.4-10.6 KB each | MIT: https://github.com/drhelius/lynx-tests (LICENSE: "MIT License / Copyright (c) 2025 Ignacio Sanchez Gines / Permission is hereby granted, free of charge...") | yes, cc65 | none / none | no | test ROMs: fetched by `tools/fetch_test_roms.sh` into `tests/roms/lynx-tests/` for M1 |
| monalynx | 42Bastian | 262,208 B | Apache-2.0 (same repo) | yes, 1 KB pages | none / none | no | maybe (a 256-byte intro port: dull) |
| nostalgia | 42Bastian | 524,352 B | Apache-2.0 (same repo) | yes, 2 KB pages | none / none | not checked (only the header fetched) | maybe |
| cc65 samples/lynx (hello, mandelbrot, tgidemo) | cc65 project | source only | zlib: https://github.com/cc65/cc65 | built by cc65's `lynx` target | none | no (lines, circles, Mandelbrot) | maybe, if built (no cc65 on the VM) |
| SpriteTestLynx | Brian Peek | source only | MIT: https://github.com/BrianPeek/SpriteTestLynx | built by cc65 | none | no (sprite-count benchmark) | maybe, if built |
| ikromin/atarilynx (Cackleberry Rescue, ...) | ikromin | | no LICENSE file ("All source code... written by me") | | | | no |
| 4Ttude (3D tic-tac-toe), Santafactory | nop90 | | no licence | | | | no |
| z88kat sprites tutorial, okiyasu atari-lynx-shooter, AtariLynx/programming-tutorial | various | | no licence | | | | no |
| Karri Kaksonen's games (Solitaire, On Duty, ...) | Karri Kaksonen | | commercial / freeware, no licence | | | | no |
| obschan 3D Raycast Demo (2012) | obschan | | no licence found | | | 3D | no |
| Songbird releases, archive.org / Zophar "PD" collections | various | | no licence terms | | | | no |
| fork_lynx_smb | 42Bastian | | Super Mario Bros port (Nintendo IP) | | | | no |

## Recommendation

Ship `roms/raycast.lnx` (with `roms/LICENSE-raycast.txt`, the Apache-2.0
text and its provenance). It is the only candidate that is explicitly
licensed, small enough for the embedded fallback (27 KB against SPEC 13's
16-32 KB line; zlib takes it to 7.6 KB), interactive, and a 3D showpiece:
a Wolfenstein-style textured raycaster drawn with Suzy sprites, so it
exercises scaled sprites, the math unit and double buffering. It boots
through `core/boot.zig` in a host test (1-block cc65-style loader).

Things M1 must handle for it: a headered file whose image (27,701 B) is
much shorter than its declared 256 KB bank (reads past the end return
$FF), and 1 KB blocks.

For a polygon showpiece, lniccc2000 is the one to watch: if 42Bastian or
Leonard state a licence for the scene data, it becomes the drive-side demo
(512 KB, so drive only, never embedded). Otherwise the SPEC 18.3 fallback
stands: a cc65-built Snouty demo, or the parked Snouty Flyover port.

## romcheck.py summary (sizes and compression only)

| File | Size | Blocks | Loader | zlib -9 | zstd -19 | Verdict |
|---|---|---|---|---|---|---|
| Hard Drivin' (local, headerless) | 131,072 B | 256 x 512 B | 3 blocks | 57.8% (per 16 KB: 70 55 66 52 58 60 43 59) | 55.0% | drive OK |
| Blue Lightning (local, headerless) | 131,072 B | 256 x 512 B | 5 blocks | 69.2% (73 66 67 55 84 87 96 26) | 68.1% | drive OK |
| raycast.lnx | 27,765 B | 1 KB pages | 1 block | 27.5% | 25.1% | drive OK, embed OK |
| lniccc2000_tsc.lnx | 524,352 B | 2 KB pages | 1 block | 83.2% | 83.0% | drive OK (not shipped) |
| lynx-tests (19 files) | 2.4-10.6 KB | 1 KB pages | 1 block each | | | all OK |
