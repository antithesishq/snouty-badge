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
