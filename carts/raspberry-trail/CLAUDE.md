# The Raspberry Trail (cart notes)

A faithful port of the 1978 MECC BASIC *Oregon Trail* listing to the SYCL
badge, named for the badge's Raspberry Pi RP2350. `SPEC.md` is the design,
`PLAN.md` the milestones, tracks and gate. The root `CLAUDE.md` has the
hardware, the cart API and the repository policies. `reference/oregon.bas`
is the game's specification: never edit it.

## Layout

- `cart/src/game/` (the `game` module): the engine, a resumable port of
  the listing. No cart API; host tested. `game.zig` is the interface.
- `cart/src/main.zig`, `cart/src/ui/`: the cart shell and the UI.
- `cart/src/art/`: generated pictures plus a draw API (from
  `tools/gen_art.py`).
- `tools/oracle/`: a BASIC interpreter that runs the unmodified listing,
  with the answer scripts, the comparison and the fuzzer.
  `tools/oracle_runner.zig` is the engine side (`zig build
  raspberry-trail-oracle`).
- `tools/check.sh`: the gate.

## Rules of thumb

- Fidelity first. If the badge plays differently from the listing, that is
  a bug, unless SPEC says otherwise (shooting input, spinner bounds).
- RAM cart, ReleaseSmall. No neopixels, no saves. Sound only through
  `lib/tone_stream.zig`, off by default.
- Every frame redraws the whole screen (`.no_copy_full_frame`).
- Keep comptime light (the Mac build): data comes from generators.
- Zig here is 0.17-dev: `@splat` instead of `**` repetition,
  `@typeInfo(T).@"enum"`.
