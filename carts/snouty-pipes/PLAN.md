# Snouty Pipes: plan

SPEC.md is the design. This file is the contract between the parallel tracks
of the current milestone, and the status log.

Adrian, 2026-10-04: "Build it - just execute the whole plan. Get a build
out, and then keep going through steer mode." So every SPEC section 12
default stands, M3 steer mode is approved, and each milestone merges to main
as soon as its gate is green.

## Plan: M1 (screensaver)

M0 (scaffold, done by the lead) left compiling stubs with the interfaces
below. Three Opus tracks work in this worktree at the same time, each in its
own files. **Agents never commit**; the lead integrates and commits.
Touching another track's file: only the lines named here, and say so in the
hand-off.

Build and test from the repository root (`/home/exedev/snouty-badge-pipes`):

```
export PATH="$HOME/.local/bin:$PATH"
zig build -Dcart=snouty-pipes          # zig-out/firmware/snouty-pipes.{uf2,elf}, zig-out/bin/snouty-pipes.wasm
zig build test -Dcart=snouty-pipes     # host tests (this cart + lib/)
zig build check-float -Dcart=snouty-pipes
```

### Shared interfaces (owned by the lead; change only by agreement)

- `grid.zig`: sizes `nx, ny, nz` (12, 10, 12), `Dir` (px nx py ny pz nz,
  none = 7), `Joint` (ball, elbow, teapot), `Prim` (one cell of one pipe in
  32 bits: x y z, din, dout, color u4, joint), `cell_center`, `Occupancy`.
  World units = cells; the grid box is centred on the origin.
- `camera.zig`: `Camera` (eye, right, up, fwd), `ray(x, y)` (component along
  fwd = 1, so hit t = view depth), `project`, `screen_rect(lo, hi)`,
  `view(index, orbit)` (8 framed views, orbit in eighths of a turn), `Rect`.
- `render/draw.zig`: `Renderer(S)` with `draw_cell(cam, prim, s0, s1)`,
  `clear_all()`, `clear_blocks(from, to)`, `block_count` (1280 4x4 blocks).
  `S.put(x, y, c: u16)` writes DisplayColor bits, `S.mark_dirty(Rect)`.
- `render/shade.zig`: `shade(color, n, d, x, y) u16`.
- `render/zbuf.zig`: `buf[x][y]` u16, `scale` depth units per world unit,
  `far` = 0xFFFF = empty, `clear()`.
- `director.zig`: `State` (boot 0, grow 1, dissolve 2, rebuild 3, numbers
  stable), `Cmd` (cell, clear_all, clear_blocks), `Input`, `reset(seed)`,
  `step(held, pressed)`, `commands()`, `commands_done()`, `cam`.
- `main.zig` runs: input -> `director.step` -> each `Cmd` through the
  renderer -> overlay -> `present_wasm`. Mode `.copy_forward`.

Cell geometry (all tracks): a cell's path runs from its entry face
`centre - din*0.5` to its exit face `centre + dout*0.5`. Pipe radius
`r_pipe = 0.22`, ball joint and caps radius `r_ball = 0.32`, elbow = quarter
torus, major radius 0.5, minor `r_pipe`, centred on `centre - din*0.5 +
dout*0.5`. Constants live in `draw.zig` (`pub const r_pipe`, `r_ball`).
Parameter s in [0, 1] runs along the path by arc length (straight: the
cylinder; ball turn: in-half, ball at s = 0.5, out-half; elbow: by angle;
start: ball at s = 0 then out-half; end: in-half then ball at s = 1).

### Track A: render (`render/draw.zig`, `render/trace.zig` new, `render/shade.zig`, `render/zbuf.zig`)

1. `trace.zig`: ray vs axis-aligned cylinder segment (2D circle quadratic +
   axial interval, front hit only), sphere, quarter torus (sphere tracing on
   the torus SDF intersected with the quarter's two half-spaces, from the
   ray's entry into the elbow's AABB, at most 24 steps, analytic normal).
   Each returns `?Hit { t, n }`. Host tests against brute-force sampling.
2. `draw.zig`: `draw_cell` for straight, start, end, ball turn, elbow turn,
   with partial s ranges; a teapot-joint cell draws its two half cylinders
   and calls `teapot.draw` (Track C's `render/teapot.zig`, interface below)
   at the centre. Per primitive: `camera.screen_rect` of its world AABB, a
   ray per pixel, z test, shade, `S.put`, one `S.mark_dirty` per primitive.
   Consecutive partial ranges must end as the same image as one 0..1 call
   (host test: draw in 4 slices vs at once into two array surfaces; allow a
   handful of differing pixels at slice seams if the tube interior shows,
   but aim for identical).
3. `shade.zig`: 16-entry palette of saturated hues (the reference's
   COLOR_MAP has good ones), ambient + two directional lights + one
   specular highlight, gamma-ish response, 4x4 Bayer dither to RGB565 (r in
   the low 5 bits, as `cart.DisplayColor`). Background black.
4. `clear_blocks`: fixed permutation of the 1280 blocks (e.g. `i * 797 mod
   1280`), clears pixels to black and z to far, marks each block dirty (or
   the union).
5. Cost: aim for <= 200 cycles per covered pixel; f32 only, `@sqrt` ok, no
   f64 anywhere (check-float). Precompute per-primitive constants outside
   the pixel loop.
6. Host tests in `trace.zig` and `draw.zig` (add `render/trace.zig` to
   `host_tests.zig`): intersections, slices vs whole, every put inside the
   marked rect.

### Track B: world (`grid.zig` generator part, `director.zig`, `main.zig`, `render/overlay.zig` new)

1. `grid.zig`: append a `Pipe` walker (port of the reference `createPipe`:
   straight with probability 1 - turn, turn = 0.25, else the 6 directions
   in random order; dead when no free in-box neighbour). Keep the lead's
   types unchanged.
2. `director.zig`: up to 3 concurrent pipes, each grows one cell per 4 ticks
   (15 cells/s), drawn one cell behind its head (a cell's exit is known
   only when the next step is taken; the dying head is flushed as an end
   cell). Each tick emits the next quarter (s range) of each pipe's pending
   cell. Respawn after 20 ticks at a random free cell, colour not used by
   a living pipe. Joint style mixed (elbow normally, 1 in 4 turns a ball);
   the teapot (1 turn in 300 in mixed mode, at most one per scene) sets
   `joint = .teapot`. Scene end at 45% filled, or 6 failed spawn attempts in
   a row, or 75 s: dissolve over 60 ticks (`clear_blocks` slices), then new
   seed-derived view (never the same view twice running) and grow again.
   History ring (2048 Prims, in draw order) for M2 rebuild and M3 rewind.
   Boot state shows the name strip for 120 ticks while the first pipes grow.
3. `render/overlay.zig`: the name strip "SNOUTY PIPES" + Iris mark
   (`@import("iris")`, lib/iris_mark.zig) at the bottom for the boot
   state, and the `-Ddebug_overlay` timing text (Select toggles it only in
   such builds). Overlays sit on a persistent picture, so save the pixels
   under the overlay before drawing it and restore them first thing next
   frame (and redraw nothing else there). Order per frame: restore ->
   director commands -> save -> draw overlay. It may use `cart.text`/`rect`
   (they mark dirty rects themselves).
4. `main.zig` debug exports (Track C's checks depend on these names):
   `debug_tick`, `debug_state`, `debug_render_us`, `debug_pixel_checksum`,
   `debug_set_seed(s)` (exist), plus `debug_scene` (scenes started, 1 after
   boot), `debug_filled` (cells filled this scene), `debug_alive` (living
   pipes), `debug_pipes` (pipes started this scene), `debug_view` (view
   index), `debug_teapots` (teapots drawn since boot), `debug_force_teapot`
   (next turn is a teapot), `debug_name_strip` (1 while shown),
   `debug_cmds` (commands run last tick).
5. Host tests: the walk never overlaps or leaves the box over 10k seeded
   steps; same seed -> same history; scene end and dissolve reach grow
   again; teapot cap holds.

### Track C: tools, teapot, docs (`tools/`, `tests/`, `docs/`, `CLAUDE.md`, `render/teapot.zig` + `render/teapot_mesh.zig` new, `badge-bench/carts/snouty-pipes.toml`)

1. `tools/gen_teapot.py`: tessellate the Utah teapot (Newell's 32 Bezier
   patches; widely published public data) into ~240 triangles, write
   `cart/src/render/teapot_mesh.zig` (committed, generated: vertices as
   `[3]f32` arrays, never `@Vector` in tables; per-vertex normals; u16
   index triples). Light on comptime (Adrian's Mac).
2. `render/teapot.zig`: `pub fn draw(comptime S: type, cam: *const
   camera.Camera, centre: math.Vec3, up: grid.Dir, front: grid.Dir, color:
   u4, size: f32) void` (size = teapot height in cells; ~0.6). Project,
   back-face cull, rasterize each triangle with a z test against `zbuf`,
   per-pixel shade via `shade.shade` with the interpolated normal, `S.put`,
   one `S.mark_dirty` for the whole teapot. You may copy the triangle/
   polygon fill from `carts/snouty-maze/cart/src/render/raster.zig`. Host
   test: draws something, stays inside its rect.
3. `tools/check_cycle.mjs` (model: the maze cart's): headless runs through
   `../../tools/preview.mjs` asserting on the debug exports above: boot ->
   grow; a scene ends and the next starts (debug_scene >= 2 within the
   75 s cap + dissolve); filled never exceeds the cell count; a forced
   teapot is drawn; name strip gone after boot. `tools/check_golden.mjs` +
   `tests/golden/` (a few seeds at fixed ticks; start from the maze's
   script). `tools/check.sh`: the whole gate (build, test, check-float,
   goldens, cycle, badge-bench calibrated + `--lcd`).
4. badge-bench: `badge-bench/carts/snouty-pipes.toml` (frames covering boot,
   growth and one dissolve; scripts under `tools/scripts/`). Find out how
   `--lcd` is used (`badge-bench/tests/test_lcd_scrub.sh`) and add an LCD
   check that the modelled LCD matches the framebuffer at the end of a run.
5. `docs/RUNNING.md` (how to pull, build, run in the simulator, flash),
   `CLAUDE.md` for the cart (model: the maze's), review GIF
   `docs/preview_m1.gif` once A and B land (`../../tools/make_gif.py`).

## Plan: M3 (steer mode)

Adrian approved M3 on 2026-10-04 ("keep going through steer mode"). One
Opus agent builds it (it lives almost entirely in `director.zig`, so
parallel tracks would collide); the lead reviews, runs the gate, merges.

- **Enter/leave**: Select toggles steer mode from any screensaver state
  (the `-Ddebug_overlay` Select toggle moves to Select+B in such builds).
  The boot name strip gets a second line or alternates with
  "SELECT: STEER" so people find it; also shown on the game-over card.
- **Run**: dissolve, then a three-quarter view (fixed for the run, no
  orbit), 2 autopilot pipes plus the player's pipe in a fixed colour that
  the autopilot avoids. The player's pipe moves by itself, starting at 3
  cells/s and +1 cell/s every 15 cells up to 8.
- **Controls, screen-relative**: the grid axis most aligned with the
  camera's `fwd` is depth (A = into the screen, B = out of it); of the
  other two, the one most aligned with `right` is Left/Right, the last is
  Up/Down (sign from the projection). A press sets the next turn (buffered
  until the next cell); a reversal is ignored. Joystick held = repeat.
- **No lag**: the walker draws one cell behind; the player's head must not.
  Draw the head cell's in-half as soon as the pipe enters it, and the rest
  once the exit is known (player turns use ball joints, so the in-half is
  always a straight piece).
- **Head marker**: a small blinking marker at the head's projected position
  through the overlay save/restore, so the head can be found among pipes.
- **Crash**: moving into an occupied cell or the wall. The first crash of a
  run rewinds (the Snouty twist): restore a snapshot from 6 player cells
  ago (occupancy, slots, rng, history count; a small ring of snapshots, one
  per player cell), clear, and regrow the scene from the history ring as
  the visible rewind, then play on. The second crash ends the run.
- **HUD**: score (player cells) and the rewind token, top left, through the
  overlay save/restore. Game over: a card with SCORE / BEST (session best,
  no flash save), "A: AGAIN  SELECT: EXIT".
- **States** (stable numbers): steer = 4, rewind = 5, game_over = 6.
- **Exports**: `debug_steer` (1 in steer states), `debug_score`,
  `debug_best`, `debug_rewinds_left`, `debug_crashes`, `debug_head_x/y/z`,
  `debug_steer_map` (packed axis map, for tests).
- **Gate**: host tests (mapping is a permutation of the six directions for
  every view, rewind restores the exact snapshot, crash rules, score),
  check_cycle runs for steer (enter, survive a scripted path, crash ->
  rewind -> crash -> game over, A again, Select out), a golden or two,
  badge-bench script with a crash + rewind (worst <= 12 ms) and `--lcd`
  clean, `docs/preview_m3.gif`. Tag `snouty-pipes/m3`, merge, push.

## Status

- 2026-10-04 M0 scaffold: build wiring, root build.zig entry, interfaces
  above as compiling stubs, `camera.zig` done with tests. The SPEC's "one
  cylinder on screen" moved into M1 Track A.
- 2026-10-04 M1 + M2 done (three Opus tracks, lead integration). Track B
  finished M1 early and built every M2 control in the same pass (orbit with
  a 16-cells-per-tick rebuild from the history ring, speed 1x..8x, joint
  style cycling, A = new scene, Start = pause), and Track A wired Track C's
  teapot, so M2 needed no second round. Lead tweaks after the first
  frames: r_pipe 0.18 -> 0.22, r_ball 0.27 -> 0.32 (pipes were ~3 px
  wide), camera overscan 1.08 -> 1.25 (the box filled ~60% of the screen),
  teapot 0.6 -> 1.3 cells (it read as a bump on the pipe), and pick_color
  avoids hue-wheel neighbours of living pipes. Gate `tools/check.sh`: PASS
  (39+ host tests, check-float, teapot mesh fresh, 8 goldens, check_cycle
  A..J, LCD == framebuffer on 72 frames). Calibrated badge-bench worst
  2.47 ms (seeds 1..10, 720 frames each); orbit rebuild + 8x speed
  (`tools/scripts/bench_orbit.json`, 1000 frames) worst 4.86 ms. Review
  GIFs `docs/preview_m1.gif` (boot, growth, dissolve, scene 2) and
  `docs/preview_m2.gif` (orbit regrow, speed-up). Next: M3 steer mode.
