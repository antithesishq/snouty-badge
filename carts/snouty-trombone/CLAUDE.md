# Snouty Trombone

A badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a slide trombone played by hand over the TMF8820
time-of-flight sensor on the Qwiic port (docs/TOF.md), or by the stick
without one. Hand height is the slide, hand side to side the embouchure
(which partial of the harmonic series sounds). Sibling of
`carts/snouty-theremin` (same sensor path, streaming audio and button
conventions). `SPEC.md` is the design, `PLAN.md` the milestone status and
open questions. The repository's `CLAUDE.md` has what every cart shares;
this file adds the cart's specifics.

## Layout

- `cart/src/`: `main.zig` (`start`/`update`, buttons, the simulator tone
  shim, debug exports, the `snouty_trombone_fake` and
  `snouty_trombone_zones` badge-bench pokes, ZONES switching, simulator
  shims); `input.zig` (**the sensor integration point
  `sensor_frame`**, source selection, the demo hand and its tune);
  `sensor.zig` (lib/tof.zig on the badge: GRID = wide SPAD map 6,
  STRIPES = the 8-stripe user mask, docs/TOF.md M5); `hand.zig` (height
  = the pose's near-cluster `height_mm`, lip tension from the pose's
  arm-rejected centroid as an angle, span per layout); `horn.zig` (slide map, harmonic series, embouchure with
  hysteresis and lip bend, note names, phase increments); `play.zig`
  (settings, the per-update player: blowing, smoothing, cracks, stick);
  `voice.zig` (the brass voice: band-limited pulse, state-variable filter,
  blat, crack split tone, plunger); `audio.zig` (the streaming-ring
  feeder, a copy of the theremin's); `screen.zig`, `gfx.zig` (drawing);
  `gen/tables.zig` (written by `tools/gen_tables.py`; M5 dropped its 3x3
  ray-to-height table, the pose does that now), `gen/art.zig`
  (written by `tools/gen_art.py`), `gen/font5x7.zig` and `gen/font8.zig`
  (per-cart copies of the theremin's fonts); `host_tests.zig`.
- Everything except `main.zig`, `screen.zig`, `gfx.zig` and `sensor.zig`
  is free of the cart API and host-tested.
- `tools/gen_tables.py` and `tools/gen_art.py` (`--check` to verify each;
  `gen_art.py --png out.png` writes a 4x preview of the art closed and at
  7th position), `tools/scripts/stick.json` (the stick performance:
  badge-bench), `tools/scripts/preview.json` (its first part, for the GIF).
- `docs/RUNNING.md`, `docs/preview_m1.gif`.

## Rules specific to this cart

- Sound boots ON (an instrument, as the theremin) and `-Dsound` does not
  apply; Select mutes. Badge builds stream through lib/stream_audio.zig
  and never call `cart.tone2`; wasm drives the simulator's `tone` import.
- Per-sample work stays integer (u32 phase, Q15/Q16, i64 products in the
  filter); float only per sensor frame (the pose, `hand.lip_t`, the demo
  hand's synthetic frames) and in host tests. `zig build check-float
  -Dcart=snouty-trombone` checks the ELF.
- Left/right comes from the pose's coverage centroid, never the closest
  zone (the theremin's M1.2 lesson).
- Read each frame by its own `frame.layout` (GRID or STRIPES), never by
  the ZONES setting: frames measured before a switch are dropped in
  `main.update`. Anything per zone goes through the pose's cells
  (`cols` x `rows`), not a hard-wired 3x3.
- Start and Select act on release; nothing reacts while both are held;
  joystick click is never bound.
- The sensor's frames come only through `input.sensor_frame`.
- Art and tables are generated on the host and committed; keep comptime
  light (Adrian's Mac Zig runs out of memory on heavy comptime).

## Gates (from the repository root)

```
zig build                                   # every cart
zig build test                              # every cart's host tests and lib/'s (the exit code counts)
zig build check-float -Dcart=snouty-trombone
python3 carts/snouty-trombone/tools/gen_tables.py --check
python3 carts/snouty-trombone/tools/gen_art.py --check
badge-bench/bench.sh zig-out/firmware/snouty-trombone.elf
```
