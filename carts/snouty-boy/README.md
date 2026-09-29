# Snouty Boy

A Game Boy and Game Boy Color emulator cart for the SYCL Badge V2, written
in Zig for Antithesis. One ROM (`.gb` or `.gbc`) is embedded at build time
and runs full screen: 144 lines squeezed onto the badge's 160x128 display by
dropping every ninth line, the D-pad and A/B/Start/Select mapped straight
through. An emulator menu behind a Select long-hold has palettes (or, for
Color games, raw or GBC-LCD colour), one-voice sound, and a time scrubber
that steps backwards and forwards through keyframes, verified by
deterministic replay. Keyframes live in a page store that shares unchanged
512-byte pages, so a keyframe costs a few KB and the scrubber holds 10 to
25 s of history.

Status: M4 (DMG core, menu, sound, scrubber) done; M6 (Game Boy Color)
in progress. ROMs above about 64 KB need the XIP cart
(`-Dcart-mode=xip`, see `docs/RUNNING.md`).

```sh
tools/fetch_test_roms.sh     # test ROMs into tests/roms/
(cd ../.. && zig build -Dcart=snouty-boy)   # ../../zig-out/firmware/snouty-boy.uf2, ../../zig-out/bin/snouty-boy.wasm
(cd ../.. && zig build -Dcart=snouty-boy -Drom=carts/snouty-boy/tests/roms/rebound.gbc -Dcart-mode=xip)   # a Color ROM, XIP cart
(cd ../.. && zig build test)                # core tests on the host (plus the other carts' host tests)
node ../../tools/serve-cart.mjs    # then the web simulator from ../../sycl-badge/simulator
```

Run from this cart's directory, `carts/snouty-boy/`; `zig build` runs from
the repository root.

- `docs/RUNNING.md`: prerequisites, build options, tests, simulator,
  headless preview, flashing.
- `SPEC.md`: design, architecture, milestones, decisions.
- `PLAN.md`: current milestone contract.

Companion carts: the sibling directories `../snouty-run` and
`../snouty-bugs` in this repository.
