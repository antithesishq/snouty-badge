# Snouty Theremin: plan

SPEC.md is the design. This file is the milestone contract and the status
log. The time-of-flight work as a whole is docs/TOF.md; this cart is its
M1.

Worktree `/home/exedev/snouty-badge-theremin`, branch `tof/theremin`
(not merged; the lead wires the sensor driver and merges). Build from the
repository root:

```
export PATH="$HOME/.local/bin:$PATH"
zig build -Dcart=snouty-theremin          # zig-out/firmware/snouty-theremin.{uf2,elf}, zig-out/bin/snouty-theremin.wasm
zig build test -Dcart=snouty-theremin     # host tests (this cart + lib/)
zig build check-float -Dcart=snouty-theremin
badge-bench/bench.sh zig-out/firmware/snouty-theremin.elf
```

## M1: the theremin (built 2026-10-05)

Contract (docs/TOF.md M1, the lead's brief):

1. Cart scaffold: `carts/snouty-theremin` (binary `snouty-theremin`), root
   build.zig entry, root CLAUDE.md cart list, badge-bench toml, wasm shims.
2. Input behind one integration point, `input.zig` `sensor_frame`, built
   against `lib/tof_types.zig` only (lib/tof.zig is the other track's);
   returns null until wired. Stick fallback; automatic switch to the sensor
   when frames arrive.
3. Layouts ONE-HAND and TWO-HAND with orientation and handedness.
4. Pitch mapping (3 octaves, exponential in distance), median + glide,
   hand-absent fade, scale snap (off, chromatic, major, pentatonic; soft
   and hard), key and octave.
5. A continuous-phase voice with four waveforms (band-limited saw and
   square, filtered) streamed into lib/stream_audio's ring; survives a slow
   frame; no `cart.tone2` on the badge; the simulator's `tone` import in
   wasm.
6. Sound boots ON, Select mutes, mute always visible; Start+Select chord
   ignored; never bind click.
7. Screen: note + cents, scope, zone grid, hand bars, labels, Snouty,
   hints, settings menu. 60 fps, `.no_copy_full_frame`.
8. Host tests for mapping, snap, smoothing, fade, layouts, voice, feeder;
   wired into `zig build test`.
9. Gate: `zig build`, `zig build test`, badge-bench under 16.7 ms with the
   audio path exercised (no underruns), a WAV checked for clicks, the
   preview GIF.

### Status

Done on `tof/theremin`, all nine items.

- Host tests: 32 in the cart (pitch 7, hands 3, voice 8, play 8, audio 3,
  input 3), all passing under `zig build test`.
- badge-bench, calibrated (2026-10-05), `badge-bench/carts/snouty-theremin.toml`
  (900 frames of `tools/scripts/melody.json`: stick melody, glides, all four
  waveforms, Right hold, mute): busy ms mean 0.56, p95 0.68, worst 0.88
  (frame 0, the first ring fill); 5% of the 16.7 ms budget. Audio: 1299
  mixes, 0 underruns after the 1024-sample start-up, queue at each mix
  min 1536 mean 1891 max 2048. Hot: `screen.draw` 34.7 k cycles/frame,
  `voice.Voice.dispatch` (the render loop) 24.8 k, `gfx.text` 14.5 k.
- Demo hand (`--poke snouty_theremin_fake=2`, 900 frames, two-hand):
  worst 0.90 ms, mean 0.55, 0 underruns.
- WAVs (scratch only, not committed): the stick run and the demo-hand run.
  Sine passages: largest sample-to-sample step 5-7 in the melody (a
  470 Hz sine at peak 120 moves 8) and 12 at the top of the glide (F5,
  700 Hz: 12), no second difference above 12 anywhere in the demo-hand
  run (no clicks at onsets, releases, volume moves or note glides); the
  only larger steps in the stick run are the triangle's corners and the
  saw and square edges (band-limited: 81 and 70 at most against 200 and
  168 for naive edges).
- Preview: `docs/preview_m1.gif` (wasm, 15 s): stick melody in C major,
  glides with TRI, SAW, SQR, then the demo hand in 2 HAND, then MUTED.

### Integration for the lead

- `cart/src/input.zig` `sensor_frame(now_us: u64) ?tof_types.Frame` is the
  only place the driver goes: call its `poll(now_us)` and return a frame
  that is new since the last call (null otherwise). It takes `now_us`
  (unlike the brief's `sensor_frame()`) because the driver's cooperative
  poll needs the time and input.zig stays free of the cart API so its
  source-switching tests run on the host. Duplicates by `seq` are dropped
  anyway.
- `build.zig` `add_lib_imports` is where `lib/tof.zig` (and, if the wasm
  build should use `lib/tof_virtual.zig` as docs/TOF.md says, that) gets
  imported.
- `main.zig` `orientation` is the mounting constant (deferred question 2).
- `hands.Config.min_confidence` (8) is a guess: the 8820's confidence
  scale is unmeasured.

### Deferred questions

1. Sound boots ON (docs/TOF.md deferred question 1). One line: `muted`'s
   initial value in main.zig.
2. Orientation default (docs/TOF.md deferred question 2), from M0's photos.
3. Default scale FREE (a real theremin is continuous) vs PENTA SOFT
   (friendlier for a passer-by). Kept FREE.
4. Wide SPAD map (6: 41x52 deg) for two-hand play: the default 33x32 deg
   field is ~12 cm across at 20 cm, tight for two hands. Driver config,
   M0's call; the cart works with either.
5. Sensor rate: the cart takes the latest frame per update; 30 Hz is
   enough (the median and glide are tuned for it); at 60+ Hz the median's
   lag halves.
6. Wasm: when lib/tof_virtual.zig lands, the wasm build could take its
   frames instead of the stick; the demo hand stays a debug tool.
