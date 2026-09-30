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
- 2026-09-30: M0 DONE. Tracks A and B merged on `lynx/m0` (b950ebe), tag
  `snouty-lynx/m0`. Merged tree: root `zig build` builds every cart; the 22
  other uf2/wasm files are byte-identical to origin/main 2680e2a (compared
  from the same directory: the wasm files embed the build path, so hashes
  from different worktrees differ); `zig build test` 461/462, the one
  failure is demosnout's pre-existing `timeline` test (fails at 2680e2a
  too, not ours); Lynx 22/22 with the local test data (both boot ROM
  cross-checks match, 240,000 SingleStepTests cases parse). Sizes with
  raycast.lnx embedded: .text 57,124 B (27,765 of it the ROM), .bss 73,920,
  uf2 264,192, wasm 258,974. badge-bench fixture run: busy mean 0.70 ms,
  worst 0.76, 0 over, LEDs off. Open for M1: `core/boot.zig` and
  `core/cart.zig` each parse the header (unify in M1; boot's `Cart` is the
  test-side one), M1 must trap $FE00/$FE4A (docs/BOOT.md), badge-manager
  station set registration, hardware never seen (show-day gate).
- 2026-09-30: M0 Track A (boot) done on `lynx/m0-boot`; report below.
  ROM sizes and compression (tools/romcheck.py, sizes only): Hard Drivin'
  131,072 B headerless, 256 x 512 B, 3-block loader, zlib -9 57.8% (per
  16 KB: 70 55 66 52 58 60 43 59), zstd -19 55.0%; Blue Lightning 131,072
  B headerless, 256 x 512 B, 5-block loader, zlib 69.2% (73 66 67 55 84 87
  96 26), zstd 68.1%; raycast.lnx (shipped) 27,765 B headered, 1 KB
  pages, 1-block loader, zlib 27.5%, zstd 25.1%; lniccc2000_tsc.lnx (not
  shipped) 524,352 B, 2 KB pages, zlib 83.2%, zstd 83.0%. For SPEC 13.1: a
  128 KB commercial title packs to ~72-91 KB, so 256 KB titles would need
  ~140-180 KB of flash, the top of the estimate.


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

## Track A report (M0 boot, 2026-09-30)

**Facts (SPEC section 3, section 20).** Every item checked against the
Epyx documentation (monlynx.de), cc65, Felix (facts only), 42Bastian's
hardware carts and our boot ROM cross-check. Corrected in place: (1) the
Lynx CPU does execute RMB/SMB/BBR/BBS (Felix; 42Bastian's hardware
Snake249 uses BBR/SMB) and has no WAI/STP, so it is the Rockwell 65C02
set, not a "65SC02 without bit instructions"; (2) page mode: fetches 4
ticks, every other RAM/ROM access 5 ticks (not only page breaks); (3)
sprite type numbering (0 background-shadow .. 7 shadow); (4) the boot ROM
loads a frame of 1-5 blocks and loaders re-enter it at $FE00/$FE4A.
Confirmed: memory map and MAPCTL bits, timers and their chains, audio
registers, interrupts, display registers, cart block select (MSB first,
IODAT bit 1, SYSCTL1 bit 0 edge) and the 11-bit counter, SCB layout,
packed format, math unit, joystick (with the LEFTHAND swap). Open:
undefined-opcode timings on hardware ($5C: 4 cycles in SingleStepTests,
8 in Felix) and SP before reset.

**CPU tests (SPEC 16).** SingleStepTests `rockwell65c02/v1`.
`tools/fetch_test_roms.sh` fetches 24 files (~97 MB, 240,000 cases) plus
drhelius's MIT lynx-tests (19 carts); `--all` streamed all 256 files in
batches of 32 and all parse (tests/roms/65c02/results.txt).
`tests/cpu65_single_step.zig` parses and shape-checks them; M1 adds the
CPU run.

**Boot (core/boot.zig, docs/BOOT.md).** `Cart.from_file` (headered or
headerless), `post_boot(cart, ram) BootError!BootState` (RAM, registers,
MAPCTL, IODIR/IODAT/SYSCTL1, Mikey writes, cart block/counter),
`decrypt_frame(reader, ram)` for the $FE4A trap, `SetCartBlockExit` for
the $FE00 trap. Public constants only (annotated disassembly and
lynx-encryption-tools, which agree); 13 x 32-bit limbs, no allocator, no
floats. Functions are snake_case per the repo style (`post_boot`, not
`postBoot`).

**Cross-check.** `tools/bootrom_crosscheck.py` (py65) runs the local boot
ROM image against each cart until the loader hands over to the game;
`tests/boot_crosscheck.zig` compares. Hard Drivin' and Blue Lightning
match exactly in registers (A 0, X 0, Y 2, P $37, SP $01), MAPCTL 0,
IODIR 3, IODAT 2, SYSCTL1 2, cart counter (154, 256), Mikey values, the
loader bytes, zero page $00-$07, all other RAM outside the ROM's work
areas, and the second $FE4A pass of each (bytes, counter, flags; Hard
Drivin' leaves P $36). Loaders use only $FE00 (331 and 266 calls) and
$FE4A (once) and reach game code at $3A51 / $137B with no timer model.
The public route is complete; the 18.2 fallback was not used. Not
reproduced: ROM work bytes in $08-$1FF and its routine copy at
$5000-$50FF (ROM code; no loader calls it directly).

**Shipped ROM.** `roms/raycast.lnx`, 42Bastian's textured raycaster,
Apache-2.0 (`roms/LICENSE-raycast.txt`), 27,765 B; boots in a host test.
Survey in `docs/ROM_CANDIDATES.md`.

**Tests.** 12 host tests (`zig build test -Dcart=snouty-lynx`): 5
known-answer/unit (cc65 bootldr.s and Wookie loaders, arithmetic, rejects,
header), 3 loader plausibility (2 local dumps, skipped when absent;
raycast), 2 boot ROM cross-checks (skipped without the JSON), 1 SST parse
(skipped without data), plus the entry test. All pass on the VM.

**Files.** `build.zig` (root: one cart line), `.gitignore` (root: `*.lnx`,
`*.lyx`, raycast exception), `carts/snouty-lynx/`: `.gitignore`,
`build.zig` (tests only), `core/boot.zig`, `tests/{all,testfiles,
boot_unit,boot_local,boot_crosscheck,cpu65_single_step}.zig`,
`tools/{fetch_test_roms.sh,bootrom_crosscheck.py,romcheck.py}`,
`docs/{BOOT,ROM_CANDIDATES}.md`, `roms/{raycast.lnx,LICENSE-raycast.txt}`,
`SPEC.md` (sections 3, 7, 11, 16, 18.2, 19, 20, status), this file.

**For the integrator (merge with Track B).** `carts/snouty-lynx/build.zig`
is Track A's tests-only `add`: keep Track B's, and add the test block
(a `boot` module rooted at `core/boot.zig`, imported by `tests/all.zig`;
or a `core` module and `tests/*.zig` switched to it). The root
`build.zig` cart line and the root `.gitignore` `*.lnx`/`*.lyx` lines
will conflict with Track B's identical ones: keep one copy and keep the
`!carts/snouty-lynx/roms/raycast.lnx` exception below them. If Track B
added `tests/all.zig` or `carts/snouty-lynx/.gitignore`, merge the
imports / lines (`tests/roms/`, `out/`). Track B's `-Dlynx-rom` default
should be `roms/raycast.lnx`. M1 must trap $FE00 and $FE4A (docs/BOOT.md
"What M1 needs").
