# Snouty Shader: design

A Shadertoy-style gallery of abstract real-time "shaders" for the SYCL
badge, played by hand over the TMF8820 time-of-flight breakout on the
Qwiic port (docs/TOF.md). Each program is a full-screen per-pixel
function of (x, y, time, uniforms); the uniforms come from the sensor.
The hand reaches into the image: nearer is stronger, moving is flow, a
punch (a fast jab toward the sensor) is a shockwave, a flash and a
palette jump. With no hand in view (or no sensor: simulator, host,
unplugged) nothing fakes one: the field stays empty and each program
runs on its own clock, so any reaction on screen is a real hand.

## 1. Uniforms (`cart/src/uniforms.zig`, `field.zig`)

- **The field.** Per screen cell (3x3, after the zone orientation):
  presence 0..1 (lib/tof_pose's background-subtracted coverage) and
  nearness 0..1 (the zone's distance, 420 mm = 0 .. 90 mm = 1). Each cell
  value `presence * (0.35 + 0.65 * nearness)` glides toward the newest
  frame (the sensor is 30 Hz, the cart 60), then a separable Catmull-Rom
  upsample turns the 3x3 values into a smooth 80x64 field `F` (0..255).
- **The pose.** lib/tof_pose: x, y (-1..1, +-1 at the outer cell
  centres), z (0 far .. 1 near), pitch, roll, yaw, velocities, swirl.
- **Events.** A punch (fast z velocity toward the sensor) sets the punch
  point and age, a white flash (decays over ~0.4 s) and a palette kick
  (+1/3 turn of the cosine palette, eased in).
- `t` (ticks, 1/60 s), the program's palette and its Up/Down parameter.

## 2. Programs (Left/Right)

All render an 80x64 RGB565 surface (half resolution) that a bilinear 2x
upscale writes to the 160x128 framebuffer: smooth gradients at a quarter
of the per-pixel cost. Integer and fixed point per pixel, f32 per frame.

1. **INK**: two octaves of a tileable gradient-noise texture, sampled
   through a warp (two more noise lookups on a 4-pixel grid, bilinearly
   interpolated). The field's gradient bends the warp into a gravity
   well around the hand, its curl (swirl, yaw speed) into a vortex, hand
   velocity smears it; the hand glows through the palette. Punch: a
   radial ring of displacement. Param: warp strength.
2. **RIPPLE**: nine ring-wave emitters at the zone centres plus one at the
   hand. Each zone's presence sets its emitter's amplitude, its nearness
   the wavelength and speed: a moiré you play with your fingers. Punch:
   every emitter's phase jumps and the hand emitter rings loud. Param:
   wavelength.
3. **LAVA**: seven metaballs (polynomial falloff, no divide) on Lissajous
   paths, pulled toward the hand when it is there and blown apart by a
   punch; the field itself is added as one more blob, so the hand is lava.
   Palette-cycled iso-bands with a hot rim. Param: speed.
4. **ECHO**: Milkdrop-style feedback. The previous frame (RGB888, 80x64)
   is resampled bilinearly through a zoom (z), rotation (yaw, roll, swirl)
   and drift (x, y) about the hand, with a sine warp, decayed, and the
   field injects colour that cycles through the palette; three orbiting
   sparks keep it going without a hand; a punch draws an expanding ring.
   Param: trail length.
5. **CELLS**: Voronoi with sixteen seeds on springs, pulled into the hand
   (gravity well), dragged by its motion and scattered by a punch; cells
   under the hand light up; dark edges from the distance gap. Param:
   speed.
6. **KALEIDO**: a tunnel through angle/depth tables, its angle folded into
   mirrored segments (3..10, yaw adds segments), twisted by roll, centred
   on the hand, flown faster as the hand comes closer. Punch: a speed
   burst. Param: segments.

Palettes: Inigo Quilez's cosine palettes (`a + b cos(2 pi (c t + d))`),
eight of them; A cycles; each program keeps its own choice. Every program
builds its 256-entry LUT per frame (cheap) so cycling, flash and kick are
free per pixel.

## 3. Controls

| Input | Does |
|---|---|
| hand over the sensor | the uniforms: field, pose, punches |
| Left / Right | previous / next program |
| Up / Down | the program's parameter (0..8) |
| A | next palette |
| B (hold) | inputs panel: program, palette, parameter, source, the 3x3 field as a grid, pose numbers |
| B + stick | steer the virtual hand (STICK source) |
| B + A | punch with the virtual hand |
| Select (on release) | MIRROR: flip the sensor's left-right (the breakout dangles on its cable) |
| Start (on release) | sound on / off (boots off) |
| Start + Select | the OS's; the cart ignores every button while both are held |

Never the joystick click. Start and Select act on release, and only if
the other was not pressed during the hold, so the exit chord never
toggles anything. Lateral effects come from the pose's coverage-weighted
centroid and the smooth field, never from the nearest zone (which jumps
between fingertips, knuckles and forearm over a flat hand), and they are
broad: the 8820 has three zones across.

Attract: no sensed hand and no button for 30 s advances to the next
program (and again every 30 s); any button or a sensed hand resets it.

## 4. Sources (`cart/src/hand.zig`, from snouty-morph)

Priority: a sensed hand, then recent stick input (B + stick; 4 s), then
the sensor with no hand in view (SENSOR, an empty field), then none (NO
SENSOR). The field only lights while the pose estimator reports a hand,
so a stray reading it rejects lights nothing. The stick hand's field
comes from tof_synth's per-cell coverage of a hand at the stick
position. (M1 had a ghost: a scripted attract hand whenever no hand was
in view. Removed 2026-10-06, Adrian: it made the sensor hard to demo,
since the image moved with nothing in front of it.)

## 5. Sound (optional, boots silent)

Seeded from `build_options.sound`; Start toggles. Badge builds stream
through lib/tone_stream.zig (never `cart.tone2`): a drone whose pitch
follows the hand's distance over a root per program and whose level
follows the field, a low thump on a punch, a blip on a program change.
The wasm build drives the simulator's `tone` import as snouty-morph does.

## 6. Budget

16.7 ms per update at 60 fps. Fixed per frame: pose and field (~0.5 ms),
the 2x upscale (~1 ms); each program a few ms at 80x64 (5120 pixels, ~250
cycles per pixel at most). Tables at start(): noise texture 16 KB,
ripple distances 10 KB, tunnel angle/depth 40 KB, feedback buffers 40 KB.
