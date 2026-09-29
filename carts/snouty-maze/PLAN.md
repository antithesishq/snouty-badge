# Plan: M0 scaffold and M1 "Rasterizer on hardware"

Companion to `SPEC.md`. This file is the contract between the parallel
tracks; when it and the spec disagree, this file wins for M1 and the spec is
updated afterwards.

## M0 Scaffold (done 2026-09-26)

Toolchain copied from `snouty-reflections` (build options, `check-float`,
`input.zig`, `math.zig`, wasm shims, `preview.mjs`, `serve-cart.mjs`,
`make_gif.py`) and `snouty-bugs` (PNG -> `gfx` module asset pipeline,
`convert_gfx.zig`, `packed_int_array.zig`). `ReleaseFast`. New: `rng.zig`,
`maze.zig` (types + boundary-only stub), `camera.zig` (basis convention,
tested), `render/{clip,raster,textures,scene,overlay}.zig` stubs with the
interfaces below, `main.zig` with the debug exports, crude placeholder PNGs
at manifest sizes, `zig build test` via `cart/src/host_tests.zig`.
Verified: uf2/elf/wasm build (incremental 2 s, clean ~4 min), `.text` 12 KB,
`.bss` 41 KB (the z buffer), `check_float` PASS, preview renders the stub.

## M1 goal

Fly through a real maze on hardware. Perfect maze with merged wall runs,
textured walls with orientation shading, textured floor and ceiling, wall
tops and the finish tile, z buffer, near clipping, full yaw/pitch/roll
camera with debug fly controls, timing overlay, golden-image tests. Adrian
flashes it and reports fps and `render_us` at the two SPEC section 16 poses.

## Tracks

Each track owns the files listed and touches nothing else. A needed change
to another track's file goes into the final report as a request, with the
exact diff. `math.zig`, `rng.zig`, `input.zig`, `build.zig` and this file
are frozen for M1 (private helpers go in the track's own files).

| Track | Owner | Files |
|-------|-------|-------|
| A rasterizer | Opus agent | `cart/src/render/clip.zig`, `raster.zig`, `textures.zig`, `scene.zig` |
| B world and camera | Opus agent | `cart/src/maze.zig`, `camera.zig`, `main.zig`, `render/overlay.zig` |
| C tools and docs | Opus agent | `tools/prepare_assets.py`, `tools/preview.mjs`, `tools/check_golden.mjs`, `tools/scripts/*.json`, `tests/golden/poses.json`, `assets/gen/*.png`, `docs/RUNNING.md`, `docs/placeholders.png` |

Integration (me): build, generate the golden PNGs, run `check_golden`,
GIF from the fly script, `size -A`, `check-float`, tag `m1`, hand-off note.

## Fixed conventions (already in the M0 code; do not change)

**World.** Units are cells. x east, z south, y up. Cell `(cx, cz)` spans
`[cx, cx+1) x [cz, cz+1)`. Walls: height 1.0, half thickness
`scene.wall_half = 0.05`. Floor y = 0, ceiling y = 1, eye height 0.5.
`maze.Dir`: n = -z, e = +x, s = +z, w = -x. `maze.Cell` bits are
"wall present". `maze.Run { x, z, len, axis }` is a panel from grid vertex
`(x, z)` running `len` cells along `axis`; the renderer extends it by
`wall_half` at both ends and gives it `+-wall_half` thickness so
perpendicular runs meet cleanly at corners.

**Camera.** `camera.Camera { pos, yaw, pitch, roll }`, angles `math.Angle`
(u16, 65,536 per turn). yaw 0 faces north (-z), `deg(90)` faces east.
Positive pitch looks down; `deg(90)` is straight down. roll `deg(180)` is
upside down. `basis()` is the world-to-view rotation, view space +x right,
+y up, +z forward; `to_view(b, p) = b.apply(p - pos)`. Tested in
`camera.zig`.

**Projection.** `raster.focal = 123.2` (66 degree horizontal FOV),
`sx = 80 + focal * x / z`, `sy = 64 - focal * y / z`, near plane
`clip.near = 0.05`. Z buffer stores `u16(1/z * raster.z_scale)`,
`z_scale = 2048`, cleared to 0, test is greater-than.

**Textures.** 32x32, `textures.Texture { texels: *const [1024]u8, palette:
*const [16]Pixel }`, texels indexed `[(u << 5) | v]` (u along the wall or
world x, v vertical or world z). Track A may add fields but not remove
these.

## Interfaces

```zig
// render/raster.zig (Track A)
pub const Vertex = clip.Vertex;                   // { p: Vec3 (view space), u: f32, v: f32 } u, v in cells
pub const Fill = union(enum) { textured: *const Texture, flat: cart.Pixel, sprite: *const Texture };
pub fn begin_frame() void;                        // clears the z buffer
pub fn draw_polygon(verts: []const Vertex, fill: Fill) void;  // 3 or 4 verts, any winding, near clip inside

// render/textures.zig (Track A)
pub fn init() void;                               // unpack gfx sheets, build palettes
pub var wall_lit, wall_dark, floor, ceiling, finish: Texture;
pub var top_color: cart.Pixel;

// render/scene.zig (Track A)
pub fn draw(m: *const maze.Maze, cam: *const camera.Camera) void;  // whole maze, no actors

// maze.zig (Track B)
pub fn Maze.generate(m: *Maze, w: u8, h: u8, r: *rng.Xorshift) void;  // perfect maze, start, finish, runs
pub fn Maze.cell(m, x, z) Cell;  pub fn Maze.has_wall(m, x, z, dir) bool;

// camera.zig (Track B)
pub var cam: Camera;
pub fn reset(m: *const maze.Maze) void;           // start cell centre, eye height, facing the open side
pub fn debug_fly(f: Fly) void;                    // one tick of debug controls

// render/overlay.zig (Track B)
pub fn draw_debug(render_us: u32, fps_x10: u32) void;
```

`main.zig` (Track B) per update: `input.update` -> Select toggles the
overlay, Start resets the camera, A+B regenerates -> `camera.debug_fly` ->
`raster.begin_frame` -> clear to the background colour -> `scene.draw` ->
timing -> overlay -> `present_wasm` on wasm. Debug exports already wired:
`debug_tick`, `debug_state`, `debug_render_us`, `debug_pixel_checksum`,
`debug_set_camera(x, y, z, yaw_deg, pitch_deg, roll_deg)`,
`debug_set_seed(seed)`, `debug_cell_x`, `debug_cell_z`. Track B may add
exports; Track C relies on the ones listed.

## Track A: rasterizer details

- `clip.clip_near`: Sutherland-Hodgman against `z = near`, attributes
  interpolated linearly in view space. Host tests: fully in front, fully
  behind, one vertex behind (5 out), two behind (4 out), vertex exactly on
  the plane.
- `draw_polygon`: project, then iterate screen columns from the leftmost
  to the rightmost projected x (clamped to 0..159). For each column find
  the top and bottom edge crossings and the endpoint values of `1/z, u/z,
  v/z` (all linear in screen space). Fill the vertical span in segments of
  8 pixels: divide at segment ends, affine `u, v` inside, 16.16 fixed
  point, `& 31` wrap. Textured, flat and sprite variants; make the inner
  loops separate functions so each stays tight. Top-left style fill rule so
  shared edges neither crack nor double-draw.
- Guard band: projected coordinates clamped to `[-4096, 4096]` before
  `i32`; columns and rows clamped to the screen; never index outside the
  framebuffer or z buffer.
- `scene.draw`: floor and ceiling quads over the maze footprint (`u = x`,
  `v = z`, one repeat per cell), single-sided (floor faces up, ceiling
  faces down; cull in world space by comparing `cam.pos[1]` with the plane
  height). Wall runs as boxes: side faces culled in world space by sign
  (`+x` face visible iff `cam.pos[0] > face_x`), end caps likewise, top
  face only when `cam.pos[1] > 1`, flat `top_color`. x-axis runs use
  `wall_lit`, z-axis runs `wall_dark`. Finish tile: `textures.finish` quad
  over the finish cell at `y = 0.002`. Sort runs front to back by the
  squared distance from the camera to the run midpoint (insertion sort on
  a `u16` key array is fine at 300 runs) before submitting.
- Frustum reject before clipping: drop a polygon when all vertices are
  behind the near plane, or all have `x > z * 0.65 + slack`, etc. (the
  six view-space half-space tests; slack for the 0.05 thickness is not
  needed since a fully outside polygon is invisible anyway).
- `textures.init`: unpack `gfx.wall`, `gfx.floor`, `gfx.ceiling`,
  `gfx.finish` into `[1024]u8`; palettes to `Pixel` via `from_color`;
  `wall_dark` is the wall palette at about 70% brightness; `top_color` a
  mid grey. The sheets may still be the crude M0 placeholders when you
  start; Track C replaces the PNGs at the same sizes and names.
- Performance rules: `f32` only, no `f64`, no `@sin`/`std.math` at runtime
  (use `math.sin_angle`), hardware divide is fine but keep it to one per
  8-pixel segment, inner loops over `y` inside a column so stores are
  stride-1. `zig build check-float` must PASS.
- Report the worst-case polygon count and your own cycle estimate; the
  wasm `debug_render_us` is a fake (the harness has no timer).

## Track B: world and camera details

- `maze.generate`: iterative recursive backtracker on a stack in `.bss`
  (max 256 entries), carve by clearing the shared wall bits on both cells.
  Start `(0, 0)`. Finish = the cell with the largest BFS distance from the
  start (BFS queue of 256 in `.bss`). Runs: sweep every grid line, merge
  consecutive present wall segments along each line into one `Run`. Runs
  along x come from the n/s bits of the cells on each row line; runs along
  z from the e/w bits. Each wall segment must appear in exactly one run
  (host test). Host tests: perfect maze for seeds 0..99 (all reachable,
  `w*h - 1` passages, both 12x12 and 16x16); runs cover every segment once;
  finish differs from start; `Dir` helpers.
- `camera.reset`: start cell centre, eye height, yaw facing the start
  cell's open side (there is exactly one for a corner cell in a perfect
  maze unless it is a junction; if several, prefer north, east, south,
  west in that order).
- `camera.debug_fly` (SPEC section 3, M1 column): Up/Down move along the
  horizontal heading at 2 cells/s (1/30 cell per tick), Left/Right turn at
  90 degrees/s (`deg(1.5)` per tick), A held makes Up/Down pitch at 60
  degrees/s instead of moving, B held makes Up/Down move vertically at 1
  cell/s. No collision. Clamp `pos[1]` to `[0.1, 40]` and pitch to
  `[-90, 90]` degrees (pitch is a u16; keep a signed shadow or clamp via
  the sign of `sin_angle`).
- `main.zig`: the M0 skeleton is yours; keep the debug exports and the
  call order above. Add the A+B "new maze" as already sketched. The
  background colour behind everything is a dark sky `0x101018`; leave it.
- `overlay.draw_debug`: as stubbed (black box, white 8x8 text), plus the
  camera cell and heading (`x,z  N/E/S/W`) on a second line, so a photo of
  the badge says where the camera was.

## Track C: tools and docs details

- `tools/prepare_assets.py --placeholders`: the eight sheets of SPEC
  section 10 at exact sizes into `assets/gen/`, validated (size, cell grid,
  <= 15 opaque colours after RGB565 quantisation, 16 for opaque sheets,
  magenta key only where transparent, transparent sheets keep a 1 px empty
  border per cell). Model on `../snouty-bugs/tools/prepare_assets.py`
  (numpy + Pillow are installed). Make the bricks read as bricks at 4x
  magnification (they fill the screen when a wall is 0.5 cells away):
  2 rows of 4 bricks per 32 px with 1 px mortar, slight per-brick tint
  variation. `--contact docs/placeholders.png` tiles the sheets at 4x with
  labels. Overwrite the crude M0 PNGs.
- `tools/preview.mjs`: add `--pose x,y,z,yaw,pitch,roll` (floats; calls
  `debug_set_camera` after `start()` and before the first `update()`), and
  `--call NAME[:ARG]` for zero/one-integer-argument exports such as
  `debug_set_seed:7` (also after `start()`). Keep every existing option
  working. Update the usage header.
- `tools/check_golden.mjs [--update] [--tolerance N]`: reads
  `tests/golden/poses.json` (array of `{ name, seed, pose, frames }`),
  runs preview for each pose with `--frames 1` (or the given count) into
  `out/golden/<name>/`, compares the last frame with
  `tests/golden/<name>.png` exactly (default tolerance 0 differing pixels;
  print the count and the first differing coordinate), `--update`
  overwrites the goldens. Exit 3 on any FAIL. No npm dependencies (PNG via
  `node:zlib`, as `preview.mjs` does; you may import its encoder/decoder
  if you export them without changing behaviour).
- `tests/golden/poses.json`: at least these poses, seed 1, 12x12 maze:
  `start` (no pose), `near_wall` = `0.5,0.5,0.08,0,0,0` (the north wall
  face straddles the near plane), `ceiling_edge` = `0.5,1.0,0.5,0,45,0`,
  `overhead` = `6,13.5,6,0,90,0`, `rolled` = `0.5,0.5,0.5,90,0,180`,
  `outside_corner` = `-3,3,-3,135,35,0`, `overhead_16` = same as overhead
  with `--call debug_set_seed:1` after the maze size is 16 (add a
  `debug_set_size:16` export request to Track B if you want it; otherwise
  drop this pose and say so).
- `tools/scripts/m1_fly.json`: a 600-tick script that walks forward,
  turns, climbs with B+Up while pitching with A+Down, and ends at an
  overhead view, for the milestone GIF.
- `docs/RUNNING.md`: adapt `../snouty-bugs/docs/RUNNING.md` (repo names,
  the debug controls table, `zig build test`, `zig build check-float`,
  `check_golden.mjs`, flashing = copy the uf2 to the badge's USB drive,
  reading fps via the OS overlay on joystick click or our Select overlay).

## Done criteria for M1

1. `zig build`, `zig build test`, `zig build check-float` all clean; ELF
   `.text` under 120 KB, `.bss` under 100 KB.
2. `check_golden.mjs` PASS on all poses (goldens generated at integration
   and committed).
3. `docs/preview_m1.gif` from `m1_fly.json`.
4. Tag `m1`, hand-off note; Adrian flashes and reports fps and `render_us`
   at the `overhead` and `start` poses (SPEC section 16 table).

## M1 result (2026-09-26, tag `m1`)

All done criteria met on the simulator: build, `zig build test` (16 host
tests), `check-float` PASS, `.text` 35 KB, `.bss` 50 KB, seven goldens
committed and passing, `docs/preview_m1.gif` from `m1_fly.json`. Hardware
gate pending. Deviations from this plan, all kept:

- Finish tile is drawn before the floor (the 0.002 lift is below one z
  unit at overhead range, and the greater-than test keeps the first draw).
- Faces are shaded by facing direction (north/south lit, east/west dark),
  which equals "x-runs lit, z-runs dark" for long sides and makes end caps
  match the walls they are parallel to.
- Guard band clamps column ranges and span rows, not vertices (clamping a
  vertex bends the edge through it).
- Runs stay sorted between frames; per-polygon plane gradients give exact
  1/z, u/z, v/z without depending on the clipper. Segments are z-tested
  before the divide and skipped when fully hidden.
- Placeholder bricks are 4 courses of 2 in running bond (upright 8x16
  bricks did not read as bricks). `overhead_16` pose is `8,17.5,8,0,90,0`
  so the whole 16x16 maze fits. `near_wall` pose is `0.5,0.5,0.09,35,0,0`
  (the original put the face entirely behind the near plane).
- Track A's cycle estimate: overhead 12x12 ~4.9 ms, overhead 16x16 ~5.9 ms,
  start pose ~6.4 ms (pixel fill dominates). Both inside 16.7 ms on paper.
- Extra wasm exports: `debug_set_size`, `debug_finish_x/z`,
  `debug_run_count`, `debug_raster_*` counters.

# Plan: M2 "Screensaver loop" (+ M3 renderer pieces in parallel)

M2 makes the cart a screensaver: autopilot, finish sequence, maze swap,
name strip. Because the M3 actors need new renderer modules that touch no
M2 file, Track A builds them now. Integration and the M2 GIF are mine.

## Tracks

| Track | Owner | Files |
|-------|-------|-------|
| A2 actor renderer (M3 prep) | Opus agent | `cart/src/render/mesh.zig` (new), `render/sprite.zig` (new), `render/textures.zig`, `render/scene.zig` (debug hook only), `render/raster.zig` (sprite fill fixes only) |
| B2 autopilot and states | Opus agent | `cart/src/autopilot.zig` (new), `cart/src/camera.zig`, `cart/src/main.zig` |
| C2 overlay and harness | Opus agent | `cart/src/render/overlay.zig`, `tools/scripts/m2_*.json`, `tools/check_cycle.mjs` (new), `docs/RUNNING.md`, `tests/golden/poses.json` (additions only) |

Frozen: `math.zig`, `rng.zig`, `input.zig`, `maze.zig`, `render/clip.zig`,
`build.zig`, `tools/preview.mjs`, `tools/check_golden.mjs`.

## Controls in M2 (replaces SPEC section 3 for this milestone)

| Input | Autopilot states | Fly (debug) |
|-------|------------------|-------------|
| Select | Toggle debug overlay | same |
| Start | Toggle name strip permanently on/off | Reset camera to start cell |
| A | Skip to PAUSE (finish sequence) | + Up/Down: pitch |
| B + Select | Toggle fly mode | Toggle back to autopilot (resumes WALK from the nearest cell centre, heading = nearest quadrant) |
| Stick | ignored | walk / turn (M1 controls) |

B+Select is a debug chord removed in M4 when takeover lands.

## State machine (B2 owns; SPEC section 8 with these exact numbers)

```
WALK -> TURN -> WALK ...         autopilot
WALK at finish centre -> PAUSE   30 ticks
PAUSE -> RISE                    150 ticks
RISE -> OVERHEAD                 120 ticks; maze regenerated at tick 0 of OVERHEAD
OVERHEAD -> DESCEND              150 ticks
DESCEND -> WALK                  at the new start cell
FLY                              debug, entered/left by B+Select
```

- WALK: heading is a `maze.Dir`; move 1/30 cell per tick along it. Cell
  centre reached when the coordinate along the heading crosses `c + 0.5`;
  snap to the centre exactly (no drift). Then, at the centre: if this is
  the finish cell -> PAUSE. Else choose the next heading by the left-hand
  wall follower relative to the current heading: left if open, else
  straight, else right, else back. If the heading changes -> TURN, else
  keep walking.
- TURN: stationary. 90 degrees over 20 ticks, 180 over 36 ticks, yaw
  interpolated with `math.smoothstep01` from the old to the new
  `camera.dir_yaw(dir)` along the short way (180 turns go clockwise). Then
  WALK.
- Roll cap (SPEC decision 9): if `roll != 0` for 1200 ticks, unroll over
  30 ticks with smoothstep. M2 has no smiley yet, so implement the timer
  and the unroll path and expose `debug_set_roll(deg)` to test it.
- PAUSE: hold pose.
- RISE: `t = smoothstep01(tick / 150)`. Position lerps from the finish
  centre at eye height to the overhead point; pitch from its current value
  to `deg(90)`; roll to 0 (short way); yaw unchanged. Overhead point: the
  maze must occupy a 96 px square on screen, axis-aligned (yaw is always a
  multiple of 90 degrees in autopilot), sitting in `y = 4..100` so the name
  strip has the bottom 24 px. Height `h = (max(w, h_cells) / 2) *
  raster.focal / 48`, i.e. 15.4 cells for 12x12, 20.5 for 16x16. Camera
  x,z = maze centre shifted 12 px worth toward the viewer's screen-down
  direction: `centre - forward_h * (12 * h / focal)`, where `forward_h` is
  the unit horizontal heading vector for the current yaw (with pitch 90,
  screen-up is the heading direction, so moving the camera against the
  heading moves the maze up the screen). Do the arithmetic once at PAUSE
  end and store the target.
- OVERHEAD: hold the pose. At tick 0 regenerate the maze from `random`
  (same size) and call nothing on the camera. Set `name_strip_visible =
  true` for the phase (overlay reads a pub flag).
- DESCEND: reverse: from the overhead point to the new start centre at eye
  height, pitch `deg(90)` -> 0, yaw from the current to
  `dir_yaw(start_facing)` along the short way, over 150 ticks with
  smoothstep. `start_facing` = what `camera.reset` would choose. Then
  WALK with that heading.
- A in WALK/TURN: jump to PAUSE from the current position (RISE then
  starts from wherever the camera is; only the pose lerp changes).
- Exports (add): `debug_cycles` (mazes completed), `debug_state_tick`,
  `debug_heading`, `debug_set_roll`, `debug_skip` (same as pressing A),
  `debug_name_strip` (0/1). Keep every existing export.

## Overlay (C2 owns `render/overlay.zig`)

- Keep `draw_debug` as is (Track B wrote it in M1).
- `pub fn draw_name_strip() void`: `ADRIAN HATCH` centred at y = 106 and
  `ANTITHESIS` centred at y = 116, built-in 8x8 font, white text with a
  1 px black drop shadow (draw black at +1,+1 first), no box. main calls it
  when `autopilot.name_strip_visible or name_strip_forced`.
- `pub fn fade(level: u8) void`: darkens the finished frame through a
  4x4 Bayer mask, `level` 0..16 = fraction of pixels blacked (16 = all).
  For M3's teleport; test it in the preview via a `debug_fade(level)`
  export you ask B2 to add (or skip the runtime test and unit-test the mask
  order; say which).
- `check_cycle.mjs`: runs the wasm with no input for N updates
  (`--frames`, default 9000), sampling `debug_state`, `debug_cycles`,
  `debug_cell_x/z` every 30 ticks through `preview.mjs --dump-exports`
  cadence (extend nothing in preview.mjs: run preview several times with
  increasing `--frames` if you need a timeline, or, better, one run with
  `--expect "debug_cycles >= 1"`). Also run with `--press A:300-300` and
  `--expect "debug_cycles >= 1"` at 1000 frames. Report PASS/FAIL; exit 3.
- `tools/scripts/m2_cycle.json`: press A at tick 240 so a 1000-tick
  preview shows walk -> pause -> rise -> overhead (name strip) -> descend
  -> walk in the new maze. `--every 10` for the GIF.
- Goldens: add `overhead_strip` = pose `null`, `calls:
  ["debug_skip", ...]` is not possible before the first update, so
  instead add a pose entry `{ "name": "overhead_strip", "seed": 1, "pose":
  null, "press": "A:0-0", "frames": 301 }` only if `check_golden.mjs`
  already supports `press`; it does not, so leave goldens alone and put
  the frame check into `check_cycle.mjs` (state must be OVERHEAD and
  `debug_name_strip == 1` at tick 300 after A at tick 0: 30 + 150 = 180
  ticks to OVERHEAD, so tick 300 is inside it).
- `docs/RUNNING.md`: update the controls table to the M2 table above.

## Actor renderer (A2 owns; nothing in M2 calls it yet)

- `textures.zig`: unpack `gfx.snouty` (4 frames of 32x32) into four
  `Texture`s with palette index 0 transparent, plus `gfx.smiley`,
  `gfx.logo`, `gfx.snouty_top` (16x16: store it in a 32x32 grid, use
  `u, v` in [0, 0.5)). Export `snouty: [4]Texture`, `snouty_top`, `smiley`,
  `logo`.
- `sprite.zig`: `pub fn draw_billboard(cam, basis, pos: Vec3 /* feet
  centre on the floor */, size: f32 /* cells, square */, tex) void`: a
  view-plane-aligned quad standing on the floor, drawn with `Fill.sprite`.
  `pub fn draw_floor_sprite(cam, basis, pos, size, tex)`: same texture on a
  quad lying on the floor at y = 0.003 for the overhead phases.
- `mesh.zig`: comptime UV sphere, 8 rings x 12 segments, quads plus pole
  triangles, `pub fn draw_sphere(cam, basis, centre, radius, base: [3]u8
  rgb) void` flat-shaded per face with light direction `normalize(0.4,
  0.8, -0.45)` and 8 grey levels via a comptime table of Pixels; backface
  cull per face by the view-space normal. `pub fn draw_spin_quad(cam,
  basis, centre, half_size, angle: Angle, tex)`: two-sided textured quad
  (draw both windings or disable culling: the raster has no culling, so
  one submission suffices) rotating about the vertical axis.
- Debug hook in `scene.zig`: `pub var debug_actors: bool = false`; when
  true, `draw` also draws a sphere at cell (1,1), a spinning smiley at
  (2,1), a spinning logo at (3,1) and a Snouty billboard at (1,2), angle
  = frame count from a `pub var debug_frame: u32` you bump inside `draw`.
  Ask B2 (in your report) for a `debug_actors(on)` export; until then test
  by flipping the default locally and reverting before you finish.
- Fix anything the untested `Fill.sprite` path gets wrong. Keep the
  goldens passing (`node tools/check_golden.mjs`), since they render with
  `debug_actors = false`.

## Done criteria for M2

1. `zig build`, `zig build test`, `check-float`, `check_golden` all clean.
2. `check_cycle.mjs` PASS: unattended run completes at least one maze;
   A-skip run shows OVERHEAD with the name strip at tick 300.
3. `docs/preview_m2.gif` from `m2_cycle.json`.
4. Tag `m2`, hand-off note.

## M2 result (2026-09-26, tag `m2`)

Done criteria met: build, 24 host tests, check-float PASS, 7 goldens
(`start` re-baselined: the cart now boots in WALK, so frame 0 is one step
in), `check_cycle.mjs` 3/3, `docs/preview_m2.gif`. `.text` 40 KB, `.bss`
50 KB. Deviations, all kept:

- Overhead framing fits the wall tops (y = 1), not the floor: `h = 1 +
  max(w, h) / 2 * focal / 48`, shift `12 (h - 1) / focal`. Floor-fitted
  framing let the tops overrun the top edge.
- `check_cycle` run B samples tick 240, not 300: OVERHEAD covers ticks
  180..299 exactly.
- If A interrupts a TURN, RISE also finishes the yaw to the nearest
  quadrant so the plan view stays axis-aligned.
- `debug_fade(level)` is sticky (applied every frame until set to 0).
- Floor sprites lift by `max(0.003, 1.5 d^2 / 2048)` capped at 0.3 so the
  strict z test does not eat them at overhead range.
- Sprite texel lookups clamp instead of wrapping at quad edges.
- Sphere is 8 bands x 12 segments (72 quads + 24 triangles); the spec's
  "96 quads" was wrong for 8 rings.
- The first maze on seed 1 finishes near tick 6900; the follower can need
  up to ~8900 on other seeds, so unattended checks use 9000 frames for
  seed 1 and should use 12000 for arbitrary seeds.
- `m1_fly.json` only works on the `m1` tag now (autopilot ignores the
  stick; B+Select enters fly mode instead).

# Plan: A1 "Real textures from the Windows 95 3D Maze recreation" (2026-09-27)

Adrian found <https://github.com/ibid-11962/Windows-95-3D-Maze-Screensaver>,
a WebGL recreation whose textures were extracted from the original
screensaver (brick wall, wood floor, pebble ceiling, wall picture, OpenGL
logo, smiley, rat, Start button). Use them instead of the placeholders.

- Copy the source files unchanged into `assets/src/w95/` with a
  `SOURCE.md` (provenance, dimensions, what each becomes).
- `tools/prepare_assets.py --from-w95 assets/src/w95` downsamples each
  source to the manifest size (Lanczos, alpha resized separately, opaque
  pixels only in the quantiser), median-cut quantises to 15/16 colours,
  snaps the palette to RGB565, re-merges duplicates, and runs the same
  `validate` as `--placeholders`. Sheets that have no source (`finish`,
  `snouty`, `snouty_top`) keep their procedural drawings so one run
  produces a complete `assets/gen/`.
- `--rat` swaps the Snouty sheet for the rat (mirrored for the left
  frames, two identical frames per side; the source has one pose). Default
  stays Snouty (SPEC decision 6). `--placeholders` keeps working.
- New manifest rows `wall_pic.png` (32x32 opaque) and `start.png` (32x32
  transparent) so M3 can hang the picture on a wall panel and float the
  Start button in the first cell, as the original does. `build.zig`
  `images` gets the two rows; nothing draws them yet (unreferenced `gfx`
  data is dropped by the linker).
- Texture size stays 32 texels: the inner loop packs u, v as 5.11 fixed
  point so the wrap is free (`raster.zig` `tex_pixel`). 64-texel textures
  would be a rasterizer change, not an asset change.
- Rebaseline `tests/golden/*.png` (pixel content changes, geometry does
  not), `docs/w95_assets.png` contact sheet, `docs/preview_a1.gif`.

## A1 result (2026-09-27, tag `a1`)

Done as planned. `wall`, `floor`, `ceiling`, `smiley`, `logo`,
`wall_pic`, `start` come from the w95 sources; `finish`, `snouty`,
`snouty_top` stay procedural (`--rat` swaps the last two). Colour counts
9..16 of 16. Build, 24 host tests, check-float PASS, 7 goldens
rebaselined (texture content only), `check_cycle` 3/3, `.text` 39.8 KB
(+0), `.bss` 50 KB. `docs/w95_assets.png`, `docs/w95_assets_rat.png`,
`docs/preview_a1.gif`. Adrian reviewed in the emulator the same day:
keep Snouty and the Iris mark, so the OpenGL word, the rat and `--rat` were
removed (commit after `a1`). Still open: the textures are Microsoft's.

# Plan: A2 "Art from the pipeline; no audio" (2026-09-27)

Adrian's guidance after seeing `a1` in the emulator: a Zig mark takes the
OpenGL word's role (the spinning logo actor), Snouty comes from the
study05 run frames (with the net) in `../snouty-art`, the Start button
gets the Iris mark in place of the Windows flag, and the Iris mark itself
is downscaled to pixel art. No audio support at all ("it'll be annoying").

- `../snouty-art/tools/build_maze.py` produces `out/maze/{snouty,logo,
  iris,start}.png` (see that repo's PLAN.md). `prepare_assets.py
  --from-w95 assets/src/w95 --art ../snouty-art/out/maze` takes them,
  validates, and writes `assets/gen/`; without `--art` the procedural
  Snouty and Iris fill in as before. `logo.png` is now the Zig mark.
- New manifest row `iris.png` (32x32 transparent) for the overhead name
  strip and wherever M3/M4 wants the mark; `build.zig` gets the row.
- `snouty_top.png` dropped 2026-09-27: from above Snouty is the walk frame
  on the floor-aligned quad (Adrian: "just billboard snouty").
- Audio removed from the design: SPEC section 9 becomes neopixels only,
  `audio.zig` leaves the M3 list, decision 9 updated. Select keeps the
  LED toggle.
- Goldens: unchanged unless a pose shows an actor (none does yet).

## A2 result (2026-09-27, tag `a2`)

Done as planned. `assets/gen/` is built with `--from-w95 assets/src/w95
--art ../snouty-art/out/maze`: Snouty from run frames 0 and 8 (14
colours), Zig mark (1), Iris mark (1), Start button with the Iris mark
(9). New `iris.png` row. Audio removed from SPEC (sections 2, 3, 9, 11,
12, 17, decision 8). Build, 24 host tests, check-float PASS, goldens
unchanged (7 pass), `.text` 39.8 KB. Adrian: keep the w95 textures, no
look-alikes. M3 next, in a fresh session.

# Plan: M3 "Inhabitants" (2026-09-27)

M3 puts the actors into the screensaver: Snouty wandering the corridors,
the smiley that flips the view, the sphere that teleports, the spinning
Zig mark, the Start button in the first cell, the original's pictures on
the walls, and the neopixels with the Select toggle. The renderer calls
(`render/mesh.zig`, `render/sprite.zig`) exist since M2; M3 is the logic,
the scene hook-up, the LEDs and the harness. No audio (Adrian).

## Tracks

| Track | Owner | Files |
|-------|-------|-------|
| A3 scene and textures | Opus agent | `cart/src/render/scene.zig`, `render/textures.zig`, `render/sprite.zig`, `render/mesh.zig` (fixes only) |
| B3 actor logic and state | Opus agent | `cart/src/actors.zig`, `cart/src/autopilot.zig`, `cart/src/main.zig`, `cart/src/host_tests.zig` |
| C3 LEDs, harness, docs | Opus agent | `cart/src/leds.zig`, `tools/check_cycle.mjs`, `tools/scripts/m3_*.json`, `tests/golden/poses.json` (additions only), `docs/RUNNING.md` |

Frozen: `math.zig`, `rng.zig`, `input.zig`, `maze.zig`, `camera.zig`,
`render/clip.zig`, `render/raster.zig`, `render/overlay.zig`, `build.zig`,
`tools/preview.mjs`, `tools/check_golden.mjs`, `tools/prepare_assets.py`,
`assets/gen/*`. A change to another track's file goes into the final
report as a request with the exact diff.

The stubs committed with this plan (`actors.zig`, `leds.zig`) are the
contract: A3 reads `actors` pub data, B3 fills it in, B3 calls `leds`,
C3 implements it. Nobody changes a pub declaration in the stubs without
saying so in the report.

## Controls in M3 (SPEC section 3, screensaver column)

| Input | Autopilot states | Fly (debug) |
|-------|------------------|-------------|
| Select | Toggle the neopixels (default off) | Toggle the debug overlay |
| Start | Toggle name strip permanently on/off | Reset camera to start cell |
| A | Skip to PAUSE | + Up/Down: pitch |
| B + Select | Toggle fly mode | Back to autopilot |
| Stick | ignored | walk / turn |

The overlay flag persists across the mode switch, so to read `render_us`
during the screensaver: B+Select, Select, B+Select. `-Ddebug_overlay=true`
still starts with it on.

## Actors (B3 owns `actors.zig`; SPEC section 7 with these numbers)

All positions are world cells, y up. `actors.reset(m, r, avoid)` places
everything for a fresh maze; `actors.step(m, r, cam_cell, triggers)` runs
one tick; `actors.place(kind, x, z)` is the debug hook. The pub data the
renderer reads is in the stub. Spawn rule for every actor: a random cell
that is not the start, not the finish, not `avoid` (the camera's cell) and
not another actor's cell; collect candidates into a `.bss` array and pick
with `r.below(n)`. Preferences: smiley in a dead end (exactly three
walls), logo in a junction (at most one wall), fall back to any cell when
the preferred set is empty.

- **Snouty**: `wanderer` with feet centre `pos`, direction `dir`, walk
  phase. 1.5 cells/s = 40 ticks per cell, `phase` toggles every 10 ticks.
  At every cell centre pick a random open direction, never the reverse
  unless the cell is a dead end. He may cross the camera's, the start's
  and the finish's cells; the spawn rule is for placement only. Keeps
  walking in every state, fly included, and moves into the new maze at
  `reset`.
- **Smiley**: `Spinner` at eye height in a dead end, `angle += 546` per
  tick (1 turn per 2 s). Trigger: `triggers` is true (state WALK or TURN)
  and the camera's cell equals its cell. Then `autopilot.flip()`,
  `flips += 1`, respawn (rule above, the camera's cell excluded).
- **Sphere**: `Bobber`, centre at eye height plus `0.05 * sin_turns(t /
  120)`, radius 0.25. Trigger as the smiley: pick a destination cell (rule
  above; also not the finish, so the walk continues) and a random open
  direction of it, call `autopilot.begin_teleport(dest, dir)`,
  `teleports += 1`, respawn (excluding the destination).
- **Logo**: `Spinner` in a junction, `angle += 364` per tick (1 turn per
  3 s). Decorative.
- **Start button**: `start_button` = start centre shifted 0.3 cells
  against `camera.start_facing(m)` (behind the camera when it starts), at
  eye height; drawn as a spin quad at 1 turn per 4 s (angle from
  `start_angle`).

Host tests in `actors.zig` (add it to `host_tests.zig`): spawns respect
the exclusion rule for seeds 1..50 (no two actors share a cell, none on
start/finish/avoid, smiley in a dead end when one exists, logo in a
junction when one exists); Snouty never walks through a wall over 5000
ticks and never reverses outside a dead end; the smiley trigger fires
exactly once when the camera cell matches and the smiley moves away; the
sphere trigger enters TELEPORT and the camera lands on the destination
centre at eye height with the yaw of an open direction.

## Autopilot additions (B3 owns `autopilot.zig`)

- `pub fn flip() void`: roll animation from the current roll to roll + 180
  over `flip_ticks = 30` with smoothstep. Generalise the existing unroll
  path into one roll animation (from, delta, tick, dur); the cap timer
  (1200 ticks, decision 9) counts only while no animation runs and roll is
  non-zero, and a flip while rolled 180 goes back to 0 (the view rights
  itself). Roll animates in WALK, TURN and PAUSE as today; RISE lerps it
  to 0 as today; a flip request outside WALK/TURN is ignored.
- `pub fn begin_teleport(dest: [2]u8, d: Dir) void` (only from WALK/TURN):
  enter TELEPORT (state 6), `teleport_ticks = 12`. Ticks 1..6 fade out
  (`fade_level = tick * 16 / 6`, so 16 at tick 6); at tick 6 the camera
  moves to `cell_centre(dest)` at eye height with `yaw = dir_yaw(d)`,
  pitch 0, roll unchanged, `cell = dest`, `dir = d`, `walk_tick = 0`;
  ticks 7..12 fade in (`16 - (tick - 6) * 16 / 6`); at tick 12 WALK via
  `decide` (may TURN at once). `pub fn fade_level() u8` returns the level
  (0 outside TELEPORT); main applies `overlay.fade(@max(debug_fade_level,
  autopilot.fade_level()))`.
- `enter_overhead` calls `actors.reset(m, r, camera cell)` right after
  `m.generate`; `main.new_maze` does the same. `autopilot` importing
  `actors` and `actors` importing `autopilot` is fine in Zig.
- A during TELEPORT is ignored (skip only from WALK/TURN, as now).
- Tests: flip reaches exactly `deg(180)` after 30 ticks and the cap timer
  then unrolls after 1200 more; a second flip at 180 ends at 0; teleport
  fade levels are 0, 2, 5, 8, 10, 13, 16 (ticks 0..6) and back to 0 at
  tick 12 with the state WALK or TURN.

## main.zig (B3)

Per tick: `input.update` -> chords as today, but Select alone toggles
`leds.enabled` in autopilot states and `show_debug` in fly -> autopilot
step / fly -> `actors.step(&world, &random, cam_cell, triggers)` where
`triggers = state == .walk or state == .turn` -> render (`scene.draw`
draws the actors itself) -> overlays -> fade -> `leds.update(state,
actors.flips, actors.teleports)` -> present. New exports: `debug_snouty_x/z`,
`debug_smiley_x/z`, `debug_sphere_x/z`, `debug_logo_x/z` (cells),
`debug_flips`, `debug_teleports`, `debug_roll_deg` (0..359),
`debug_leds` (1 when enabled), `debug_led_max` (largest channel value),
`debug_place(code)` with `code = kind * 10000 + x * 100 + z`, kind 0
Snouty, 1 smiley, 2 sphere, 3 logo (one integer so `preview.mjs --call`
can drive it), `debug_fade_level`. Remove `debug_actors` (the hook is
gone). Keep every other export.

## Scene (A3 owns `render/scene.zig`, `textures.zig`)

- `textures.init` also unpacks `gfx.wall_pic` (opaque, `wall_pic`),
  `gfx.start` and `gfx.iris` (transparent, `start`, `iris`). Palette
  brightness 10 for all.
- `scene.draw` order: finish tile, **wall pictures**, wall runs, floor,
  ceiling, **actors**. Pictures go before the walls for the same reason
  the finish tile goes before the floor: they sit 0.005 out from the face
  and the strict greater-than z test keeps the first draw where the two
  quantise equal.
- Pictures: for every run and every cell-length segment `k` of it, hash
  `h = (x + k*dx) * 7 + (z + k*dz) * 13 + axis * 3` (any cheap mix);
  when `h % 8 == 0` hang a 0.5 x 0.5 `wall_pic` quad centred on the
  segment at height 0.55, on the face picked by `(h / 8) & 1` (north or
  south for x-runs, west or east for z-runs), 0.005 out from the face,
  only when the camera is on that side (same sign test as the face) and
  below `wall_height`. u increases to the viewer's right, v = 0 at the
  top, so the picture is never mirrored. About one segment in eight;
  the frustum test drops the rest.
- Actors, after the ceiling, reading `actors` pub data:
  - Snouty: `cam.pos[1] < wall_height` -> `sprite.draw_billboard(cam, b,
    snouty.pos, actors.snouty_size, frame)`; otherwise
    `sprite.draw_floor_sprite` with the same frame. Frame: the sheet's
    cells 0, 1 face left, 2, 3 face right (`../snouty-art/tools/
    build_maze.py`); with `right = (cos yaw, 0, sin yaw)` and `mv =
    (dir.dx, 0, dir.dz)`, `dot(right, mv) >= 0` picks the right-facing
    pair, then `phase` picks the frame within the pair.
  - Smiley and logo: `mesh.draw_spin_quad(cam, b, pos, 0.2, angle, tex)`.
  - Sphere: `mesh.draw_sphere(cam, b, sphere.pos, actors.sphere_radius,
    .{ 0xc0, 0xc0, 0xc0 })`.
  - Start button: `mesh.draw_spin_quad(cam, b, actors.start_button, 0.2,
    actors.start_angle, &textures.start)`.
- Remove the `debug_actors` hook and `debug_frame`.
- Fix whatever the sprite path gets wrong when a billboard straddles the
  near plane (Snouty walks through the camera's cell) or lies under the
  camera from above; `check_golden` will be rebaselined at integration
  because actors now appear in the fixed poses, so report the before and
  after PNGs of any pose you touched rather than relying on it.
- Cost report: extra polygons at the start pose and the overhead pose.

## LEDs (C3 owns `leds.zig`)

`pub var enabled: bool = false`; `pub fn update(state: autopilot.State,
flips: u32, teleports: u32) void` writes all five `cart.neopixels` every
tick (GRB struct, every channel at most 10):

- disabled: all zero.
- WALK, TURN, PAUSE, RISE, DESCEND, FLY: dim brick `(r 6, g 2, b 1)`.
- `flips` changed since the last tick: start a purple pulse, 90 ticks,
  `(r 6, g 0, b 10)` scaled by `1 - t`, on top of the base (clamp each
  channel to 10).
- TELEPORT: white `(10, 10, 10)`.
- OVERHEAD: breathing, level `1 + 9 * (0.5 + 0.5 * sin_turns(tick /
  180))` in the brick hue.
- Keep it integer where you can; `math.sin_turns` is fine. No cart API
  beyond `cart.neopixels`.

## Harness and docs (C3)

- `check_cycle.mjs`: keep A, B, C; add
  - D flip: `--call debug_place:10100` (smiley in cell (1, 0), the first
    cell the seed 1 camera enters, heading east from (0, 0)), 100
    frames, expect `debug_flips == 1`, `debug_roll_deg == 180`,
    `debug_smiley_x != 1 || debug_smiley_z != 0` (it moved; if `--expect`
    cannot express "or", check x and z through two runs or accept a
    weaker check and say so).
  - E teleport: `--call debug_place:20100`, 100 frames, expect
    `debug_teleports == 1`, `debug_state < 2` (WALK or TURN),
    `debug_fade_level == 0`.
  - F leds: `--press SELECT:0-0`, 10 frames, expect `debug_leds == 1`,
    `debug_led_max <= 10`, `debug_led_max > 0`.
  - Run A may need more frames now that teleports restart the walk:
    measure the first-finish tick for seeds 1..5 (`--expect
    "debug_cycles >= 1"` with increasing `--frames`) and set the default
    so seed 1 passes with margin; record the numbers in RUNNING.md.
- Goldens: add `actors` = seed 1, pose `0.5,0.5,0.5,90,0,0` (start cell
  looking east down the first corridor, cells (1, 0) and (2, 0) in
  view), calls `debug_place:0200` (Snouty at (2, 0)), `debug_place:10100`
  (smiley at (1, 0); poses run in FLY, where triggers are off, so
  nothing fires), plus the sphere and the logo in cells the pose can
  see (check the seed 1 map with `maze.dump` or a preview). Add
  `overhead_actors` = `6,13.5,6,0,90,0` with the same calls, so the
  floor sprite and the spin quads from above are covered. Both are
  generated at integration (`--update`); you add the entries and confirm
  they render something sensible.
- `tools/scripts/m3_tour.json`: A at tick 700, for a 1000-frame,
  `--every 10` GIF run with `--call debug_place:10100 --call
  debug_place:20401` (sphere at (4, 1), on the path after the flip).
  Document the exact preview command in RUNNING.md.
- `docs/RUNNING.md`: controls table above, the new exports, runs D..F,
  the M3 GIF command, LEDs note (dim on purpose; Select toggles).

## Done criteria for M3

1. `zig build`, `zig build test`, `check-float` clean; `.text` under
   120 KB, `.bss` under 100 KB.
2. `check_golden` PASS after rebaselining (all poses inspected).
3. `check_cycle` PASS on A..F.
4. `docs/preview_m3.gif` from `m3_tour.json`.
5. Tag `m3`, hand-off note.

## M3 result (2026-09-27, tag `m3`)

Done criteria met: build, 30 host tests, check-float PASS, 9 goldens
(`overhead`, `overhead_16`, `outside_corner` re-baselined for the spawned
actors; `actors` and `overhead_actors` new), `check_cycle` 6/6,
`docs/preview_m3.gif`. `.text` 61.6 KB (+22 KB, mostly the actor drawing
and the sphere mesh inlined into the frame function), `.bss` 59 KB (+9 KB:
four more unpacked sheets, spawn scratch). Deviations, all kept:

- **Teleport hops forward along the follower's path** instead of to a
  random cell. B3's first version restarted the walk from a random cell,
  and seed 1 then took 39,000 ticks (11 minutes) to reach its first
  finish. Now the destination is a random point in the second half of the
  remaining wall-follower path (never the finish), so every hop shortens
  the walk. First finish: seed 1 at tick 2622, seeds 2..5 within 5307.
  `check_cycle` run A stays at 9000 frames. Landing heading is the
  follower's arrival heading, so the camera may face a dead-end wall for a
  moment and turn, as the follower would have.
- The roll animation also runs during TELEPORT, so a flip in progress does
  not freeze during the dissolve.
- Golden pose `actors` is `11.88,0.95,0.08,190,14,0` looking down the
  x = 11 corridor with the actors placed at (11, 1..5): the plan's
  start-cell pose could not see cell (2, 0) (the preview's `--seed 1` maps
  to `cart.rand() = 270369`, a different maze from `Xorshift.init(1)`).
- Tour script puts the sphere at (4, 0), not (4, 1): with the smiley flip
  at (1, 0) the follower only reaches (4, 1) at tick 700.
- LEDs: the white flash follows the TELEPORT state rather than the
  `teleports` counter; the pulse remembers the last `flips` value while
  off, so enabling the LEDs later does not replay an old pulse.
- `textures.iris` is unpacked but nothing draws it yet (M4 polish).
- Snouty placed by `debug_place` heads along the cell's first open side
  (the hook has no rng).
- **Fix after the first `m3` tag** (badge-bench found it, same day): the
  comptime sphere face table used `Vec3` fields; on the thumb target the
  code stepped 40 bytes per face over a table emitted at 48, so faces
  1..95 read garbage indices (past the stack into SRAM8/9, no fault, a
  garbage sphere on hardware). Fields are `[3]f32` now; the table is
  96 x 32 bytes, wasm output identical (goldens unchanged), `m3` re-tagged.
  badge-bench's modelled cost: mean 11.3 ms, worst 15.4 ms of 16.7, so the
  hardware fps numbers matter more than ever.

# Plan: M4 "Polish" (2026-09-29)

Adrian, 2026-09-29: agreed to the M4 list; target 12x12, keep 16x16 one
switch away. Four pieces, three parallel Opus tracks plus integration:

| Track | Owns | Delivers |
|---|---|---|
| A4 perf | `render/raster.zig`, `render/clip.zig`, `render/mesh.zig`, `render/sprite.zig`, `render/scene.zig` (except C4's hunk), `build.zig` | worst frame <= 12.0 ms at 12x12, `-Dmaze_size` build option, bench numbers |
| B4 takeover | `autopilot.zig`, `main.zig`, `input.zig`, `leds.zig`, `actors.zig` (trigger hook only) | MANUAL state, idle return, B+Select chord debug-only |
| C4 carving + Iris | `maze.zig`, `render/overlay.zig`, `render/textures.zig`, one hunk in `scene.zig`, two lines in `autopilot.zig` (`enter_overhead` / `.overhead`) | animated carving in OVERHEAD, Iris mark in the name strip |

All three share one working tree (as in M1..M3): edit shared files with
small `Edit` hunks only, never rewrite them whole, re-read before editing.
Each track keeps `zig build test`, `check-float` and `check_golden` green
at the end of its work. Integration (me): check_cycle, bench, GIF, docs, tag.

## Baseline (calibrated badge-bench, 2026-09-29, build 1910d2f)

`badge-bench/bench.sh zig-out/firmware/snouty-maze.elf --script
carts/snouty-maze/tools/scripts/m2_cycle.json --frames 900` (seed 1,
12x12): mean 8.47 ms, p95 11.84, worst 13.60 ms at frame 108 (walking,
81% of 16.7). Hot: `draw_polygon` with its inlined column/span code 68.6%
(184 polygons per frame), `inner_tex8` 19.5%, `inner_tex` 5.1%, z clear
1.8%. 16x16 (2026-09-29 note): worst 15.90 ms.

## A4 perf

Goal: worst busy ms <= 12.0 (72%) at 12x12 over m2_cycle.json seeds 1..10
and m3_tour.json, calibrated model (the default). Also report 16x16
(`--poke maze_size=16`); if 16x16 also comes in <= 12.0, say so: Adrian
decides the default, the code must not.

- Exactness gate: every optimisation must leave `check_golden` pixel
  identical (all 9 poses) unless a change is intended and argued in the
  result section. Hidden-surface culling has to be conservative.
- Profile first (`--listing`, `--symbols`) and write down where the
  cycles go before changing code. Candidates, in the order I would try
  them: (1) column occlusion for walls at eye height: walls are submitted
  front to back and span floor to ceiling, so a per-column "closed" mask
  (or near/far horizon) lets later wall polygons skip closed columns and
  stops wall submission once all 160 columns are closed; floor and
  ceiling then only see the open rows. (2) cheaper per-polygon setup for
  polygons that end up covering few columns. (3) span_tex per-column
  overhead (`sample_uv` divides, `any_visible`). Anything else the
  profile shows.
- Tunables in one place with comments (e.g. `seg`).
- `-Dmaze_size=N` (default 12, clamp 4..16) in `build.zig` ->
  `build_options.maze_size`, used as the initial value of `main.maze_size`
  (B4 owns `main.zig`; A4 may change that one initializer line). The
  badge export stays so `--poke` still works.
- Record before/after tables (12x12 and 16x16, seeds 1..10, mean / p95 /
  worst) in the M4 result section.

## B4 takeover (SPEC section 3 "Takeover" column)

- New state `manual = 8` (append; existing values stay stable).
- Entering: any of Up/Down/Left/Right pressed in WALK or TURN. In other
  states (PAUSE, RISE, OVERHEAD, DESCEND, TELEPORT) the stick is ignored.
  From WALK mid-cell: the camera keeps moving to the next cell centre
  (Down reverses it back to the cell it left); from TURN: the turn
  finishes first. Grid-locked like the original.
- In MANUAL at a cell centre: Up walks forward one cell if no wall (same
  speed as WALK, 30 ticks), Down walks back one cell facing forward, Left
  / Right pivot 90 degrees (`turn90_ticks`, same easing). Held buttons
  repeat at the next cell centre / end of pivot. A wall in the way: no
  move (no bump animation).
- Idle return: 300 ticks (5 s) with no stick held, at rest -> WALK from
  the current cell and heading (`decide`; the left-hand follower reaches
  every cell of a perfect maze from anywhere).
- Walking into the finish cell in MANUAL starts PAUSE -> the normal
  finish sequence. A still skips to PAUSE. Select toggles the LEDs,
  Start toggles the name strip, as in the screensaver.
- Actors: smiley and sphere trigger in MANUAL too; a teleport from MANUAL
  returns to MANUAL (idle timer restarted), not WALK.
- LEDs: MANUAL gets the WALK colour (or a slight variant, B4's call).
- B+Select fly chord: compiled in only with `-Ddebug_overlay=true`;
  `debug_set_camera` keeps using FLY on wasm.
- Exports: `debug_manual_idle` (ticks since the last stick input).
- Host tests: enter from WALK mid-cell, Down reversal, wall blocks Up,
  idle return after 300 ticks, finish from MANUAL, teleport returns to
  MANUAL.
- `check_cycle.mjs` runs G (Up at tick 0 for 45 ticks: state 8 and cell
  changed) and H (Right at tick 0 then idle to tick 400: state WALK or
  TURN).

## C4 carving and the Iris mark

- `maze.generate` also records the carve order (`carve_log`: w*h-1
  entries of cell + direction, <= 255). `Maze.reveal(k)` rebuilds `runs`
  as if only the first k carves had happened (all walls, then k removed);
  `cells`, `start`, `finish` stay final, so the actors and the follower
  never see a partial maze. `reveal(carve_count)` equals the normal runs.
  The `runs` buffer bound (`max_runs`) already covers the full grid.
- OVERHEAD: `enter_overhead` calls `reveal(0)` after `generate`; each
  OVERHEAD tick reveals `k = carve_count * t / carve_ticks` with
  `carve_ticks = 90` (constant in autopilot.zig), so the last 30 ticks
  show the finished maze. DESCEND starts from the full runs.
- Scene (C4's hunk): while carving (`m.revealed < m.carve_count`) skip the
  finish tile and the actors; both appear when carving ends. Optional, if
  it stays cheap: the carve head cell drawn as a flat tile.
- Iris mark in the name strip: draw `textures.iris` (32x32, palette 0
  transparent) as a 2D blit next to the two text lines (e.g. 16x16 at
  2:1 or 24x24, left of the lines, the icon+text group centred), inside
  y = 104..127 so it does not touch the maze square. Blit, not the
  rasterizer (no z test).
- Exports: `debug_carve_shown` (k), `debug_carve_count`.
- Host tests: `reveal(count)` == generated runs for seeds 0..99; `reveal(0)`
  is the full grid (2*(w+h)... one run per grid line: w+1 + h+1 runs);
  run counts stay <= max_runs for every k.
- `check_cycle.mjs` run I: A at tick 0, 200 updates (OVERHEAD tick 20):
  debug_carve_shown < debug_carve_count; run B unchanged.

## Integration and done criteria for M4

- `zig build`, `zig build test`, `check-float`, `check_golden` 9/9 (A4
  proves pixel identity), `check_cycle` A..I pass.
- Calibrated bench over m2_cycle.json seeds 1..10 and m3_tour.json:
  worst <= 12.0 ms at 12x12; 16x16 numbers recorded. A takeover bench
  script `tools/scripts/m4_takeover.json` costed too.
- `.text` + `.data` <= 120 KB, `.bss` <= 100 KB.
- `docs/preview_m4.gif` (carving overhead, takeover walk, Iris strip),
  `docs/RUNNING.md` controls, SPEC status, tag `snouty-maze/m4`.
