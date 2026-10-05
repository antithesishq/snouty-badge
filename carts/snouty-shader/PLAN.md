# Snouty Shader: plan

`SPEC.md` is the design. Worktree `/home/exedev/snouty-badge-shader`,
branch `shader/m1` (the parent session reviews, merges and pushes).

## M1: the gallery

- Cart skeleton (build.zig, root build.zig entry, check-float, host
  tests, badge-bench toml, README/INSTALL/CLAUDE.md rows).
- sensor.zig and hand.zig from snouty-morph (sensor, stick, ghost).
- field.zig (3x3 to 80x64 Catmull-Rom), uniforms.zig (smoothing, punch,
  flash, kick), surface.zig (spread RGB565, 2x bilinear upscale),
  palette.zig (cosine palettes), noise.zig (tileable gradient noise).
- Six programs: INK, RIPPLE, LAVA, ECHO, CELLS, KALEIDO.
- app.zig: buttons to actions (program, palette, parameter, HUD, stick,
  sound on Start release, the Start+Select chord ignored), attract.
- hud.zig: inputs panel on B, toasts.
- sound.zig: drone, thump, blip; boots silent.
- Preview GIF, docs/RUNNING.md, badge-bench per program (normal and
  `-Dtof-fake=true`).

Acceptance: gate green (`zig build`, `zig build test`, `zig build
check-float`), every program under 12 ms worst busy in badge-bench, both
builds; the GIF shows several programs driven by the ghost.

## Status

### M1: DONE 2026-10-05 (tag `snouty-shader/m1`, branch `shader/m1`)

- Six programs, all at 60 fps (none needed the 30 fps fallback), the
  inputs panel, toasts, attract, MIRROR, sound, ghost/stick/sensor.
- Host tests (`zig build test`): surface spread maths and upscale, cosine
  palettes, field weights (sum to one, interpolate the centres, smooth
  bump), noise (range, tiling, sampling), ghost and stick sources (the
  ghost lights every cell and punches once per loop; B + stick moves a
  hand whose field follows it and hands back), uniforms (glide, punch,
  flash, kick), app (programs, params, palettes, Start/Select on release,
  every button ignored while Start+Select are held, B panel and stick,
  attract after 30 s held off by a hand or a button), and the whole
  pipeline per program (varied, moving, reacts to a hand, deterministic).
- badge-bench, calibrated, busy ms worst / mean. Per program: pinned with
  `--poke start_program=N --frames 960 --script
  carts/snouty-shader/tools/scripts/bench_program.json` (one 16 s ghost
  routine with its punch, then the B panel and stick moves). The
  `-Dtof-fake=true` build runs the driver against its model and
  busy-waits each transfer's wire time, so it includes the real sensor's
  bus cost (up to ~3 ms on a frame that reads a result).

  | Program | normal worst / mean | tof-fake worst / mean |
  |---|---|---|
  | INK | 7.50 / 5.74 | 10.23 / 6.51 |
  | RIPPLE | 8.61 / 6.97 | 11.34 / 7.64 |
  | LAVA | 6.40 / 4.69 | 9.00 / 5.47 |
  | ECHO | 6.55 / 4.83 | 9.28 / 5.53 |
  | CELLS | 9.85 / 7.07 | 11.76 / 7.63 |
  | KALEIDO | 4.92 / 3.26 | 7.65 / 4.03 |

  Tour (`badge-bench/carts/snouty-shader.toml`, 3600 frames, every
  program, stick and punches; normal ELF sha256 `4b189135fea5`, fake
  `ae06e5b028f0`): normal worst 10.44 (frame 2653, CELLS with the stick
  hand) mean 5.51; tof-fake worst 11.31 mean 6.13; 0 frames over 16.7 ms;
  a program switch costs at most 6.6 ms (KALEIDO's tables). Hot: CELLS
  and RIPPLE render ~15 % each, tof_synth.cell_hit (ghost and stick field)
  14 %, INK 11 %. Fixes on the way: RIPPLE emitter-outer per column (10.5
  -> 8.1 ms), CELLS seeds sorted by column distance with an early out
  (13.1 -> 8.2), KALEIDO's tables from one quadrant (switch 16.1 -> 6.6).
- RAM: .text 108 KB + .data 6 KB + .bss 108 KB = 222 KB of the 307 KB
  window (32 KB of it stack). ECHO's frame buffers, KALEIDO's tables and
  RIPPLE's distances share one 40 KB arena, rebuilt on `enter`.
- `zig build`, `zig build test`, `zig build check-float` green; preview
  GIF `docs/preview_tour.gif`.

## Deferred decisions (defaults taken; Adrian may flip any)

1. The programs: INK, RIPPLE, LAVA, ECHO, CELLS, KALEIDO (all six
   suggested ones; the kaleidoscope and the tunnel are one program).
2. Every program renders 80x64 and a bilinear 2x upscale fills the
   screen (smooth, not blocky); none needed full resolution or 30 fps.
3. The stick moves the virtual hand only while B is held (B + stick, B + A
   punches): plain Left/Right/Up/Down/A are program, parameter and
   palette, so steering lives under B with the inputs panel. Holding B
   alone never takes over from the ghost or the sensor.
4. Start toggles sound and Select toggles MIRROR, both on release and
   only if the other button never joined the hold, so the Start+Select
   chord never flips either. Select was unbound, so MIRROR displaces
   nothing. MIRROR flips flip_x relative to snouty-morph's default
   (`.{ .flip_x = true }`) and restarts the estimator's background.
5. Attract: 30 s with no sensed hand and no button moves to the next
   program, then every 30 s; the ghost never counts as play, and buttons
   pressed under the Start+Select chord do not count either.
6. Each program keeps its own palette and parameter (0..8, default 4)
   while the cart runs; nothing is saved.
7. Field cell value = presence * (0.35 + 0.65 * nearness), gliding 0.3
   per tick toward the newest 30 Hz frame; Catmull-Rom through the cell
   centres with the edge cells repeated. Lateral effects use the pose
   centroid (x, y) or this field, never the nearest zone.
8. Punch: snouty-morph's threshold (fast z velocity under -900 mm/s,
   30-tick cooldown); flash peak 0.8 decaying 0.88 per tick; palette kick
   1/3 turn.
9. LAVA: the field only adds lava above max(100, 80 % of its mean), so a
   big hand covering every zone warms the background instead of flooding
   it; hot cores fold back into the bands instead of going flat.
10. ECHO injects the field's contour lines (running outward), not the
   filled field, which washed the screen out under a big hand.
11. Sound: a drone (root per program, pitch up with nearness, level with
   the field), a thump on a punch, a blip on a program change; boots
   silent. Not heard on hardware.
12. The GIF is 1x (5 MB); 2x would be ~4 times that.
