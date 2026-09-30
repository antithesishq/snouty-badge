# Snouty Lynx: plan

SPEC.md is the design. This file is the working contract for the current
milestone. Nothing below starts until Adrian has answered SPEC.md
section 18 (item 1 decides whether this waits for Snouty Gear M3).

## M0 Research and scaffold (two tracks, then me)

Execution 2026-09-30: integration branch `lynx/m0` in worktree
`/home/exedev/snouty-badge-lynx`. Track A "boot" (branch `lynx/m0-boot`,
worktree `-lynx-boot`): facts check, CPU test choice, `core/boot.zig` with
host tests, cross-check against the local boot ROM, ROM candidates with
licences, compression numbers. Track B "scaffold" (branch `lynx/m0-scaffold`,
worktree `-lynx-scaffold`): cart skeleton, build wiring, ROM source
(drive/embed), romfs images, bench toml, gitignore, byte-identical check.
Integration: merge both, `zig build` + `zig build test`, sizes, tag
`snouty-lynx/m0`, push `lynx/m0:main`.


- Facts: check every SPEC.md section 3 register and section 19 item
  against the Epyx hardware spec and cc65's `lynx.h`; write corrections
  into SPEC.md with the source.
- CPU tests: pick the SingleStepTests 65x02 variant matching the 65SC02;
  sparse fetch in `tools/fetch_test_roms.sh`.
- ROMs: Adrian's dumps are at `~/roms/lynx/` on the VM (outside the
  repo): `hard_drivin.lnx`, `blue_lightning.lnx` (both 128 KB, headerless;
  SPEC 18.3) and `lynxboot.img` (SPEC 18.2). Record per-16 KB compression
  (for the 13.1 fallback). Headerless files are accepted everywhere the
  `.lnx` header is (block size from file size).
- Boot path per section 18 item 2: implement the loader decryption in
  `core/boot.zig` from the public write-ups (host-tested). Verification:
  a host-only test (skipped when the file is absent) runs Adrian's
  `~/roms/lynx/lynxboot.img` on the 65SC02 core against the real cart
  image and compares the RAM the two routes leave; the decrypted loader
  must also disassemble to sane 65SC02 code that jumps to the loaded game.
  If the public route is incomplete, the packer/boot uses constants read
  from the local image and SPEC 18.2 records it.
- ROM source per `docs/ROM_DRIVE.md`: `-Dlynx-rom-source=drive|embed`, the
  shared romfs parser (reuse it if Snouty Gear or Snouty Genesis built it
  first), romfs images for host tests and badge-bench.
- Shipped ROM candidates with licenses, as Snouty Gear section 11 did.
- Scaffold: `carts/snouty-lynx/` per SPEC.md section 15, root `build.zig`
  line, `-Dlynx-rom`, test pattern, `*.lnx`/`*.lyx` in the root
  `.gitignore`, badge-bench toml.
- Done when: the RAM cart builds, `zig build test` passes, other carts'
  uf2 byte-identical, and the ROM sizes are recorded.

## M1 Core: contract

Written at the end of M0, once the register facts and the boot path are
confirmed (frozen interfaces: `Lynx.step_frame(pad)`, the Bus methods,
the `line_sink`/frame sink, the Suzy entry point and its bus-time
charge).

## Status

- 2026-09-29: SPEC.md and this plan drafted; waiting on section 18.

## Track B report (scaffold, branch `lynx/m0-scaffold`, 2026-09-30)

Files (all new unless noted):

- Root: `build.zig` (carts table line, `-Dlynx-rom`, `-Dlynx-rom-source`),
  `build/common.zig` (`lynx_rom`, `lynx_rom_source: RomSource`),
  `.gitignore` (`*.lnx`, `*.lyx`, `!carts/snouty-lynx/roms/placeholder.lnx`),
  `README.md` (cart row), `badge-bench/carts/snouty-lynx.toml`.
- `carts/snouty-lynx/`: `build.zig` (RAM cart + wasm, generated `rom`
  module, `drive` module, host tests on `zig build test` and
  `zig build test-lynx`), `CLAUDE.md`, `README.md` (ROM on the drive,
  Gear's wording), `docs/RUNNING.md`, `docs/m0_splash.png`,
  `docs/m0_screen.png`, `.gitignore`.
- `core/`: `lynx.zig` (`Lynx`, `Pad`, `Frame`, `init_in_place`, `reset`,
  `step_frame` = M0 test pattern, `frame()`), `cart.zig` (SPEC 7's name;
  `parse` -> `Layout`/`Refusal`, `Cart` = 256 block pointers + fallback),
  stubs `cpu65.zig` (`Regs`, `Cpu(Bus)`), `bus.zig` (addresses, MAPCTL
  bits), `mikey.zig` (palette, DISPADR), `suzy.zig`.
- `cart/src/`: `main.zig` (splash -> running, status strip, no-ROM help,
  wasm shims, 11 `debug_*` exports), `frontend/{video,input,drive,romsrc,
  splash,debug,text,menu}.zig` (`menu` is an M2 stub; `text` is Gear's
  verbatim; `drive` is a module of its own, as Genesis's).
- `tests/`: `all.zig`, `cart_unit.zig` (6 tests), `drive_unit.zig`
  (4 tests), `fixtures/make_fixtures.py` + `m0_drive.img` (18,944 B) and
  `m0_none.img` (11,264 B); plus the `lynx:` test in core/lynx.zig: 11/11.
- `roms/placeholder.lnx` (576 B: header declaring a 128 KB bank + one
  512 B block; not a Lynx program) from `tools/make_placeholder_rom.py`;
  `tools/scripts/m0_boot.json`.

Parser: headered = trust the header (bank 0 page size 256/512/1024/2048,
data at 64, short files allowed, missing bytes 0xFF); headerless = block
size from the file size (<= 128 KB 512 B, <= 256 KB 1 KB, <= 512 KB 2 KB).
Refused: bank 1, rotation, bad bank 0 size, over 512 KB, empty. EEPROM:
accepted, `warn_eeprom()`, strip shows `no-EEPROM`. Deviation: 64 KB banks
(256 B blocks) are accepted too (SPEC 11 lists 128/256/512 KB); Track A's
romcheck.py may want the same.

Sizes (ReleaseFast, drive source, placeholder embedded): `.text` 29,944 B,
`.data` 112, `.bss` 73,920 (the `Lynx` static 66,644 B, the romfs cluster
table 5,120 B); uf2 209,920 B; wasm 231,442 B. Free run-time arena
`__bss_end__` 0x2004e838 .. `__stack_limit__` 0x20078000 = 169,928 B
(168,904 B after Gear's 1 KB guard): what M1's code growth and the M3
scrub ring share. Console RAM is already in `.bss`, the ~8 KB frame lives
inside it (DISPADR), so the SPEC 13 ring target (>= 64 KB) fits unless M1
code grows by more than ~100 KB.

badge-bench (calibrated, busy ms, 300 frames, `m0_boot.json`, splash
skipped at 40 then the placeholder screen): fixture drive (GAME.LNX runs)
mean 0.70, p95 0.76, worst 0.76 (frame 40), start-up 2.28 ms; local
Hard Drivin' drive image (`out/lynx-romfs.img`, 128 KB headerless, crc
6DF63834) mean 0.71, worst 0.77, start-up 7.32 ms (the CRC over 128 KB);
no-ROM help (`m0_none.img`) mean 0.88, worst 0.96. 0 frames over budget,
neopixels never written. Hot: `run_frame` 81% (the frame conversion),
`text.draw` 13%.

Byte-identical check: every other cart's uf2 (11 files) and wasm
(11 files) from a clean `zig build` at `c25f5bb` (`out/baseline-*.sha256`)
equals the build with this branch. `zig build` succeeds for all carts;
`zig build test`: 472/473, the one failure is demosnout's
`timeline.test.hold: endless parts run on...` (expected .seamless, found
.fade), which fails identically at `c25f5bb` (checked in a detached
worktree): pre-existing, not touched here.

Preview: `node tools/preview.mjs` with `m0_boot.json` passes
`debug_state == 1`, `debug_led_max == 0`, Pause 256 at 105, Up+B 130 at
135, Option 1 (8) after the Select tap at 163.

Left as stubs / for later: cpu65, bus, mikey, suzy (M1); menu (M2; a
Select hold does nothing yet); no sound and no `build_options.sound` (add
it with the first tone, docs/SOUND.md); the 256-entry byte -> pair table
of SPEC 6 is a shift and mask for now (M4 measures); the picker (M2)
reads `romsrc.candidates()`; `pack` prints "not built". `-Dlynx-rom` has
no cart-relative form (no filesystem probe). Not registered in the
badge-manager station sets.
