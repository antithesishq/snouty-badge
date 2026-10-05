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
  test`. M1 adds `levels.zig` (the ladder, block layouts; M2 its
  `Options` and SKIRMISH's config), M2 `history.zig` (keyframes, the
  input log, retract and restore).
- `tools/` — `check.sh` (the whole gate), `gen_font.py` (writes
  `cart/src/font8.zig` from `sycl-badge/src/font.zig`), `scripts/` (input
  scripts; `bench_m0.json` is badge-bench's). The headless runner
  (`preview.mjs`), `serve-cart.mjs`, `make_gif.py` and `check_float.mjs`
  are shared, in `../../tools/`.
- `docs/` — `RUNNING.md` (pull, build, simulator, flash, previews, gate,
  debug exports), milestone GIFs.
- `../../badge-bench/carts/snouty-cycles.toml` — badge-bench defaults
  (3600 frames, autopilot poked on: title, A, the ladder, a forced
  derez and rewind at World tick 900).

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

### M1 rules (track S: `sim.zig`, `layouts.zig`)

Every M1 rule is behind its `Config` flag and all are off in a bare
`Config`, so M0's rules hold until the game turns them on. The ladder's
config is `.{ .n_cycles, .speed_pct, .grinding = true, .rubber =
sim.tuning.rubber_max (12; HARDCORE 4), .energy = true, .sudden_death =
true, .layout = n }`.

- **Step order changed**: the speed update now runs *after* the moves
  (per alive cycle: `update_grind`, `update_speed`, rubber recharge), so a
  step moves at the speed set by the previous one and **`will_step(i)`
  is exact** even with grinding and boost. A/B pressed on tick t change
  the speed from tick t+1. Order: inputs, moves (turns, rubber stalls),
  `resolve`, sudden death, grind/speed/rubber, `update_result`, fades.
- **Grinding** (`cfg.grinding`): each tick, per side of the head, a trail
  cell (any cycle's, dying ones too) at lateral distance 1 gives
  `cycles[i].grind` = 2 and a `grind` event; else a trail at distance 2
  behind an empty cell gives 1. Rim and blocks give nothing and shield.
  Acceleration per tick is `tuning.grind1` = 11 / `grind2` = 4 in
  1/1024 of base speed. With `decay_above_shift` = 7 (1/128 of the excess
  per tick; was 9): distance 1 for 1 s = 1.51x, 2 s = 1.83x, cap 2.2x
  after ~4.5 s; off the wall 1.51x falls to 1.31x after 1 s, 1.19x after
  2 s. Distance 2 for 1 s = ~1.18x.
- **Energy** (`cfg.energy`): `cycles[i].energy` 0..1000. A with a
  non-empty bar: target 1.5x, drains 10/tick (1.7 s of boost). B: target
  0.5x, drains 6/tick, eased at the fast 1/8 rate; B wins when both are
  held. Recharges 2/tick only while neither is held (holding A on an
  empty bar gives nothing and no recharge). Cap 2.2x base always.
- **Rubber** (`cfg.rubber` = meter size, 0 = off): at a cell boundary a
  wall ahead with `cycles[i].rubber` > 0 stalls the cycle at `p = one -
  1`, `stalled` = true, rubber - 1, a `stall` event every stalled tick;
  with 0 left the step goes ahead and crashes. During a stall a queued or
  newly pressed turn applies on that same tick if its cell is free and
  is **dropped** if not (press again); a U-turn press resolves to the
  freer side, so it is the quick escape. Recharge 1 per 8 ticks while not
  stalled. Two heads nose to nose both stall, then DEADLOCK.
- **Sudden death** (`cfg.sudden_death`, which also ignores `round_cap`):
  from tick `tuning.sudden_death_ticks` (1800) ring k (1 = next to the
  rim, `sim.ring_of(x, y)`) is laid over the 60 ticks from `1800 + (k -
  1) * 60` by two sweeps going clockwise from the top-left and
  bottom-right corners (symmetric under a half turn). At most 6 cells a
  tick: each empty one becomes `block` with a **per-cell `block` event,
  a = k** (trail stays trail); a head on a swept cell derezzes with
  ACCESS VIOLATION (no credit). `w.sudden_death_ring` = the ring being
  laid (0 before; 0 -> 1 on tick 1800: the banner), up to
  `tuning.sudden_death_rings` = 29, the last; every round ends by tick
  3540. `w.is_sudden_death_block(x, y)` says whether a block is a
  sudden-death one (draw it red); layout blocks inside closed rings count.
- **Layouts** (`cfg.layout`, `layouts.zig`): `layouts.all[i]` = `name` +
  `rects`, `layouts.count` (9: 0 OPEN, 1 PILLARS, 2 BARS, 3 CROSS, 4
  RING, 5 LANES, 6 CORNERS, 7 CHECKER, 8 COLUMNS), `layouts.get(i)` (out
  of range = OPEN). `init` draws them as `block` with each rect mirrored
  across both centre lines and emits no events (the round start's full
  repaint shows them). Start cells and the 5 cells ahead stay free; every
  layout leaves the arena connected.
- **New events** (`EventKind`, appended): `grind` (cycle, x/y = the
  trail cell beside the head, a = the side `Dir`; one per grinding side
  per tick) and `stall` (cycle, x/y = head, a = its `Dir`, b = rubber
  left; one per stalled tick). Worst case per tick stays within the 48.
- **Helpers**: `w.ticks_to_step(i)` (ticks until the next boundary at the
  current speed; 1 iff `will_step`; further out an estimate),
  `w.speed_fraction(i)` (speed as % of the round's base: 100, 150 boost,
  220 cap), `sim.ring_of(x, y)`, `w.is_sudden_death_block(x, y)`.
- `hash()`/`same_state` also cover `rubber_tick`, `stalled`, `grind` and
  `sudden_death_ring`.

### M1 game (track P: `game.zig`, `render.zig`, `levels.zig`, `main.zig`)

- **`levels.zig`**: `table` (SPEC 6's twelve levels: name, programs as
  `{ tier, preset }`, `speed_pct`, `layout` index into `layouts.zig`,
  `sudden_death`), `get(n)` for ladder position n (1-based, loops after
  PROD at +10% speed, layouts shift per loop) returning a `Round` with
  `config()` (every M1 rule on), `number()`, `name()`, `programs()`.
- **`game.State`** (`debug_state`): title, menu, howto, intro, countdown,
  play, derez (your crash or time up; the World runs on), clear (tally,
  a life back up to 3), game_over (CORE DUMPED), paused (RESUME /
  RESTART LEVEL / QUIT). `g.new_game(n)` starts the ladder at n
  (`debug_set_level`, the `snouty_cycles_level` poke); `g.level`,
  `g.lives`, `g.score`, `g.high` (session, RAM only). Autopilot 3 = T3.
  Brains come from `game.compat.brain(tier, preset, seed)`: `ai.preset`
  once Track A lands (it must return an `ai.Brain`), `Brain.init` before.
- **`render.View`** adds `tags` (bit i: cycle i's crash gets a small name
  tag for 30 ticks). **`render.Hud`** is drawn in the 4x5 `font5` at y
  2..6, 2 px from every edge: `left`, `right`, `energy` (null hides the
  bar), `bar_mode` (0 ride, 1 boost, 2 brake), `lives`/`max_lives` pips.
  Banners take up to 8 lines and stay 2 px inside the screen; lines of up
  to 18 characters at scale 1 (9 at scale 2) fit (`Banner.fits`).
- **Effects** (`render.fx`): a pool of 96 dots (grind sparks from `grind`
  events, 1..3 a tick, 4..8 ticks; stall sparks from `stall`; a 16-dot
  derez burst per crash, 40 ticks, 2x2 while hot) and per-cycle crash
  tags (never over a banner). They age once per World tick (they freeze
  with pause), take their randomness from the World's seed and tick, are
  redrawn every frame and erased with `repaint_rect`; `full_repaint`
  draws them from the same state (the render test copies them into its
  fresh renderer). `invalidate` drops them (a new scene). A stalled head
  flickers red.
- **Sudden death** draws blocks on rings 1..`sudden_death_ring` red (odd
  rings brighter: stripes) with a red floor glow; when the ring count
  grows the renderer repaints that ring's strip itself, so layout blocks
  already on it turn red too.

### M2 modifiers (track O: `sim.zig`, `layouts.zig`, `render.zig`, `ai.zig`)

The OPTIONS modifiers (SPEC 6) are `Config` fields, all off in a bare
`Config`. The game sets them: TRAILS SNAKE `snake_len =
sim.tuning.snake_len` (200; FULL = 0), GAPS `gaps = true`, WRAP `wrap =
true`, HARDCORE `rubber = 4` (nothing else in sim), SPEED `speed_pct`.

- **WRAP** (`cfg.wrap`): `init` draws no rim and `next_cell` wraps every
  edge, so turns, the U-turn, grinding and the AI all see a torus. Layouts
  are the same blocks (none reaches the edge). Sudden death closes the old
  rim ring first: **`sudden_death_ring` is now a stage**, stage k closes
  ring `k - 1 + w.sd_first_ring()` (first ring 1, or 0 in WRAP),
  `w.sd_stages()` is 29 (30 in WRAP), `w.sd_stage_of(x, y)` is a cell's
  stage, `block` events carry a = the stage; WRAP rounds end by tick 3600
  (3540 otherwise). The renderer gives an empty edge cell a dim dashed
  outer line (`colors.edge_dash`, 4 px on, 4 px off) and reads glow
  neighbours with bounds checks (no glow across the edge).
- **SNAKE** (`cfg.snake_len` > 0): after a cycle paints its new cell,
  its trail log keeps the newest `snake_len` entries: one tail pop per
  step, a `cleared` event when the popped cell is still its trail. The
  pop comes after the collision check, so a cycle entering that tail
  cell on the same tick still crashes. A dead cycle fades as before.
- **GAPS** (`cfg.gaps`): new `Cycle` fields `gap_rng` (xorshift seeded
  `rng.mix(seed, 0x6A70 + i)` in `init`, advanced once per gap),
  `gap_in` (painted cells to the next gap, 40..80) and `gap_left` (gap
  cells still to lay, `tuning.gap_cells` = 3). A gap cell is painted
  while the head is on it (head collisions still happen) and its log
  entry carries `sim.log_gap` (bit 15); the step that leaves it clears
  the cell (a `cleared` event). Popping a gap entry later (SNAKE, fade)
  clears nothing, unless it is the last entry (the head a dead cycle
  crashed on), so riding back over your own old gap keeps the new wall.
  `log_at`/`log_from_tail` return the cell with the bit masked;
  `w.log_gap_at(i, k)` tells a gap entry (k-th newest).
- **Events**: SNAKE and GAPS add up to one `cleared` per cycle per step
  each (8 a tick at most).
- **AI**: SNAKE and GAPS only change the grid. For WRAP `ai.zig` steps
  neighbours with `nb(wr, at, k)`, specialised at compile time in the
  four hot BFS loops (`fill`, `others_field`, `region`, `chamber_space`),
  so the rim arena runs the M1 code (M1 tournament scores unchanged);
  head distances, the race hold and T3's 32 x 32 window go the short way
  round. `ai.wrapping` is set from the World in `decide`, `avoid`,
  `flood` and `open_neighbours`.
- `hash()`/`same_state` cover the new Cycle fields (`same_state`
  compares whole Cycles). No new `World` field: the three new fields are
  plain `Cycle` state (keyframed with the Cycle).
- **Cost** (calibrated badge-bench worst / mean busy ms, autopilot T3,
  seed 2, measured with a temporary modifier poke): no modifiers L1 5.63,
  L6 6.84, L12 6.88 (M1: 5.68 / 7.05 / 7.13; play is pixel-identical);
  WRAP L1 7.31, L6 9.44, L12 10.37 / 3.83 mean, attract frame 0 10.88;
  WRAP + GAPS + SNAKE L1 7.57, L6 8.80, L12 9.50 / 4.67 mean. WRAP costs
  more because the BFS passes, no longer stopped by a rim, run nearer
  their unit caps (the caps hold: `ai` host test "budgets hold in WRAP").

**What a rewind keyframe must hold (Track R)**: the grid (gap clears and
SNAKE pops change it), each `Cycle` whole (now with `gap_rng`, `gap_in`,
`gap_left`, and `log_head`/`log_tail`), and the World scalars as before.
Log entries are written once, gap bit included, and never changed; SNAKE
pops and fades only advance `log_tail`. So restoring `log_head` and
`log_tail` brings the trail back exactly, as long as the ring has not
overwritten the restored tail's entries (`log_head - restored log_tail <=
log_cap` = 4096 cells; a round is far shorter). Gaps take nothing from
`World.seed` after `init`. A retraction drawn by popping log heads will
not bring back tail cells SNAKE cleared or gap cells (empty once left,
`log_gap_at`); the restore's full repaint shows the true picture.

### M2 time travel and modes (track R: `history.zig`, `game.zig`, `levels.zig`, `main.zig`)

- **`history.History`** (~46 KB, inside `game.Game`): `start(w, brains,
  aux)` at a round's tick 0; `record(w, input, brains, aux)` after every
  ladder play step and every replayed one (the player's input, each
  cycle's trail-log head/tail moves, a journal of `cleared`/`block`
  cells, a keyframe every 30 ticks: 8 kept, 4 s). A keyframe is
  `Rewindable` (World fields copied by name: tick, result, winner,
  timed_out, sudden_death_ring, grid, cycles), the four Brains and the
  game's `Aux` (score, the autopilot's tier deadline). `not_keyframed`
  lists the rest of World with the reason; a test fails if a World field
  is in neither: **a new World field a rewind needs goes into
  `Rewindable` (same name and type), nothing else**. The trail logs are
  not copied: a step only writes at `log_head` and fades/clears only
  move `log_tail`, so restoring the heads in `cycles` restores them; a
  rule that rewrote an old log entry would break this (the exactness
  tests catch it).
- **A rewind**: `plan(now, back)` / `plan_exact(t)` / `plan_start()` set
  `target`; `retract(w, n)` undoes n ticks of the World in place for the
  screen (newest trail cells pop, journaled cells go back, heads slide
  back, a cycle that rides again gets a `crash` event with `Crash.none`)
  and leaves events like a step; `restore(w, brains, aux)` puts the
  keyframe at or before `target` back (forgets later keyframes, calls
  `ai.reset_pool()`); the game replays `input_at(t)` to `target`. After
  the game changes the autopilot at the landing it calls `resave`.
- **Determinism contract**: a replay is exact because the World depends
  only on the Brains, the rules and the player's inputs. The programs
  decide first and alone share the per-tick AI pool (`ai.decide`); the
  autopilot decides after them with `ai.decide_apart`, from a pool of
  its own (`ai.tuning.apart_pool`, capped at `apart_cap` less what the
  programs spent on that tick), so nothing it does reaches a program
  and the programs play the same for you and for the bot (M2.1; until
  M2 the autopilot went first and drained the programs' pool). A
  replay (`step_world(..., logged)`) puts the logged input in and runs
  only the programs, for you and the autopilot alike; the autopilot's
  Brain is not replayed, and the landing gives it a new one
  (`finish_rewind`). Anything else that changes a program's or the
  World's behaviour must be in the World, a Brain or `Aux`.
- **Game flow** (`game.State` appended: 10 frozen, 11 rewind, 12
  options, 13 skirmish_setup, 14 round_over, 15 match_over): your derez
  with a snapshot -> `frozen` (20 ticks) -> `rewind` (retract
  `retract_step` ticks a frame, ~40 frames; then restore + replay with
  `hold_frame` set, which main honours by not drawing) -> `countdown`
  with `resuming` (2-1, then RUN away from you). A derez within 3 s of
  the last landing restarts the round (`restart_round`: same seed and
  Brains). `g.snapshots` replaces M1's lives (HARDCORE: 0); `g.mode`
  ladder / skirmish; `g.opts` (`levels.Options`) apply through
  `Options.apply(cfg)`; SKIRMISH is `g.sk` (`levels.skirmish_config`).
- **The tint** is main's: `g.tinted()` rows from the arena top; main's
  `Screen.mark_dirty` tints each rect the renderer marks (`put` stays a
  plain store: a per-pixel check costs 2 ms on a full repaint) and
  repaints the rows the wipe reaches with `Renderer.repaint_rect` (made
  pub for this). The banner box is never tinted.
- Banner lines go through `add_line` (noinline) and the cold game
  functions are `noinline`: ReleaseFast inlining of them cost ~7 KB of
  .text in a RAM cart (the cart is ReleaseSmall since M2.1).

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
- `cell_colors` reads an empty cell's four neighbours with bounds checks
  (WRAP has no rim, so an empty cell can sit on the screen edge), and
  `bare_floor` never counts an edge cell as bare floor (WRAP's dashes).

## Target hardware (SYCL Badge V2)

- RP2354B, Core 1 runs the cart, Cortex-M33 at 150 MHz. Integer only in
  the cart; `f64` must not appear (`zig build check-float
  -Dcart=snouty-cycles`).
- Screen 160x128 RGB565, column-major `cart.framebuffer[x][y]`. The arena
  is y 8..127 (80 x 60 cells of 2x2 px), the HUD y 0..7.
- RAM cart only. M0: `.text` 40 KB, `.bss` 77 KB (World 38 KB, AI fill
  scratch 19 KB, banner overlay 19 KB). M2 (track R): `.text` ~103 KB,
  `.bss` ~140 KB (History 46 KB more), ~243 KB of the ~275 KB window.
  M2.1: the cart builds **ReleaseSmall** (`build.zig`): `.text` 58 KB,
  ~198 KB in all, 74 KB free. compiler_rt's ReleaseSmall `memcpy` copies
  bytes, so `cart/src/mem.zig` exports a word-wise `memcpy`/`memset`
  (and the `__aeabi_*` entry points) for the badge build: without it
  the API's copy-forward present costs 2.6 ms a frame. Hot render
  helpers (`put_cell`, `dim565`, the raster targets) and the T3
  endgame's per-node helpers (`hug_order`, `free4_t`) are `inline`; a
  new per-pixel, per-cell or per-node helper on a hot path wants the
  same (AI units are calibrated against inlined code).
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
