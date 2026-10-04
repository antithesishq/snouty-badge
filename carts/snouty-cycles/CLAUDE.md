# Snouty Cycles

A badge cart for the Software You Can Love (SYCL) conference, built for
Antithesis: a top-down Tron light-cycle arena. You ride a cycle that
leaves a wall; so do up to three AI programs; hit a wall and you derez.
The screen is a function of an 80 x 60 cell grid, drawn incrementally
into the OS's `.copy_forward` framebuffer. `SPEC.md` is the design and
milestone list, `PLAN.md` the current milestone's contract and the status
log. The repository's `CLAUDE.md` has what every cart shares (hardware,
cart API, build wiring); this file adds the cart's specifics.

## Layout

- `cart/src/` (SPEC.md section 11):
  `sim.zig` the rules (grid, cycles, movement, collisions, derez, round
  clock), pure and integer only; `ai.zig` the programs (T1 AVOID in M0);
  `game.zig` the state machine (title, countdown, play, round over,
  pause), pure; `render.zig` the picture, generic over a pixel sink;
  `main.zig` `start`/`update`, the wasm shims, the debug exports and the
  badge-bench hooks; `rng.zig` xorshift streams; `font8.zig` the OS 8x8
  font (generated, do not edit); `host_tests.zig` the root for `zig build
  test`. M1 adds `levels.zig` (the ladder, block layouts), M2
  `history.zig` (keyframes, rewind).
- `tools/` — `check.sh` (the whole gate), `gen_font.py` (writes
  `cart/src/font8.zig` from `sycl-badge/src/font.zig`), `scripts/` (input
  scripts; `bench_m0.json` is badge-bench's). The headless runner
  (`preview.mjs`), `serve-cart.mjs`, `make_gif.py` and `check_float.mjs`
  are shared, in `../../tools/`.
- `docs/` — `RUNNING.md` (pull, build, simulator, flash, previews, gate,
  debug exports), milestone GIFs.
- `../../badge-bench/carts/snouty-cycles.toml` — badge-bench defaults
  (1800 frames, autopilot poked on: title, A, a round, a crash, the next
  round).

## Interfaces (for the M1 tracks)

Module boundaries: `sim` imports nothing of the cart; `ai` reads `sim`;
`render` reads `sim` (and `iris`, `font8`); `game` drives `sim` and `ai`
and builds `render.View`s; only `main` touches the cart API. Nothing but
`World.step`/`init`/`set_heading` writes a World.

- **`sim.World`** (about 38 KB: a static, never on the stack; the cart's
  stack is 32 KB). `w.init(cfg, seed)` in place starts a round: rim,
  cycles on their start cells (`starts`, facing the centre).
  `w.step(inputs: [4]Input)` advances one tick (1/60 s) and refills
  `w.events[0..w.n_events]`. Read-only helpers: `at(x, y)`,
  `next_cell(x, y, dir)`, `free_run`, `log_at(i, k)` (k-th newest trail
  cell, 0 = head), `log_from_tail(i, k)`, `planned_dir(i)` (heading after
  queued turns), `will_step(i)` (crosses into its next cell this coming
  step), `alive_mask()`, `hash()` (FNV over the rule state; M3's CRC),
  `same_state(a, b)`. Fields to read: `grid` (row-major, `index(x, y)`),
  `cycles[i]` (`x`, `y`, `dir`, `state`, `p`, `speed`, `crash`, `killer`,
  `kills`, the M1 fields `rubber`, `energy`, `stalled`, `grind`), `tick`,
  `result` (`running`, `won` + `winner`, `draw` + `timed_out`), `cfg`.
- **Cell values** (SPEC 3): 0 empty, 1..4 trail of cycle 0..3, `rim`
  0x40, `block` 0x41; bit 7 (`fx_bit`) is the renderer's, rules mask it.
  `is_wall(v)`, `trail_owner(v)`.
- **Units**: progress `p` and `speed` are in 1/65536 cell
  (`tuning.one`); base speed `68 << 8` = 16 cells/s. Every rule constant
  is in `sim.tuning`, including M1's (grind, energy, rubber, sudden death).
  Per-round options are `sim.Config` (`n_cycles`, `speed_pct`,
  `round_cap`; M1/M2 flags `grinding`, `rubber`, `energy`,
  `sudden_death`, `layout`, `wrap`, `snake_len`, `gaps`, unused in M0).
- **`sim.Input`**, one byte: `press` (`none`, `up`, `right`, `down`,
  `left`: the d-pad direction newly pressed this tick), `boost` (A held),
  `brake` (B held). The planned heading again does nothing, its opposite
  queues a safe U-turn, the queue is two deep.
- **Step order** (`World.step`): presses into the queues; per alive cycle
  speed update (M1's boost/brake/grind go in `update_speed`), `p +=
  speed`, at a cell boundary apply one queued turn and pick the target
  (M1's rubber stall goes there, marked); `resolve` collisions after all
  moves in index order; `update_result`; fade dying trails. Once the
  result is latched, alive cycles freeze and only fades run.
- **Events** (`sim.Event`: `kind`, `cycle`, `x`, `y`, `a`, `b`):
  `painted` (cycle entered x, y), `cleared` (a faded cell), `crash` (a =
  `Crash`, b = killer or `no_cycle`), `turn` (a = new `Dir`), `block` (M1:
  a cell became a block). More than `max_events` (48) sets `events_lost`
  and the renderer repaints everything. Anything that changes how a cell
  looks must emit an event: the renderer only repaints what events name.
- **`ai.decide(brain, world, i) Input`**: call every tick for each
  program before `step`; it decides once per cell (`brain.decided` holds
  the trail position) on the tick `will_step` is true, at the cycle's
  current speed. `ai.Brain` (`tier`, `rng`, `reaction`,
  `mistake_permille`, `vision`) is small and plain (M2 keyframes copy
  it); `Brain.init(tier, seed)`. Every `Tier` plays T1 until M1 fills in
  `wander`, `territory`, `search` (the switch in `decide`). `ai.flood(w,
  x, y, cap)` and `open_neighbours` are reusable; the fill's scratch is
  module state, so `ai` is not reentrant.
- **`render.Renderer(S)`**: `S` has `put(x, y, c: u16)` (DisplayColor
  bits, `render.rgb(0xRRGGBB)`) and `mark_dirty(Rect)`. `r.reset()` (the
  cart's instance is `undefined` in .bss: a `.{}` literal would put the
  19 KB overlay in .data), `r.invalidate()` (full repaint next frame),
  `r.frame(&world, view)` once per update. `render.View` = `banner:
  ?Banner` (up to 4 `Line`s of 20 characters, a scale and colour each,
  optional Iris mark, vertical centre `cy`), `hud: Hud` (left and right
  text in y 0..7), `heads: bool`. Colours live in `render.colors`.
- **`game.Game`** (holds the World: a static). `g.init(seed)`,
  `g.update(held, pressed: Buttons)` once per tick, `g.view()` for the
  renderer; `g.repaint` asks main for a full repaint (main clears it).
  `g.autopilot`: 0 the player drives, 1 T1 drives, 2 T1 with slips.

## Rendering rules that are easy to break

- **Mark every write.** `.copy_forward` sends only the marked dirty rect
  to the LCD. Every primitive marks a rect covering its puts. A missed
  mark looks fine in the simulator and leaves the badge stale;
  `tools/check.sh lcd` (badge-bench `--lcd` vs the framebuffer) and the
  render host test (puts against marks, pixel by pixel) catch it.
- **The picture is a function of the grid.** `cell_colors` derives a
  cell's four pixels from its value, its neighbours (floor glow), the
  owner's state (dying trails dim) and trail age (the three newest cells
  of a live trail run hot). Transients (heads; M1's sparks and particles)
  are erased by `repaint_rect` over their last rect, never by saved
  pixels. The render host test checks incremental frames against a full
  repaint every 50 ticks; keep it passing when adding looks.
- **Banners are an overlay.** `load_banner` rasterises the box into `ov`
  (shadow, Iris, line inks); `put_cell` and the head sprites go through it
  inside the box, so nothing under a banner forces a redraw. A banner
  whose text changes repaints its box (about 1-3 ms for a big one); a
  colour-only change repaints just those lines (the title's blink).
- **Order per frame**: erase heads, set the banner, apply the World's
  events (once per World tick), draw heads, the HUD if it changed.
- `cell_colors` reads an empty cell's four neighbours without bounds
  checks: the rim guarantees them. M2's WRAP (no rim) must change that
  and `World.next_cell`.

## Target hardware (SYCL Badge V2)

- RP2354B, Core 1 runs the cart, Cortex-M33 at 150 MHz. Integer only in
  the cart; `f64` must not appear (`zig build check-float
  -Dcart=snouty-cycles`).
- Screen 160x128 RGB565, column-major `cart.framebuffer[x][y]`. The arena
  is y 8..127 (80 x 60 cells of 2x2 px), the HUD y 0..7.
- RAM cart only. M0: `.text` 40 KB, `.bss` 77 KB (World 38 KB, AI fill
  scratch 19 KB, banner overlay 19 KB).
- No audio, neopixels off (never written). The OS owns Start+Select and
  the joystick click; the cart ignores Start and Select while both are
  held.
- Budget: worst calibrated badge-bench frame <= 12 ms.

## Building

From the repository root (`../..`):

```
export PATH="$HOME/.local/bin:$PATH"
zig build -Dcart=snouty-cycles          # zig-out/firmware/snouty-cycles.{uf2,elf}, zig-out/bin/snouty-cycles.wasm
zig build test -Dcart=snouty-cycles     # host tests (this cart + lib/)
zig build check-float -Dcart=snouty-cycles
```

Then from this directory: `tools/check.sh` (the whole gate; steps can be
named: `tools/check.sh cycle bench`). `-Ddebug_overlay=true` shows the
render time in the HUD's right corner. This cart's `build.zig` is a
module (`pub fn add`) called by the root `build.zig`.

## Simulator and preview

Same shims as every cart (`present_wasm`, `read_controls`). Headless:

```
node ../../tools/preview.mjs ../../zig-out/bin/snouty-cycles.wasm --seed 7 --frames 1720 --every 4 \
    --out out/gif --call debug_autopilot:2 --press A:90-91
python3 ../../tools/make_gif.py out/gif docs/preview_m0.gif --scale 2 --ms 67
```

The debug exports are listed in `docs/RUNNING.md` section 6;
`tools/check.sh` depends on their names. The firmware exports
`snouty_cycles_seed` and `snouty_cycles_autopilot` for badge-bench
`--poke` (a command-line `--poke` replaces the toml's `pokes`, so repeat
the autopilot one).

## Conventions and gotchas

- Zig style follows upstream (`zig fmt`; this toolchain's `zig fmt`
  rewrites `@intFromEnum`/`@enumFromInt` to `@backingInt`/
  `@fromBackingInt`). No `**` array repetition (use `@splat`), no
  `@Vector` in comptime tables, light comptime (the colour tables and
  floor columns are the only comptime loops).
- Big state (World, Game, Renderer) lives in statics and is initialised
  in place; host tests use file-level statics too.
- Randomness only through `rng.zig`: `game.seeds` makes round seeds,
  each `Brain` has its own stream advanced only by its decisions, and
  `World.seed` is kept for M1/M2 (gaps). The seed comes from
  `cart.rand()` once in `start()` (mixed with the microsecond clock on
  the badge), so `preview.mjs --seed` reproduces runs.
- Commit messages: short imperative subject, body explains why. Milestone
  hand-off: tag `snouty-cycles/<m>`, a GIF in `docs/`, merge to `main`
  once `tools/check.sh` is green (the lead merges M0).
