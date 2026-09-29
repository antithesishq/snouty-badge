# Snouty Boy

A Game Boy (DMG) emulator cart for the SYCL Badge V2, written in Zig for
Antithesis. It runs a `.gb` file copied onto the badge's USB drive (read in
place from flash, up to 1 MB, a picker when there are several) or, when there
is none, the ROM embedded at build time, full screen: 144 lines squeezed onto
the badge's 160x128 display by dropping every ninth line, the D-pad and
A/B/Start/Select mapped straight through. Behind a Select long-hold: an
emulator menu with palettes, one-voice sound, and time scrubbing backwards
and forwards by deterministic replay.

Status: M1, M3 and M4 tagged; M5 (ROMs from the badge drive) in progress,
see PLAN.md. The web simulator always runs the embedded ROM.

```sh
tools/fetch_test_roms.sh     # test ROMs into tests/roms/
(cd ../.. && zig build -Dcart=snouty-boy)   # ../../zig-out/firmware/snouty-boy.uf2, ../../zig-out/bin/snouty-boy.wasm
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
