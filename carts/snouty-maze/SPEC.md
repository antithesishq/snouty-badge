# Snouty Maze: cart spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Sixth cart for the badge, alongside `snouty-badge` (running Snouty),
`snouty-bugs` (bullet hell), `snoutenstein` (raycaster FPS, spec only),
`snouty-reflections` (ray tracer demo) and `snouty-boy` (Game Boy emulator,
spec only). Name decided; see section 18.
Status and milestones are at the bottom.

## 1. One paragraph

A from-scratch clone of the Windows 95 / NT 4 "3D Maze" screensaver. A
random maze of thin brick walls under a textured ceiling, a textured floor,
and a camera that walks itself through the corridors, pausing to pivot 90
degrees at junctions and turning around in dead ends. Snouty scurries
through the maze in the rat's role. A spinning smiley flips the view upside
down, a grey sphere teleports the camera, a floating logo spins for
decoration. When the camera reaches the finish it rises out of the maze,
tilting down until it looks straight at the whole maze from above, holds
that view with the badge text under it, then descends into the start of a
fresh maze. Everything is drawn by a real perspective renderer with a z
buffer, not a raycaster, because the rise is the part everyone remembers
and a raycaster cannot pitch. No source or bitmaps from the original are
used: the geometry is well known and the textures are ours.

## 2. Hardware facts the design leans on

- RP2354B, Cortex-M33 at 150 MHz. The cart target is `eabihf` with
  `fp_armv8d16sp` (verified in `snouty-reflections` M0), so `f32` add and
  multiply are single-cycle and `f32` divide and `@sqrt` are hardware
  (about 14 cycles). `f64` is soft-float and must never appear in a hot
  loop. Core 1 runs only the cart; `present()` waits for the previous LCD
  flush, so the cart gets essentially the whole 16.7 ms.
- Screen 160x128. The framebuffer is column-major (`framebuffer[x][y]`),
  so the rasterizer fills vertical spans: it is a scanline rasterizer with
  the axes swapped, and every store is a stride-1 `u16`. The z buffer uses
  the same layout.
- Both framebuffers belong to the OS (`platform.framebuffers`), not to the
  cart, so the cart's only large buffer is the 40 KB z buffer.
- On hardware `Pixel` is a plain bitcast of `DisplayColor`; on wasm it is
  byte-swapped. Palettes are converted to `Pixel` at comptime or in
  `start()`; inner loops do a table lookup and a store.
- Cart RAM 307 KB (`0x20035100..0x20080000`), binary at most 256 KB.
  Budget for this cart: ELF `.text`+`.data` at most 120 KB, `.bss` at most
  100 KB, measured with `size -A` every milestone (section 13).
- Inputs: joystick 4-way, A, B, Start, Select. Start+Select (250 ms) and
  joystick click (FPS overlay) are OS-owned; never bound.
- Audio: none (Adrian, 2026-09-27: "it'll be annoying"). Neopixels: 5,
  every channel at or below 10/255.
- Rendering: `.no_copy_full_frame`, full redraw every frame,
  `set_vsync_enabled(1000.0 / 60.0)`.

## 3. Controls

The cart is a screensaver first: it needs no input at all. Inputs exist for
the M1 debug camera and, from M4, for taking the camera over.

| Input        | Screensaver (default)            | Takeover (M4)                           | M1 debug camera                     |
|--------------|----------------------------------|-----------------------------------------|-------------------------------------|
| Up / Down    | (starts takeover)                | Walk forward / back one cell at a time  | Move forward / back                 |
| Left / Right | (starts takeover)                | Pivot 90 degrees                        | Turn                                |
| A            | Skip to the finish sequence      | Skip to the finish sequence             | Hold + Up/Down: pitch               |
| B            | (nothing)                        | (nothing)                               | Hold + Up/Down: rise / sink         |
| Select       | Toggle LEDs                      | Toggle LEDs                             | Toggle render-microseconds overlay  |
| Start        | Toggle name strip                | Toggle name strip                       | Reset camera to the start cell      |

Takeover: any stick input hands the camera to the viewer; movement is
grid-locked like the original (cell to cell, 90 degree pivots). After 5 s
without input the autopilot resumes from wherever the camera is. Takeover
is M4 and is an open question (section 18).

## 4. Screen layout

The whole 160x128 is the 3D view. There is no HUD.

- Name strip: `ADRIAN HATCH` / `ANTITHESIS` in the built-in 8x8 font, two
  lines centred, drawn only during the overhead hold (section 8), where the
  view has empty margin around the maze. Start toggles it permanently on
  (bottom-left corner, one line) or off.
- Debug builds: `render us` and fps in the top-left corner (Select toggles
  in M1), so the M1 timing check is one photo of the badge.

## 5. World

- Units are cells. A maze is `W x H` cells, default 12x12, maximum 16x16
  (section 18 asks which). Walls are thin panels on cell edges, like the
  original: height 1.0, thickness 0.1. Floor at y = 0, ceiling at y = 1.
  Eye height 0.5.
- Maze representation: one `u8` per cell holding wall bits N/E/S/W plus a
  visited bit for the generator. Boundary walls always present.
- Generation: iterative recursive backtracker (stack of at most 256 cells
  in `.bss`), which gives a perfect maze: every cell reachable, exactly
  `W*H - 1` passages. Start is a corner cell; finish is the cell farthest
  from start by BFS, so the walk is long and ends somewhere interesting.
- Wall runs: after generation, collinear wall segments are merged into
  runs (`x0, y0, length, axis`). A 12x12 maze has about 120 wall segments
  and merges to roughly 60 to 80 runs; 16x16 is about 300 segments. Each
  run is a box 0.1 thick with two long side faces, two end caps and a top.
  Runs are the renderer's unit of geometry; they are rebuilt only when a
  maze is generated.
- Coordinates: x east, z south (cell row), y up. Cell `(cx, cz)` spans
  `[cx, cx+1) x [cz, cz+1)`; its centre is `(cx + 0.5, cz + 0.5)`.
- Randomness: own xorshift in `rng.zig`, seeded from `cart.rand()` on
  hardware and from a fixed seed (or `debug_set_seed`) on wasm, so headless
  runs reproduce and golden images are stable.

## 6. Rendering

A small software 3D rasterizer. Everything visible is a convex polygon in
world space: axis-aligned quads for the maze, a comptime sphere mesh, two
rotating textured quads, and screen-facing billboards.

### 6.1 Camera and projection

- `Camera { pos: Vec3, yaw: u16, pitch: u16, roll: u16 }`, angles in
  65,536ths of a turn with a comptime 1,024-entry sin table returning
  `f32`. A 3x3 rotation matrix is built once per frame from yaw, pitch and
  roll in that order. Roll is what the smiley flip animates; pitch is what
  the rise animates; so the flip and the rise are the same code path as
  ordinary turning.
- View space: `v = R * (p - pos)`, camera looks down +z. Horizontal FOV 66
  degrees, matching Wolf3D and the Snoutenstein spec, so the focal length
  is `f = 80 / tan(33 deg) = 123.2 px`. Vertical FOV follows as 55 degrees.
- Projection: `sx = 80 + f * x / z`, `sy = 64 - f * y / z`, clamped to a
  guard band of `[-4096, 4096]` before conversion to `i32`.
- Near plane `z = 0.05`. The camera pivots at cell centres, 0.45 from the
  nearest wall face, so nothing is ever closer than the near plane during
  normal walking, but the rise passes through the ceiling and teleports
  can land anywhere, so clipping is not optional.

### 6.2 Geometry pass

Per frame, in this order, each producing polygons for the rasterizer:

1. Floor: one quad covering the maze footprint, texture `u = x`, `v = z`,
   tiled per cell (32 texels per cell). Faces up, single-sided.
2. Ceiling: one quad at y = 1, same tiling, faces down, single-sided. This
   is why the rise needs no special ceiling handling: once the eye is
   above y = 1 the ceiling is a back face and vanishes on its own.
3. Wall runs: for each run, world-space backface culling is a sign
   comparison (a +x face is visible iff `pos.x > face.x`), so at most two
   of the five faces of a run are ever submitted, plus the top when the eye
   is above y = 1. Side faces are textured (`u` along the run in cells, `v`
   is height); end caps use the same texture; tops are a flat colour, which
   also makes the coplanar overlap of perpendicular runs at junctions
   invisible (same colour, so z-fighting cannot show).
4. Finish marker: the finish cell's floor is a separate quad with its own
   texture, drawn after the floor with a tiny y offset (0.002) so it wins
   the z test.
5. Actors (section 7): sphere mesh, smiley and logo quads, Snouty
   billboard.

Runs are sorted front to back by the distance from the camera to the run's
midpoint before submission, so the z buffer rejects most hidden pixels at
the compare rather than after texturing. The sort is for speed only;
correctness comes from the z buffer.

Frustum rejection: a polygon whose four view-space vertices all fail the
same one of the six half-space tests is dropped before clipping. About 90%
of a 16x16 maze's faces go away here from inside the maze.

### 6.3 Clipping and rasterization

- Near-plane clipping with Sutherland-Hodgman against `z = near` only;
  input up to 4 vertices, output up to 5. Attributes `u, v` are clipped
  linearly in view space, which is exact. Left, right, top and bottom are
  handled by span clamping in screen space thanks to the guard band.
- Rasterizer: convex polygon, iterated over screen columns (the axes of a
  textbook scanline rasterizer swapped), filling one vertical span per
  column. Per column the left and right edges give `y_top, y_bottom` and
  the endpoint values of `1/z, u/z, v/z`.
- Perspective correction: `1/z, u/z, v/z` are linear in screen space. Each
  vertical span is walked in segments of 8 pixels: one divide per segment
  endpoint (hardware, ~14 cycles), affine `u, v` stepping inside the
  segment in 16.16 fixed point. Textures are 32x32 so `u, v` wrap with
  `& 31`. Fallback: segments of 16.
- Z buffer: `[160][128]u16` holding `1/z * 2048` (near = 0.05 gives 40,960,
  a wall 40 cells away gives 51). Cleared to 0 each frame with word stores
  (about 10k cycles). Test: `if (q > zbuf[x][y]) { zbuf = q; fb = pixel }`.
- Textured span inner loop: step `u, v` (2 adds), texel fetch from the
  unpacked `u8` texture (shift, or, load), palette lookup (load `u16`),
  z compare and two stores. Around 14 to 20 cycles per drawn pixel; a
  rejected pixel costs about 6.
- Flat spans (wall tops, sphere faces): no texture step, about 8 cycles per
  drawn pixel.
- Sprite spans (Snouty): same as textured with a transparent-index skip;
  constant `1/z` per billboard.

### 6.4 Shading

No lighting in the maze, like the original. Each texture has palette
variants converted to `Pixel` at start: lit and dark for the two wall
orientations (the Wolf3D trick, so corners read), floor and ceiling one
each, tops one flat colour. The sphere is flat-shaded per face by one dot
product with a fixed light direction, quantised to 8 grey levels from a
comptime table. The teleport fade and the title fade are done by drawing
a fixed fraction of pixels black through a 4x4 Bayer mask over the
finished frame, no per-pixel blend.

### 6.5 Budget

| Item, at 60 Hz                                   | Estimate         |
|--------------------------------------------------|------------------|
| Cycles per frame                                 | 2.5 M            |
| Z buffer clear                                   | 0.01 M           |
| Transforms and setup, 16x16 maze seen from above | ~300 faces, 0.2 M |
| Fill from above: 20,480 px, ~1.4x overdraw       | 0.5 M            |
| Fill from inside: walls + floor + ceiling        | 0.4 M            |
| Actors                                           | < 0.1 M          |
| Worst case total                                 | ~0.8 M (5.5 ms)  |

If hardware disagrees, section 16 has the decision table.

## 7. Actors

- **Snouty** (the rat). A 32x32 billboard walking the maze at 1.5 cells/s:
  at each cell centre pick a random open direction, never reversing unless
  in a dead end. Two walk frames per facing (left, right), facing chosen
  from the movement direction relative to the camera. Drawn with the
  per-pixel z test so walls hide him properly. During the rise and overhead
  phases the billboard is replaced by `snouty_top`, a 16x16 sprite on a
  floor-aligned quad, so he still reads from above (M4; in v1 he simply
  hides when the eye passes y = 1).
- **Smiley**. A 32x32 two-sided textured quad with transparency at eye
  height in a random dead-end cell, spinning about its vertical axis at
  1 turn per 2 s. When the camera enters its cell the view rolls 180
  degrees over 30 ticks (smoothstep) and the smiley respawns in another
  dead end. The roll stays until the next smiley or the finish, which
  undoes it during the rise.
- **Sphere**. Comptime UV sphere, 8 rings x 12 segments (96 quads plus
  24 pole triangles), radius 0.25, at eye height in a random cell, bobbing
  0.05 up and down. Entering its cell fades the frame to black over 6
  ticks, teleports the camera to a random cell centre with a random
  facing, fades back over 6 ticks, and respawns the sphere.
- **Logo**. A 32x32 two-sided quad with the Iris mark (from
  `snouty-badge`), spinning about its vertical axis in a random junction
  cell. Decorative only. Section 18 offers alternatives.
- **Finish marker**. The finish cell's floor texture, so the viewer sees
  it coming.

Actors never occupy the start, the finish or each other's cells.

## 8. Autopilot and the finish sequence

State machine in `main.zig`:

```
WALK -> TURN -> WALK ...            walking the maze
WALK (finish reached) -> PAUSE      30 ticks
PAUSE -> RISE                       150 ticks
RISE -> OVERHEAD                    120 ticks, name strip on, new maze generated at tick 0
OVERHEAD -> DESCEND                 150 ticks
DESCEND -> WALK                     at the start cell of the new maze
any WALK/TURN, teleport trigger -> TELEPORT (12 ticks) -> WALK
```

- **WALK**: move along the heading at 2 cells/s (1/30 cell per tick). On
  reaching a cell centre choose the next heading by the left-hand wall
  follower: left if open, else straight, else right, else back. On a
  perfect maze this reaches the finish after at most `2 * (W*H - 1)` cell
  moves, and it wanders into dead ends and turns around the way the
  original did.
- **TURN**: stationary pivot, 90 degrees in 20 ticks with smoothstep
  easing, 180 degrees in 36 ticks. No walking while turning, like the
  original.
- **RISE**: parameter `t` from 0 to 1 with smoothstep. Position
  interpolates from the finish centre at eye height to the overhead point
  `(W/2, h, H/2)`; pitch from 0 to 90 degrees down; roll to 0 if flipped;
  yaw unchanged (so the maze is seen rotated the way you approached it,
  again like the original). Overhead height so the maze fits with a one
  cell margin on the short screen axis: `h = (max(W, H) / 2 + 1) * f / 64`,
  about 13.5 cells for 12x12 and 17.3 for 16x16. The ceiling disappears
  by itself when the eye crosses y = 1 (section 6.2).
- **OVERHEAD**: hold. The name strip is drawn. The new maze is generated
  at the first tick of this phase, so the viewer sees the maze change
  under them (the original swapped mazes here too). Optional M4 polish:
  animate the carving over the 120 ticks instead of swapping.
- **DESCEND**: the reverse path into the new maze's start cell, ending at
  eye height facing the only open direction (start is a corner; if two
  directions are open, pick by the wall follower).
- A in any walking state jumps to PAUSE (a demo shortcut, also handy for
  M1 timing).

## 9. Neopixels (no audio)

The original is silent and so is this cart: Adrian dropped audio on
2026-09-27 ("we don't need audio support for this, it'll be annoying").
LEDs default off, Select toggles them.

- Neopixels: dim brick colour while walking, a purple pulse on smiley
  (Iris purple, the badge's brand colour), white flash on teleport, slow
  breathing during OVERHEAD. All channels at or below 10/255.

## 10. Assets

Since 2026-09-27 (tag `a1`) the sheets are downsampled from the original
screensaver's textures (`assets/src/w95/SOURCE.md`, via
`tools/prepare_assets.py --from-w95`); two extra sheets `wall_pic.png`
(the picture the original hangs on odd panels, 32x32 opaque) and
`start.png` (the Start button floating in the first cell, 32x32
transparent) wait for M3 code. Adrian kept Snouty (not the rat). With
`--art ../snouty-art/out/maze` the Snouty, logo (Zig mark), iris and start
sheets come from the art pipeline (`../snouty-art/tools/build_maze.py`);
the committed `assets/gen/` is built that way.
The placeholder mode below still exists.

Adrian asked for placeholders in v1; real art comes later through the same
manifest sizes. `tools/prepare_assets.py --placeholders` draws every sheet
below procedurally at the exact size so code never waits on art, as in
`snouty-bugs`. 4-bit indexed, 15 colours plus transparent index 0
(magenta key) where marked.

| Sheet             | Cell  | Frames | Transparent | Placeholder look                                  |
|-------------------|-------|--------|-------------|---------------------------------------------------|
| `wall.png`        | 32x32 | 1      | no          | red bricks, 2 rows of 4, mortar lines             |
| `floor.png`       | 32x32 | 1      | no          | 4x4 checker in two greys                          |
| `ceiling.png`     | 32x32 | 1      | no          | pale tiles with a dark grid                       |
| `finish.png`      | 32x32 | 1      | no          | black and white 8x8 checker                       |
| `snouty.png`      | 32x32 | 4      | yes         | blob with an "S", left x2 / right x2, legs alternate |
| `snouty_top.png`  | 16x16 | 1      | yes         | top-down blob (M4)                                |
| `smiley.png`      | 32x32 | 1      | yes         | yellow disc, two eyes, a smile                    |
| `logo.png`        | 32x32 | 1      | yes         | iris-like mark (real: Zig mark via `--art`)       |
| `iris.png`        | 32x32 | 1      | yes         | same drawing (real: Iris mark via `--art`)        |

Textures are unpacked to `u8` 32x32 grids at `start()` (1 KB each). Wall
tops and the sphere are flat colours in code and need no sheet.

## 11. Architecture

```
cart/src/
  main.zig          start/update, state machine (section 8), wasm shims (present_wasm,
                    read_controls), debug exports
  math.zig          Vec3, Mat3, u16 angles with comptime sin table, smoothstep, fixed 16.16 helpers
  rng.zig           xorshift32, seedable
  maze.zig          cell grid, recursive backtracker, BFS farthest cell, wall-run merging,
                    dead-end and junction queries
  camera.zig        Camera, autopilot (wall follower, turn easing), rise/overhead/descend paths
  actors.zig        Snouty wanderer, smiley, sphere, logo: state, triggers, respawn rules
  render/
    raster.zig      near clip, project, column-major convex polygon fill: textured, flat,
                    sprite variants; z buffer
    scene.zig       per-frame polygon list: floor, ceiling, wall runs with world-space culling,
                    tops, finish quad; front-to-back sort
    mesh.zig        comptime sphere, flat-shaded face submission, rotating two-sided quads
    sprite.zig      billboards with z test, floor-aligned top sprite
    textures.zig    unpack sheets at start(), palette variants (lit/dark/floor/ceiling)
    overlay.zig     name strip, Bayer fade, debug readouts
  leds.zig          neopixels
  input.zig         edge detection, takeover and idle timer
  packed_int_array.zig  (upstream copy)
tools/              prepare_assets.py (--placeholders), preview.mjs (+ --script, --pose,
                    --dump-exports, --expect), serve-cart.mjs, make_gif.py, check_golden.mjs
tests/golden/       PNGs for fixed seed + fixed poses (section 15)
```

Per tick: read controls -> state machine (autopilot or takeover) ->
actors -> clear z buffer -> scene list -> rasterize -> actors -> overlay ->
LEDs -> present.

`maze.zig`, `math.zig`, `camera.zig` and `render/raster.zig`'s clipper do
not touch the cart API, so they have host unit tests (`zig build test`).

Debug exports (wasm only): `debug_render_us`, `debug_fps_x10`,
`debug_state`, `debug_tick`, `debug_pixel_checksum`, `debug_set_seed`,
`debug_set_camera(x, y, z, yaw, pitch, roll)`, `debug_cell_x/z`.

## 12. Fidelity notes against the original

Things the clone deliberately keeps: thin walls, stop-and-pivot motion,
dead-end wandering, the smiley flip, the sphere teleport, a spinning logo,
the rise to a plan view, the maze swapping while overhead. Things changed:
Snouty for the rat (a billboard rather than a mesh), the finish marker (the
original had none visible; ours helps a viewer follow along), the name
strip (it is a badge). Not cloned: the "walk through walls"
option and custom texture options. Wall, floor, ceiling and picture
textures are the originals (extracted by the ibid-11962 recreation);
Adrian decided on 2026-09-27 to keep them, no look-alikes.

## 13. Memory budget

| Item                                          | Where  | Size    |
|-----------------------------------------------|--------|---------|
| Code (est. 3k lines of Zig)                   | .text  | ~40 KB  |
| Sheets (section 10), 4-bit packed             | .text  | ~5 KB   |
| Sphere mesh, sin table, palettes               | .text  | ~6 KB   |
| Z buffer 160x128 u16                          | .bss   | 40 KB   |
| Unpacked textures and sprites, 9 x 1 KB       | .bss   | 9 KB    |
| Maze cells 256 + runs 320 x 6 B + stack 512 B | .bss   | 3 KB    |
| Sorted run list, clip scratch                 | .bss   | 2 KB    |
| Camera, actors, state                         | .bss   | 1 KB    |
| Total                                         |        | ~106 KB |

Well inside the section 2 budgets (`.text` ~51 KB of 120, `.bss` ~55 KB of
100). If the z buffer had to go, the fallback is a painter's sweep over the
grid (rows away from the camera, then columns away from the camera, which
is a correct back-to-front order for axis-aligned boxes on a grid) with
per-column depth only for the sprites.

## 14. Risks

- **Rasterizer correctness at the near plane** (cracks, T-junction
  sparkle, wrong clipping when the eye passes through the ceiling). The
  golden-image tests at nasty poses are there for this, and the M1 debug
  camera lets Adrian fly through geometry on hardware.
- **Fill rate lower than estimated.** Section 16 has the decision table;
  none of the fallbacks change the look from inside the maze.
- **The rise looking wrong** (too fast, too high, maze too small on
  screen). Constants live in one place in `camera.zig` and the M2 GIF is
  the review point.
- **Snouty as a billboard from above.** Hidden in v1, `snouty_top` in M4.
- **Boredom.** A perfect wall follower can spend a long time in a 16x16
  maze. The default is 12x12 and the A shortcut exists; section 18 asks
  about the solution-path alternative.

## 15. Verification

- `zig build` gives `zig-out/firmware/snouty-maze.uf2` and
  `zig-out/bin/snouty-maze.wasm`; `size -A` against section 13; soft-float
  symbol check as in `snouty-reflections`.
- `zig build test` (host): the generator yields a perfect maze for seeds
  0..999 (all cells reachable, `W*H - 1` passages); the wall follower
  reaches the finish within `2 * (W*H - 1)` moves; run merging covers
  every wall segment exactly once; the clipper on hand-built cases
  (polygon fully behind, straddling with 1 and 2 vertices behind);
  projection of known points.
- Headless: `preview.mjs --script tools/scripts/*.json` for a full
  walk-to-finish-and-rise cycle at seed 1, dumping PNGs; every milestone
  ships a GIF in `docs/`. `--pose` calls `debug_set_camera` for fixed
  views.
- `check_golden.mjs`: renders the fixed poses in `tests/golden/` and
  compares per pixel with a small tolerance, so a rasterizer change that
  cracks a corner fails CI rather than an eyeball.
- Hardware: Adrian flashes M1 and M2 and reports fps and `debug_render_us`
  (section 16).

## 16. Hardware gate (M1)

Measured on the badge with the debug camera at the overhead pose of a
16x16 maze (worst case) and from the start cell looking down the longest
corridor.

| Worst frame measured   | Decision                                                        |
|------------------------|-----------------------------------------------------------------|
| >= 60 fps (< 16 ms)    | as spec'd; allow 16x16 mazes                                    |
| 40 to 59 fps           | 12x12 only; 16-pixel affine segments                            |
| 25 to 39 fps           | lock 30 fps during RISE/OVERHEAD/DESCEND only; 60 inside        |
| < 25 fps               | 30 fps everywhere, render the rise at 80x64 and upscale 2x      |

## 17. Milestones

Each milestone: a tag, a GIF in `docs/`, and a "pull and run" note.
Parallel tracks go to Opus subagents with disjoint files.

- **M0 Scaffold**: repo, toolchain copied from `snouty-bugs` (with the
  hard-float check from `snouty-reflections`), `CLAUDE.md`, `PLAN.md`,
  placeholder sheets from `prepare_assets.py --placeholders`, stub cart
  showing a flat-filled screen, `docs/RUNNING.md`.
- **M1 Rasterizer on hardware** (the risk milestone): maze generation and
  wall runs, floor and ceiling, textured walls with orientation shading,
  z buffer, near clipping, full yaw/pitch/roll camera, debug camera
  controls, render-microseconds overlay, golden tests. Tracks: A
  `render/raster.zig` + `textures.zig` + clipper tests; B `maze.zig`,
  `camera.zig` (camera only), `scene.zig`, maze tests; C tools
  (`prepare_assets.py`, `preview.mjs --pose`, `check_golden.mjs`,
  `RUNNING.md`). Gate: Adrian flashes it and reports the section 16
  numbers from both poses.
- **M2 Screensaver loop**: autopilot wall follower with eased turns,
  finish detection, PAUSE/RISE/OVERHEAD/DESCEND, maze swap, finish
  marker, name strip, A shortcut. Review point: the rise GIF.
- **M3 Inhabitants**: Snouty billboard wanderer, smiley with roll flip,
  sphere mesh with flat shading and teleport fade, logo quad, LEDs with
  the Select toggle.
- **M4 Polish**: joystick takeover with idle return, `snouty_top` during
  the rise, animated maze carving in OVERHEAD, real art drop-in, hardware
  tuning pass.

## 18. Decisions and open questions

All decided by Adrian on 2026-09-26 (the recommended defaults, with a cap
added to 9):

1. Name "Snouty Maze", repo `snouty-maze`.
2. Maze 12x12 by default; 16x16 is allowed only if the M1 numbers permit.
3. Left-hand wall follower. If the loop feels long, raise the walk speed.
4. Ceiling on.
5. Name strip overhead-only; Start toggles it permanently on or off.
6. Snouty fully replaces the rat.
7. Logo: the Zig mark spins in the OpenGL word's place (Adrian,
   2026-09-27); the Iris mark is its own sheet `iris.png` for the Start
   button and the overhead strip.
8. No audio. LEDs default off, Select toggles them.
9. Smiley flip persists until the finish, capped at 20 s: if no finish
   comes within 20 s the view unrolls on its own.
10. Joystick takeover is in scope, as the last item of M4.
11. Textures 32x32.
12. No rewind gag in this cart.
13. Walk 2 cells/s, pivot 20 ticks; tune from the M2 GIF.

## Status

- 2026-09-26: spec drafted after the feasibility discussion (raycaster vs
  rasterizer; rasterizer chosen so the rise can be real). Placeholder art
  for v1 per Adrian.
- 2026-09-26: section 18 decided (all defaults, 20 s cap on the flip).
  M0 tagged `m0`.
- 2026-09-26: M1 tagged `m1`: real rasterizer, maze generator, fly
  camera, placeholders, golden tests, `docs/preview_m1.gif`. Hardware gate
  (section 16) pending Adrian's flash. Deviations recorded in PLAN.md.
- 2026-09-26: M2 tagged `m2`: autopilot, finish sequence, maze swap, name
  strip, `check_cycle.mjs`, `docs/preview_m2.gif`. The M3 actor renderer
  (`render/mesh.zig`, `render/sprite.zig`) landed early behind
  `debug_actors`. Review point: the rise GIF and the walk/pivot speeds.
