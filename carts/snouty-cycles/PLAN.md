# Snouty Cycles: plan

SPEC.md is the design. This file is the contract for the current milestone
and the status log.

Adrian, 2026-10-04: "Let's make a tron lightcycle game ... Spec it and build
it with subagents as appropriate." Every SPEC section 14 default stands until
he overrides one. Milestones run back to back and merge to main once their
gate is green.

Worktree `/home/exedev/snouty-badge-cycles`, branch `cycles/m0`. Build from the
worktree root:

```
export PATH="$HOME/.local/bin:$PATH"
zig build -Dcart=snouty-cycles          # zig-out/firmware/snouty-cycles.{uf2,elf}, zig-out/bin/snouty-cycles.wasm
zig build test -Dcart=snouty-cycles     # host tests (this cart + lib/)
zig build check-float -Dcart=snouty-cycles
```

## M0: a playable slice (one Opus agent)

Goal: a cart you can play in the simulator. You against one T1 program, rounds
looping. It also sets the module boundaries that M1's parallel tracks fill in.

1. **Scaffold.**
   - `carts/snouty-cycles/build.zig` (module `pub fn add`, copy snouty-pipes' shape, `build_options.debug_overlay`, `iris` import).
   - The root `build.zig` cart entry.
   - `CLAUDE.md` for the cart (Pipes' as the model).
   - `.gitignore`, `docs/RUNNING.md`.
   - `badge-bench/carts/snouty-cycles.toml`.
   - Add the cart to the root CLAUDE.md cart list.
   - `main.zig` with the wasm shims (`present_wasm`, `read_controls`) copied from Pipes, `.copy_forward`, vsync 60.
   - Seed from `cart.rand()` mixed with `micros_since_boot` on the badge, plus a `snouty_cycles_seed` export for badge-bench, as Pipes does.
2. **`sim.zig` (pure, host-tested), SPEC sections 3 and 4 minus grinding, rubber and energy.**
   - Leave the fields and hooks for those in place, with `tuning` constants in one struct, so M1 adds behaviour without changing types.
   - Contents:
     - Grid (80x60 bytes; values as SPEC 3) and rim.
     - Cycles (up to 4), 1/256-cell progress, base speed, absolute heading input with a 2-entry turn queue.
     - Safe U-turn on the opposite heading, the one-cell minimum turn gap, the turn tax.
     - Collisions resolved after all moves (wall, same cell = RACE CONDITION, head swap = DEADLOCK).
     - Crash kinds and kill credit.
     - Derez with `wall_stay` and the tail-to-head fade.
     - Trail logs.
     - Round clock and the round result.
   - API shape: `World.init(cfg, seed)`, `World.step(inputs: [4]Input)`, where `Input` is a packed u8 (heading-press 3 bits: none, U, R, D, L; A; B). It returns an event list for the renderer (cell painted, cell cleared, crash at x/y with its kind, turn).
   - The renderer and AI read `World` but never write it.
   - Integer only, no floats in sim.
3. **`ai.zig`: T1 AVOID (SPEC 5).** Capped flood fill per legal move. `decide(world, idx) Input`.
   - Keep a `Tier` enum with T0-T3 and a per-AI state struct (rng stream, reaction delay) so M1 fills in the rest.
   - Use a generation-stamped visited array so nothing is cleared per fill.
4. **`render.zig`, generic over a sink, as Pipes does.**
   - `paint_cell` (floor grid lines every 8 px, trail colours, rim).
   - Full repaint.
   - Head sprite (4x4 with nose) with repaint-from-grid erase.
   - Bright newest-3 trail cells.
   - HUD strip stub (level name, score).
   - Banner text over the arena, erased by repainting the cells under it.
   - Every write marks its dirty rect. A host test checks puts against marked rects.
5. **`game.zig`: the minimal loop.**
   - States: title (text only, any button), countdown 3-2-1-RUN, play, round-over banner (who won, crash name), next round.
   - Start pauses.
   - Ignore Start and Select while both are held.
6. **Debug exports** for the tools:
   - `debug_tick`, `debug_state`, `debug_round`, `debug_alive_mask`.
   - `debug_player_x`, `debug_player_y`, `debug_player_dir`.
   - `debug_render_us`, `debug_pixel_checksum`, `debug_set_seed`.
   - `debug_autopilot(on)`: the player is driven by the T1 AI. Used for the bench, GIFs and survival checks.
7. **Gate, `tools/check.sh`.**
   - Build, host tests, check-float.
   - badge-bench worst busy ms <= 12 on a 900-frame script (autopilot on, rounds looping) plus `--lcd` == framebuffer.
   - A headless `preview.mjs` run reaching round 3 via the debug exports.
   - Goldens are optional in M0.
   - Host tests:
     - Movement and turn queue.
     - U-turn never crashes when one side is free.
     - RACE CONDITION and DEADLOCK.
     - Fade clears the trail.
     - Two `World`s with the same seed and inputs stay byte-identical for 5000 ticks.
     - T1 vs T1 rounds always end (sudden death is M1, so cap rounds at 90 s with a draw in M0).
8. **Hand-off.** `docs/preview_m0.gif`, the PLAN status filled in (bench numbers, sizes), and a list of anything that deviates from SPEC.

Rules for the agent:
- Read the repo `CLAUDE.md` and `carts/snouty-pipes/` (closest template) first.
- Commit on `cycles/m0` in small steps, but do not push and do not tag; the lead reviews and merges.
- Zig rules from the repo CLAUDE.md apply:
  - No f64.
  - No `**` array repetition (use `@splat`).
  - Light comptime.
  - No `@Vector` in comptime tables.

## M1: the game (three Opus tracks)

M0 is merged (tag `snouty-cycles/m0`). M1 runs as three tracks at once, each
in its own worktree and branch, cut from `cycles/m0`:

| Track | Worktree | Branch |
|---|---|---|
| S | `/home/exedev/snouty-badge-cycles-sim` | `cycles/m1-sim` |
| A | `/home/exedev/snouty-badge-cycles-ai` | `cycles/m1-ai` |
| P | `/home/exedev/snouty-badge-cycles-game` | `cycles/m1-game` |

The lead merges them into `cycles/m0` in that order (S, A, P), then runs
the integrated gate.

**File ownership is strict:**
- S owns `sim.zig` and the new `layouts.zig`.
- A owns `ai.zig`.
- P owns `game.zig`, `render.zig`, the new `levels.zig`, `main.zig`, the docs and `tools/`.
- `host_tests.zig` is shared, append-only: one import line per new module.
- Anything outside your own files: write it into your hand-off as a request rather than editing.
- Tracks commit on their own branch (small steps, the repo's message style, `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`).
- Never push, tag or merge.

**One rule for every track: the simulation stays deterministic.**
- AI work budgets count work units (cells visited, nodes searched), never microseconds.
- Rewind (M2) and the link duel (M3) replay the same inputs and must get the same result.
- Calibrate units to time with badge-bench.

### Track S: rules (`sim.zig`, `layouts.zig`)

Each new rule is behind its `Config` flag, and every constant is in `tuning`.

1. **Grinding** (SPEC 4): on entering a cell, check the lateral cells at distance 1 and 2 for trail.
   - Rim and blocks give nothing.
   - The boost decays slowly from above and fast from below.
   - While a distance-1 grind is active, emit `grind` events (cycle, the wall-side cell x/y, a = side dir) once per tick, for P's sparks.
   - `cycles[i].grind` holds the current level, 0..2.
2. **Energy** (SPEC 4): A boosts, B brakes, both from one bar of 0..1000, recharging while neither is held. A cycle with an empty bar gets nothing. The speed cap is 2.2x base.
3. **Rubber** (SPEC 4): a stall at the marked spot, with `stalled` set and a `stall` event each tick (for P's flicker and sparks).
   - A turn queued or pressed during a stall applies at once if that cell is free.
   - The meter is 12 ticks and recharges 1 per 8 ticks. Empty means a crash.
   - The default is `Config.rubber` = 12; HARDCORE (M2) sets 4.
4. **Sudden death** (SPEC 4): `Config.sudden_death`, starting at `tuning.sudden_death_ticks` = 1800.
   - Every 60 ticks the next ring in becomes `block`, but cells that already hold trail stay trail.
   - Each changed cell emits a `block` event, or one event per ring with a = ring index if 48 a tick is too few (agree it with P through the CLAUDE.md interface notes in your hand-off).
   - A cycle on a new block cell crashes with ACCESS VIOLATION.
   - Expose `sudden_death_ring` (0 = not started) for P's banner.
   - It replaces M0's 90 s draw cap when on.
5. **Layouts**: `layouts.zig` is a small table of block layouts (pillars, bars, a cross, a ring with gaps, about 8), drawn into the grid by `World.init` from `Config.layout` (0 = empty arena). Start cells and the 5 cells ahead of each start are always free. Data only, no comptime loops over big arrays.
6. **Helpers for the AI and render tracks:**
   - `ticks_to_step(i)`: ticks until the next cell boundary at the current speed.
   - `speed_fraction(i)`: speed / base x 100.
7. **Host tests:**
   - Each mechanic.
   - Two Worlds staying identical for 5000 ticks with all flags on and random A/B/presses.
   - Rounds with sudden death always end before 1800 + 60 x 30 ticks.
8. Update the Interfaces section of `carts/snouty-cycles/CLAUDE.md` for what you added. This is the one shared file S edits: append only, its own subsection.

### Track A: programs (`ai.zig`)

1. **Tiers per SPEC 5:**
   - **T0 WANDER.**
   - **T2 TERRITORY:**
     - Multi-source BFS Voronoi; score 0.055 x cells + 0.194 x edges, as integer weights.
     - A cut-cell penalty from a 3x3 neighbourhood table. The 256-entry table is generated at host time or written out as data, not comptime-heavy.
     - Aggression toward the player's head.
     - Wall-hugging fill once separated, with the parity bound.
   - **T3 SEARCH:** alpha-beta against the nearest rival, Voronoi leaves in a 32x32 window, iterative deepening within a deterministic node budget.
   - **Fallback:** T1's answer if the budget runs out.
   - Use the energy bar too: T2/T3 boost to win a race for a cut-off and brake when the space ahead is tight. T0/T1 never use it.
2. **Timing:** decide early. Decide on the first tick in a new cell, or when `ticks_to_step` <= 2, and keep the answer for the boundary. The work can be split over the ticks before the boundary; the per-tick work cap is a tuning constant.
3. **Knobs per Brain:** reaction (cells), mistake_permille, vision radius. Expose `ai.preset(tier, level)` for P's ladder, returning a Brain config.
4. **Host tests:**
   - Tournament win rates over 40 seeded rounds each, recorded in your hand-off: T1 > T0, T2 > T1, T3 >= T2 (1v1, empty arena, rubber on).
   - Determinism of decide (same world, same brain, same answer).
   - Budget respected (count work units).
5. **Bench:** add a debug-only autopilot level 3 = T3, requested from P through the hand-off; meanwhile test with a host harness.
   - Measure T2/T3 decision cost with badge-bench using a temporary local poke or a host cycle estimate.
   - Tune the per-tick cap so a frame with three T3s plus rendering stays under 8 ms calibrated.
   - Record the numbers.
6. **Gotcha:** the fill scratch is module state (not reentrant). Keep one scratch, and keep it under 40 KB total.

### Track P: the game around it (`game.zig`, `render.zig`, `levels.zig`, `main.zig`, `tools/`, docs)

1. **`levels.zig`:** the 12-level ladder from SPEC 6 (name, programs with tier and preset level, speed_pct, layout index, sudden death on). It loops after PROD at +10% speed.
2. **Game flow:**
   - Title: the attract round with 4 programs (use T2 once A lands; until then, whatever tier exists), then a menu: GRID LADDER, SKIRMISH (M2: show it greyed out or "SOON"), OPTIONS (M2, same), HOW TO PLAY (one card of controls).
   - Ladder: level intro banner ("LEVEL 6 / C / 1 PROGRAM"), countdown, play, LEVEL CLEAR plus score tally, next level.
   - **Lives** (M1 stand-in for M2's snapshots): 3 pips in the HUD. A derez costs one, and the level restarts. At 0 the game ends with a CORE DUMPED card: score, level reached, session high score in RAM. A level clear gives a life back, up to a maximum of 3.
   - Pause menu: RESUME / RESTART LEVEL / QUIT.
3. **HUD (y 0..7), with at least a 2 px margin from the screen edges** (Adrian flagged edge-touching UI on Zero): level name, score, energy bar, life pips. Keep it legible at 8x8.
4. **Effects:**
   - Grind sparks from `grind` events (1-3 px, life 4-8 ticks).
   - Stall flicker plus sparks from `stall`.
   - A derez particle burst (16 particles, 40 ticks).
   - Sudden-death ring drawn red, with a SUDDEN DEATH banner when `sudden_death_ring` goes 0 to 1.
   - Crash-name banners (SEGFAULT, DEREZZED, OUT OF BOUNDS, ACCESS VIOLATION, RACE CONDITION, DEADLOCK). Show the player's own crash big; programs' crashes as a small tag near the crash for 30 ticks.
   - Every transient is erased by `repaint_rect` (CLAUDE.md rendering rules). Keep the render host test (incremental == full repaint) passing.
5. **`main.zig`:** debug exports for the ladder bot (`debug_level`, `debug_lives`, `debug_set_level(n)`, `debug_score`, `debug_autopilot` levels 0-3, where 3 is T3 once A lands).
6. **Ladder bot = the content gate** (`tools/ladder_bot.mjs` or a check.sh step): with autopilot 3, each level 1..12 is cleared within 3 lives on at least 4 of 5 seeds (`debug_set_level` jumps there).
   - Until A lands, wire it with T1 and expect failures on later levels; the lead re-runs it after integration.
   - Also refresh `tools/check.sh` (the bench script now plays ladder levels 1, 6 and 12 with sudden death), the toml, and `docs/RUNNING.md`.
7. **Preview GIF** `docs/preview_m1.gif`: title, menu, a level, sparks, a derez, level clear.

### Integration (lead)

- Merge S, then A, then P into `cycles/m0`.
- Run the whole gate plus the ladder bot with T3.
- Run badge-bench on levels 1, 6 and 12. Worst frame 12 ms or less.
- Tag `snouty-cycles/m1`, merge to main, push.

## Status

- 2026-10-04: SPEC written from the prior-art research (SPEC section 1). M0 started.
- 2026-10-04: **M0 done** on `cycles/m0` (not merged, not tagged; the lead
  reviews). Items 1-8 built: scaffold and wiring, `sim.zig`, `ai.zig` (T1),
  `render.zig`, `game.zig`, debug exports, `tools/check.sh`, the hand-off
  below. `carts/snouty-cycles/CLAUDE.md` has an "Interfaces" section for
  the M1 tracks.
  - Gate `tools/check.sh`: PASS (build, test, float, font, cycle, bench, lcd).
  - Host tests: 22 (sim 10, ai 4, render 2, game 4, rng 1, the root), plus
    `lib/`'s. They cover the turn queue, the U-turn from 300 random spots,
    every crash kind, RACE CONDITION, DEADLOCK in and out of step, the
    fade, the turn tax, T1 rounds ending (15 of 20 by a crash, mean 71 s),
    two Worlds identical for 5000 ticks, every put inside a marked rect
    and incremental frames equal to a full repaint (2400 ticks, banners
    coming and going and blinking), the game loop to round 3, pause and
    the Start+Select guard.
  - badge-bench (calibrated, toml run: 1800 frames, autopilot 2): busy ms
    mean 0.36, p95 0.64, worst 4.28 at frame 0 (the title's first frame:
    full repaint under the big title box); a round start's full repaint
    2.40 (frames 60, 1576), the crash frame 2.93 (1426: the dead trail
    repaints dim, the YOU LOSE box goes up), a plain tick ~0.3 (0.27 of it
    the OS's copy-forward memcpy), the four-program attract ~1.1. Seeds
    2..6: worst 4.28, means 0.37-0.38. `--lcd` == framebuffer on all 360
    compared frames.
  - ELF: `.text` 40,320, `.data` 12, `.bss` 76,816 (World 38 KB with
    32 KB of trail logs, AI fill scratch 19 KB, banner overlay 19 KB);
    UF2 236 KB (the RAM image includes .bss). Wasm 333 KB.
  - `docs/preview_m0.gif`: seed 7, title and attract, A, countdown, a
    round on autopilot 2, the program boxes itself in, SEGFAULT, YOU WIN.

### M0 deviations from SPEC and this plan

- Units: progress and speed are 1/65536 cell, not 1/256 (same values;
  the extra bits let the 1/512 decay and the 0.95 turn tax be integers).
- U-turn: accepted only with an empty queue (it takes two turns), and its
  reverse half is skipped when blocked while carrying on sideways is free.
- Head-on: a cycle stepping into the head of a facing cycle that has not
  moved this tick is DEADLOCK for both (no credit), not DEREZZED, so a
  head-on never depends on which cell boundary came first.
- Trail logs: a 4096-entry ring per cycle (32 KB of the World).
- Banners: the box is an overlay mask (computed, not saved pixels) over
  the dimmed arena; cells and heads under it go through the mask, so it
  never redraws when something passes under it. Erasing is still by
  repainting cells.
- Countdown banner: the digit and the level name only ("3" / "PASCAL"),
  narrow so the start cells stay visible; RUN at scale 2 for 40 ticks.
- Looks added: floor pixels next to a wall glow in its colour; a dead
  cycle's wall dims until it fades.
- Title: already over an attract round (four T1 programs) with the Iris
  mark; PLAN asked for text only. M1 swaps in T2 and the menu.
- Pause: Start resumes, B quits to the title (M1's menu replaces it).
- Scoring: SPEC 6's kill 500, self-crash 250 (not RACE/DEADLOCK) and
  1000 x level (3) per round won; no high score yet.
- Autopilot has levels (0 off, 1 T1, 2 T1 slipping 8% of decisions into a
  random free cell); the firmware poke `snouty_cycles_autopilot` sets it.
  A Brain's `mistake_permille` slip is a random move into a free cell.
- Bench run: 1800 frames, not 900, so a crash and the next round's full
  repaint are in it with the slipping autopilot.
- Memory: 117 KB of RAM image at M0 against SPEC's "about 120 KB for the
  whole cart". M2's keyframes will pass it; the RAM window is 307 KB, so
  the real limit is ~250 KB.
- Goldens: none in M0 (optional).

### Notes for the M1 tracks

- `ai.decide` decides on the tick `will_step` predicts at the current
  speed. Once grinding or boost change speed between ticks, a prediction
  can miss and the cycle goes straight through a cell undecided; decide a
  tick or two early (or on the first tick of each cell) when adding T2/T3.
- The renderer repaints only what events name: sudden death's ring and
  layouts must emit `block` events (or call `invalidate`), and sparks or
  particles need their rects erased like the heads' (`repaint_rect`).
- `cell_colors` and `bare_floor` read empty cells' neighbours without
  bounds checks (the rim guarantees them); WRAP (M2) must change both and
  `World.next_cell`.

## Deferred questions for Adrian

See SPEC section 14. None block the build.
