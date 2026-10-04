# Snouty Pipes: cart spec

Status: M0-M3 built 2026-10-04; Adrian took every section 12 default and
approved M3 ("Build it - just execute the whole plan"). Later additions
(B nametag with coin-flipping Iris marks) and M3's as-built changes are in
PLAN.md.

Reference: Windows NT/98/XP "3D Pipes" screensaver, plus the three.js
recreation at https://github.com/xlostincode/three-d-pipes (MIT, ~900 lines
of TypeScript: grid random walk in `src/pipe.ts`, three directional lights,
cylinders plus ball joints, orbit camera). We reuse its generator rules, not
its code: it leans on three.js for everything visual.

## 1. One paragraph

Shiny coloured pipes grow through an invisible 3D grid one segment at a
time, turning at random, never crossing each other. When they get stuck a
new pipe starts somewhere else. When the box is full enough the screen
dissolves and a new set starts from another camera angle. Every so often a
joint is a Utah teapot. The camera never moves while pipes grow, so the cart
draws **only the new piece** each frame and leaves the old pixels where they
are. That is what makes this cheap on the badge: a frame costs about one
pipe segment, not the whole scene.

## 2. Hardware facts the design leans on

- RP2354B Core 1, Cortex-M33 150 MHz, single-precision FPU. 60 fps budget
  2.5 M cycles, headroom rule: worst calibrated badge-bench frame <= 12 ms.
- 160x128 RGB565, column-major `cart.framebuffer[x][y]`.
- The OS default double buffer mode is `.copy_forward`
  (`sycl-badge/src/os/cart/api.zig:188`): the back buffer is copied forward
  on present, so pixels drawn last frame are still there, and only the
  dirty rect goes to the LCD. The cart calls `set_double_buffer_mode(
  .copy_forward)` explicitly and `mark_dirty_rect` around every write.
  Missing a `mark_dirty_rect` shows nothing on hardware while the simulator
  looks fine (the 2026-10-03 emulator scrub bug), so `badge-bench --lcd` is
  part of every gate.
- RAM cart only (no XIP). Needs are tiny: section 10.
- No audio, neopixels off (repo policy).

## 3. World and generator

- Grid of cells, default 12 x 10 x 12 (x, y, z). The reference uses 25^3,
  which on 160x128 makes pipes 2 px wide; fewer, fatter cells read better.
  `-Dgrid` keeps it one switch away.
- Occupancy: one bit per cell (1,440 bits).
- Each pipe starts at a random free cell with a random axis direction. Each
  step: keep going straight with probability `1 - turn` (default turn 0.25,
  same as the reference) if the next cell is free and inside the box,
  otherwise try the 6 directions in random order. No free neighbour = the
  pipe dies. Port of `createPipe` minus the string-keyed set.
- Up to 3 pipes grow at once (`-Dpipes`). A dead pipe is replaced by a new
  one after a short pause. Pipe colour from a 16-entry palette of saturated
  hues, never the same as a living neighbour's.
- Scene ends when 45% of cells are filled, or 6 spawn attempts in a row find
  no room, or 75 s pass. Then: dissolve (section 5), clear, new camera, go.
- Deterministic from a seed: badge build mixes `micros_since_boot` like the
  maze does (cart.rand() is 0 on RP2350), simulator and tests use fixed
  seeds.

## 4. Rendering

No triangle meshes for the pipes. Each primitive is drawn by casting a ray
per pixel inside its screen bounding box and solving the intersection
analytically, so every pipe is a perfect smooth cylinder at any size.

- **Straight segment**: axis-aligned cylinder, radius 0.22 cell. Ray vs
  axis-aligned cylinder is a 2D circle quadratic plus an interval clip on
  the axis. A segment grows over 4 frames (default 15 segments/s per pipe),
  each frame drawing the next quarter of its length.
- **Ball joint**: sphere, radius 0.32 cell. Also caps the start and end of
  each pipe.
- **Elbow joint**: quarter torus (major radius 0.5 cell, minor 0.22). Ray
  vs torus is a quartic, so this one is sphere-traced against the torus SDF,
  at most 24 steps, only inside its bbox.
- **Teapot**: a low-poly Utah teapot (~240 triangles, tessellated on the host
  into a const table, no comptime work for the Mac) rasterized with a small
  z-tested triangle filler borrowed from the maze cart's `render/raster.zig`.
  Drawn once, so its cost doesn't matter.
- **Depth**: a u16 z buffer (40 KB), cleared with the screen. Analytic hits
  give exact depth, so joints and crossings intersect cleanly.
- **Shading**: per-pixel Phong from the analytic normal: ambient + two
  directional lights + one specular highlight, like the original's
  fixed-function look but smooth. Then a 4x4 ordered dither into RGB565,
  because shiny gradients band badly at 5-6 bits per channel.
- **Camera**: perspective, fixed per scene. Each scene picks one of 8 views
  (the 3 axis views with a slight tilt, plus 5 three-quarter views) framed
  so the box fills the screen.

### 4.1 Budget

New pixels per frame: 3 pipes x (quarter segment ~60 px + the odd joint
~150 px) gives about 500 px. At ~150 cycles per pixel (ray setup, quadratic,
sqrt, shade, dither, z test) that is ~75 k cycles, about 0.5 ms. An elbow
at 24 steps is the worst single item, ~200 k cycles. Clear and dissolve are
memsets spread over frames. Nothing here comes near 12 ms.

The one expensive thing is a **rebuild**: redrawing the whole scene from its
history after the camera moves (M2 orbit). About 600 primitives at ~150 px
each is ~13 M cycles, so a rebuild is spread across frames with a 10 ms per
frame cap and shown as a fast regrow, which looks intentional.

## 5. Screensaver loop

1. Boot: name strip "SNOUTY PIPES" with the Iris mark (`lib/iris_mark.zig`)
   for 2 s over the first scene.
2. Grow pipes until the scene ends (section 3).
3. Dissolve: a random-order 4x4 block wipe to black over 1 s (screen and z
   buffer). The original cleared in one go. Either is cheap, decision 5.
4. New seed, new camera view, back to 2.

## 6. Controls

Autopilot always runs. Buttons change it, and it never needs input.

Screensaver:

| Input | Action |
|---|---|
| A | New scene now (dissolve) |
| B | Nametag strip on/off ("ADRIAN HATCH" / "ANTITHESIS" beside the Iris mark, the boot strip's style; it stays through new scenes, orbits and speed changes) (M3; joint-style cycling left B; since then each scene picks mixed, elbows or balls at random) |
| Up / Down | Growth speed 1x / 2x / 4x / 8x |
| Left / Right | Orbit the camera 45 degrees; the same pipes regrow fast from the new angle (M2) |
| Start | Pause |
| Select | Steer mode (M3): dissolve into a run where one pipe is yours |
| Select + B | Debug overlay (fps, primitives, cells filled), only with `-Ddebug_overlay` |

Steer mode (M3; PLAN.md "Plan: M3"):

| Input | Action |
|---|---|
| Up / Down / Left / Right | Turn your (silver) pipe that way on screen at the next cell centre; held = keeps turning that way when it can; reversals are ignored |
| A / B | Dive into / come out of the screen |
| Start | Pause |
| Select | Back to the screensaver (dissolve) |
| A (game-over card) | Play again |

The boot strip reads "SNOUTY PIPES" over "SELECT: STEER" and shows for
the first 2 s of every screensaver scene; the Iris mark on it (and on the
nametag) flips like a coin 45 ticks after the strip appears and every 5 s
after that.

Start+Select and joystick click belong to the OS and are never bound; while
Start and Select are both held the cart reacts to neither (newer firmware
opens its settings box over the running cart).

## 7. Fidelity notes

- Like the original: grid walk, multiple pipes, mixed elbow/ball joints,
  teapot easter egg, full-screen restart with a new view.
- Different: smooth per-pixel shading instead of Gouraud, a coarser grid,
  no textured-pipe mode, no "flex" (spline) pipes. Textures could come later
  if wanted (decision 7).
- Teapot odds: the original only showed teapots with mixed joints, rarely.
  Default here: 1 joint in 300 in mixed mode, at most one per scene.

## 8. Architecture

`carts/snouty-pipes/`, same layout as the maze cart:

- `cart/src/main.zig`: `start`/`update`, wasm shims, debug exports.
- `cart/src/grid.zig`: occupancy, generator, pipe list, history ring.
- `cart/src/director.zig`: scene state machine (boot, grow, dissolve,
  rebuild, pause), spawn/death, joint style, speed, seed.
- `cart/src/camera.zig`: views, projection, ray per pixel, bbox projection.
- `cart/src/render/trace.zig`: cylinder, sphere, torus intersection.
- `cart/src/render/shade.zig`: Phong, palette, dither, RGB565.
- `cart/src/render/zbuf.zig`, `render/raster.zig` (teapot only),
  `render/overlay.zig` (name strip, debug text).
- `cart/src/host_tests.zig`: root for `zig build test`.
- `tools/`: `gen_teapot.py` (host tessellation), `check_golden.mjs`,
  `check_cycle.mjs`. Shared `../../tools/preview.mjs`, `make_gif.py`,
  `check_float.mjs`.

## 9. Code reuse

- From the maze cart, copied (not shared, so the tuned maze stays
  untouched): `math.zig`, `rng.zig`, `input.zig`, the triangle filler and
  overlay font.
- From the repo: root `build.zig` cart wiring, `lib/iris_mark.zig`,
  badge-bench poses, the headless preview and GIF tools.
- From the three.js reference: the walk rules and the turn probability.

## 10. Memory budget

| Item | Size |
|---|---|
| z buffer u16 160x128 | 40,960 B |
| Occupancy bits + pipe state | < 1 KB |
| History ring (primitive id, cell, dir, colour, 4 B each, 2,048 entries) | 8 KB |
| Teapot mesh table | ~4 KB |
| .text estimate | < 50 KB |

Far inside the ~274 KB RAM cart window.

## 11. Verification

- Host tests: generator never overlaps or leaves the box (10k seeded
  steps); same seed gives the same history; intersection functions against
  brute-force sampling; every framebuffer write lies inside the marked dirty
  rect (diff the buffer before and after each primitive).
- Goldens: fixed seeds at fixed tick counts through `preview.mjs`.
- `zig build check-float`.
- badge-bench, calibrated: worst frame <= 12 ms across seeds 1..10 and a
  forced-teapot, forced-elbow-storm and rebuild script; plus `--lcd` so the
  dirty rects are proven on the modelled LCD.
- Review GIF per milestone in `docs/`.

## 12. Decisions (defaults in bold, built unless Adrian says otherwise)

1. Name: **"Snouty Pipes"**, `carts/snouty-pipes`.
2. Grid: **12 x 10 x 12**, fatter pipes, vs the reference's 25^3.
3. Concurrent pipes: **3**.
4. Joint default: **mixed** (elbows, balls now and then), like the original.
   Since 2026-10-04 (Adrian): a random style per scene (mixed, elbows,
   balls), like the original's "Cycle".
5. Scene end: **block dissolve over 1 s** vs the original's instant clear.
6. Teapot: **yes, Utah teapot, 1 in 300 joints**. Snouty-themed easter egg
   (Iris mark or a Snouty head at a joint) as a second, rarer egg: **no for
   v1**.
7. Textured pipes: **no**.
8. Attendee feature beyond the screensaver: **M3 "steer" mode as a
   proposal, not built until Adrian says go** (section 13).

## 13. Milestones

- **M0 scaffold** (solo): cart directory, build wiring, module stubs with
  the interfaces above, one shaded cylinder and one sphere on screen in the
  simulator, host test root, preview works. Tag `snouty-pipes/m0`.
- **M1 screensaver** (three Opus tracks):
  - A render: cylinder, sphere, torus tracers, Phong + dither, z buffer,
    dirty rects.
  - B world: generator, director (spawn, death, scene end, dissolve),
    camera views, joint styles, seed.
  - C tools: goldens, `check_cycle.mjs` badge-bench scripts, GIF, docs.
  Gate: GIF, host tests, check-float, bench worst <= 12 ms and `--lcd`
  clean. Tag `snouty-pipes/m1`, merge to main and push (badge-ready).
- **M2 controls and extras**: teapot, orbit with progressive rebuild, speed,
  joint cycling, pause, name strip. Same gate, tag, merge.
- **M3 steer mode** (approved and built 2026-10-04; PLAN.md has the
  contract and what changed in practice): one pipe is yours. The joystick turns it on
  screen (up/down/left/right), A and B dive into or out of the screen; the
  others grow on autopilot. Hitting a pipe or the wall ends the run, score =
  segments. Snouty twist: on a crash, time rewinds a few segments (the
  history ring already holds everything; rewind = rebuild minus the tail)
  and you get one retry per run. Only after Adrian says yes.
