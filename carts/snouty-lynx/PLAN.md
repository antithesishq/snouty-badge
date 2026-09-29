# Snouty Lynx: plan

SPEC.md is the design. This file is the working contract for the current
milestone. Nothing below starts until Adrian has answered SPEC.md
section 18 (item 1 decides whether this waits for Snouty Gear M3).

## M0 Research and scaffold (one agent, then me)

- Facts: check every SPEC.md section 3 register and section 19 item
  against the Epyx hardware spec and cc65's `lynx.h`; write corrections
  into SPEC.md with the source.
- CPU tests: pick the SingleStepTests 65x02 variant matching the 65SC02;
  sparse fetch in `tools/fetch_test_roms.sh`.
- ROMs: Adrian copies his `.lnx` dumps to `~/` on the VM (outside the
  repo); record sizes and per-16 KB compression (for the 13.1 fallback).
- Boot path per section 18 item 2: prototype the loader decryption in
  `core/boot.zig` (host-tested) and confirm it reproduces a known-good
  post-boot RAM image for one title (from a reference emulator run
  locally).
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
