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
