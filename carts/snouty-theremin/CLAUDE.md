# Snouty Theremin

A badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a theremin played by hand distance over the TMF8820
time-of-flight sensor on the Qwiic port (docs/TOF.md M1), or by the stick
without one. `SPEC.md` is the design, `PLAN.md` the milestone status and
open questions. The repository's `CLAUDE.md` has what every cart shares;
this file adds the cart's specifics.

## Layout

- `cart/src/` (SPEC.md section 7): `main.zig` (`start`/`update`, buttons,
  the simulator tone shim, debug exports, the `snouty_theremin_fake`
  badge-bench poke, simulator shims); `input.zig` (**the sensor
  integration point `sensor_frame`**, source selection, the demo hand);
  `hands.zig` (layouts from a frame); `pitch.zig` (distance map, scale
  snap, note names, cents to phase increment); `play.zig` (settings, the
  per-update player); `voice.zig` (the oscillator); `audio.zig` (the
  streaming-ring feeder); `screen.zig`, `gfx.zig` (drawing);
  `gen/tables.zig` (written by `tools/gen_tables.py`, do not edit),
  `gen/font5x7.zig` and `gen/font8.zig` (per-cart copies of paperclips'
  and snouty-cycles' generated fonts); `host_tests.zig`.
- Everything except `main.zig`, `screen.zig` and `gfx.zig` is free of the
  cart API and host-tested.
- `tools/gen_tables.py` (`--check` to verify), `tools/scripts/melody.json`
  (the stick melody: preview GIF and badge-bench).
- `docs/RUNNING.md`, `docs/preview_m1.gif`.

## Rules specific to this cart

- Sound boots ON (an instrument; docs/TOF.md deferred question 1) and
  `-Dsound` does not apply; Select mutes. Badge builds stream through
  lib/stream_audio.zig and never call `cart.tone2`; wasm drives the
  simulator's `tone` import.
- Per-sample work stays integer (u32 phase, Q15/Q16); float only in host
  tests. `zig build check-float -Dcart=snouty-theremin` checks the ELF.
- Start and Select act on release; nothing reacts while both are held.
- The sensor's frames come only through `input.sensor_frame`.
