# Snouty Pipes

A badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a clone of the Windows 3D Pipes screensaver. Pipes grow through
an invisible 12 x 10 x 12 grid, each primitive ray cast per pixel
(analytic cylinders and spheres, sphere-traced elbows, a rasterized Utah
teapot), Phong shaded and dithered. The camera holds still while pipes
grow, so a frame draws only the new pieces into the OS's `.copy_forward`
framebuffer. Select switches to steer mode (M3): one pipe is the
player's, steered screen-relative through a small play box, with a time
rewind on the first crash. `SPEC.md` is the design and milestone list, `PLAN.md` the
current milestone's contract between parallel tracks and the status log.
The repository's `CLAUDE.md` has what every cart shares (hardware, cart
API, build wiring); this file adds the cart's specifics.

## Layout

- `cart/src/` — the Zig cart, one module per concern (SPEC.md section 8).
  `main.zig`: `start`/`update`, the wasm shims, debug exports.
  `grid.zig`: sizes, `Dir`, `Prim` (one cell of one pipe in 32 bits),
  occupancy, the pipe walk (`spawn_in`/`fill_outside` for steer mode's
  play box). `director.zig`: the scene state machine (boot, grow,
  dissolve, rebuild; steer, rewind, game over), spawn and death, joint
  style, speed, the nametag flag, the history ring, and the steer section
  (runners that draw with no lag, snapshots, rewind, the overlay data); it
  emits draw commands that `main.zig` runs through the renderer.
  `steer.zig`: the screen-relative control mapping and the turn queue.
  `camera.zig`: the 8 fitted views plus the 4 steer views, rays (hit t =
  view depth), projection.
  `render/`: `draw.zig` (per-cell drawing, dirty rects, the dissolve, the
  steer box outline and floor grid, steer mode's fatter radii),
  `trace.zig` (ray vs cylinder, sphere, quarter torus), `shade.zig`
  (Phong, palette, 4x4 dither), `zbuf.zig` (u16 z buffer), `teapot.zig` +
  `teapot_mesh.zig` (the easter egg), `overlay.zig` (title strip and
  nametag with the coin-flipping Iris, steer HUD, banner, head marker,
  floor spot, game-over card, debug text). `host_tests.zig` is the root
  for `zig build test`.
- `tools/` — `check.sh` (the whole gate), `check_golden.mjs`,
  `check_cycle.mjs`, `gen_teapot.py` (writes `render/teapot_mesh.zig`),
  `steer_bot.mjs` (plays steer mode headless, writes input scripts),
  `scripts/` (input scripts; `bench_m1.json` is badge-bench's, `bench_steer.json`
  the steer bench run, `steer_survive.json` and `steer_gif.json` check_cycle's,
  the goldens' and the GIF's; all three steer ones come from `steer_bot.mjs`). The headless
  runner (`preview.mjs`), `serve-cart.mjs`, `make_gif.py` and
  `check_float.mjs` are shared, in `../../tools/`.
- `tests/golden/` — golden PNGs and `poses.json` for `check_golden.mjs`.
- `docs/` — `RUNNING.md` (pull, build, simulator, flash, previews, gate),
  milestone GIFs.
- `../../badge-bench/carts/snouty-pipes.toml` — badge-bench defaults (720
  frames: boot, growth, a forced dissolve, the next scene).

## Rendering rules that are easy to break

- **Mark every write.** The cart runs `.copy_forward`: the OS copies the
  last frame forward and sends only the dirty rect to the LCD. Every
  primitive calls `S.mark_dirty` once with a rect that covers every pixel it
  `S.put`s; `cart.text`/`rect` mark their own. A missed mark looks fine in
  the simulator and leaves the badge's screen stale. `tools/check.sh lcd`
  (badge-bench `--lcd` vs the framebuffer, every 10th frame) catches it;
  host tests check puts against the marked rect.
- **Depth.** `zbuf.buf[x][y]` is u16, view depth times `zbuf.scale`,
  smaller is nearer, `zbuf.far` = empty. `camera.ray` has unit length along
  `fwd`, so a hit's ray t is its view depth. Everything drawn z tests, so
  pipes, joints and the teapot intersect cleanly in any order.
- **Overlays sit on a persistent picture.** The overlay saves the pixels
  under itself, restores them first thing next frame, then the director's
  commands draw, then it saves and draws again. Overlays can overlap (the
  head marker passes under the HUD), so `restore` runs in the reverse
  order of `draw`; anything an overlay draws must lie inside its saved
  region (text shadows too). The floor spot reads `zbuf` and draws only on
  empty pixels.
- **Steer runs replay from snapshots.** A rewind restores occupancy, rng,
  history head and the runners, then regrows from the history ring; a
  runner's head cell enters the history only once its exit is known, and
  the regrow draws runner heads only as far as they have got. Anything new
  that a run mutates must go into `Run`/`Snap` or the rewind stops being
  exact (host test "first crash rewinds ...").
- **Sinks.** `draw.zig` and `teapot.zig` are generic over a sink `S` with
  `put(x, y, c: u16)` (DisplayColor bits) and `mark_dirty(camera.Rect)`;
  `main.zig`'s `Screen` writes the framebuffer, host tests use arrays.

## Target hardware (SYCL Badge V2)

- RP2354B, Core 1 runs the cart. Cortex-M33 at 150 MHz, single-precision
  FPU: `f32` add/mul 1 cycle, `/` and `@sqrt` ~14. `f64` is soft-float and
  must not appear (`zig build check-float -Dcart=snouty-pipes`).
- Screen 160x128 RGB565, column-major `cart.framebuffer[x][y]`. Both
  framebuffers are the OS's; the cart's z buffer is its own 40 KB.
- RAM cart only (no XIP). Memory is small: z buffer 40 KB, history ring
  8 KB, teapot tables ~5 KB.
- Inputs as SPEC section 6 (screensaver: A new scene, B nametag,
  Up/Down speed, Left/Right orbit, Start pause, Select steer mode;
  steer: the stick turns on screen, A/B into/out of the screen, Select
  out, A again on the card). The OS owns Start+Select and the joystick
  click; the cart ignores Start and Select while both are held.
- No audio (repo policy for non-emulator carts), neopixels off (never
  written).
- Budget: worst calibrated badge-bench frame <= 12 ms (16.7 ms at 60 fps,
  with headroom). Normal frames draw a few hundred pixels; the dissolve and
  orbit rebuild are spread over ticks.

## Building

From the repository root (`../..`):

```
export PATH="$HOME/.local/bin:$PATH"
zig build -Dcart=snouty-pipes          # zig-out/firmware/snouty-pipes.{uf2,elf}, zig-out/bin/snouty-pipes.wasm
zig build test -Dcart=snouty-pipes     # host tests (this cart + lib/)
zig build check-float -Dcart=snouty-pipes
```

Then from this directory: `tools/check.sh` (the whole gate; steps can be
named: `tools/check.sh golden cycle`). `-Ddebug_overlay=true` starts with
the debug overlay on and lets Select+B toggle it. This cart's `build.zig` is
a module (`pub fn add`) called by the root `build.zig`; running `zig build`
in this directory fails ("import of file outside module path").

## Simulator and preview

Same shims as every cart: `present_wasm()` copies the frame to 0x20 with
red and blue swapped, `read_controls()` reads the button word at 0x04.
Headless:

```
node ../../tools/preview.mjs ../../zig-out/bin/snouty-pipes.wasm --frames 1080 --every 6 --out out/preview
python3 ../../tools/make_gif.py out/preview docs/preview_m1.gif --scale 3 --ms 100
node tools/check_golden.mjs            # golden-image regression
node tools/check_cycle.mjs             # screensaver loop on the debug exports
```

The debug exports (`debug_state`, `debug_scene`, `debug_filled`,
`debug_force_teapot`, the steer and nametag ones, ...) are listed in
`docs/RUNNING.md` section 6; `check_cycle.mjs` and `steer_bot.mjs` depend
on their names. The firmware exports one symbol for badge-bench,
`snouty_pipes_seed` (`--poke snouty_pipes_seed=270369` = the wasm seed of
`preview.mjs --seed 1`), so bench and headless runs of a steer script
match.

## Conventions

- Zig style follows upstream: snake_case functions, 4-space indent,
  `zig fmt`.
- No allocation, no libm at runtime (`math.sin_turns`), no `f64` in the
  cart. Array repetition `**` does not parse in this Zig build; use
  `@splat`.
- No `@Vector` fields or elements in comptime tables (arrays in
  `.rodata`): on thumb, Zig and LLVM disagree on their stride, so entries
  after the first are read misaligned while the wasm build looks fine. Use
  `[3]f32` rows and convert at the use site (`render/teapot.zig`).
- No runtime-indexed `@Vector` lanes (`v[i]` with a runtime `i` does not
  compile for the host tests); switch on the direction instead.
- Light comptime: Adrian's Mac runs out of memory on heavy comptime, so
  data comes from committed generated files (`tools/gen_teapot.py` ->
  `render/teapot_mesh.zig`; re-run it and commit both, `tools/check.sh
  teapot` checks they match).
- Randomness only through `rng.zig`, seeded in `start()` from `cart.rand()`
  so `preview.mjs --seed` reproduces runs; the badge build mixes in the
  microsecond clock because `cart.rand()` reads 0 on the RP2350.
- Goldens: `node tools/check_golden.mjs --update` only after looking at the
  new frames; a director or renderer change moves them all.
- Commit messages: short imperative subject, body explains why.
- Milestone hand-off: tag `snouty-pipes/<m>`, preview GIF in `docs/`, merge
  to `main` and push once `tools/check.sh` is green, and a "pull and run
  this" section in the final message (Adrian reviews in the simulator and
  on the badge).
