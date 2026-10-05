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

## M2: time travel and options (two Opus tracks)

M1 is on main (tag `snouty-cycles/m1`). M2 is SPEC section 13's M2: snapshots and rewind, SKIRMISH, the OPTIONS modifiers, HARDCORE. It runs as two tracks, each in its own worktree and branch cut from `cycles/m0`:

| Track | Worktree | Branch |
|---|---|---|
| O | `/home/exedev/snouty-badge-cycles-opts` | `cycles/m2-opts` |
| R | `/home/exedev/snouty-badge-cycles-rewind` | `cycles/m2-rewind` |

The M1 rules carry over:
- **Strict file ownership.** If you need someone else's file, make only the minimal edit and list it in your hand-off.
- **Determinism.** Rewind replays the same inputs and must reach the same World, byte for byte.
- **Workflow.** Commit small steps on your own branch; never push, tag or merge.
- **Gates.** `tools/check.sh` stays green, including the ladder bot. Worst calibrated frame 12 ms or less, and `--lcd` equal.

### Track O: modifiers (`sim.zig`, `layouts.zig`, `render.zig`, `ai.zig` only where a modifier needs it)

The `Config` fields `wrap`, `snake_len` and `gaps` exist but are inert. Make each one work (SPEC 6 OPTIONS), keeping all of them off by default:

1. **SNAKE trails** (`snake_len` > 0, default 200 when on): a trail longer than `snake_len` clears its tail cell, one per step, emitting `cleared` events. Both grinding and the AI see the shorter walls.
2. **GAPS** (Achtung): every 40-80 cells (from the cycle's own rng stream inside World, seeded from `World.seed`), a cycle leaves no wall for 3 cells.
   - The head still occupies its cell, so collisions with heads still happen.
   - The trail log needs a "gap" mark so that fades, rewind and snake handle gaps correctly.
   - Render: gap cells show nothing (plain floor).
3. **WRAP** (Surround): no rim, and cycles wrap at the edges.
   - Fix `next_cell`, `update_grind`'s lookups, `cell_colors`/`bare_floor` neighbour reads (bounds), and the layouts' rim clamp.
   - Sudden death in WRAP closes from the screen edge inwards as before (the first ring is the old rim ring).
   - The AI's BFS and bitboard window must wrap too, or at minimum treat the edge as open. Measure the AI cost.
   - Draw the screen border in a dim dashed style so players see that it is open.
4. **HARDCORE** is only `rubber` = 4 in sim (the game wires it). Nothing to do but test it.
5. **Host tests:**
   - Each modifier.
   - The 5000-tick twin-World determinism test with every modifier on, in random combinations.
   - The render test (incremental frames equal a full repaint) with WRAP, GAPS and SNAKE on.
   - AI tournaments still sane with modifiers on (T2 beats T1).
6. Append an "M2 modifiers (track O)" subsection to the cart CLAUDE.md Interfaces section.

### Track R: rewind, SKIRMISH, OPTIONS menu (`history.zig` new, `game.zig`, `levels.zig`, `main.zig`, `tools/`, docs)

1. **`history.zig`, exact rewind (SPEC 9):**
   - A ring of keyframes every 30 ticks covering at least 4 s, plus the player's input byte per tick and the AI Brains in each keyframe.
   - A rewind to tick T restores the keyframe at or before T and replays to T. Call `ai.reset_pool()` after a restore.
   - Memory budget: 48 KB or less for history. The World is 38 KB (32 KB of it trail logs), so do not keyframe whole Worlds. Keyframe the grid (4.8 KB) and the small per-cycle state, plus the log heads and lengths. The trail logs are append-only rings that keep their old entries, so a restore only resets their heads.
   - Check that a fade or a SNAKE tail clear never overwrites a log entry that a rewind still needs. If one does, keyframe what is needed instead.
   - Host test: run, rewind 120 ticks, replay the same inputs, and the World hash and bytes equal the original run. Repeat over many seeds, with sudden death, layouts and every M2 modifier on.
   - Track O's modifiers will land after you branch. Write the test so it turns them on through `Config`, and it will pick them up at integration.
2. **Snapshots replace M1's lives in the ladder:**
   - 3 per game, shown as pips (snapshot icons).
   - When you derez: freeze for 20 ticks with the crash banner, then REWIND. Trails visibly retract newest-first at 3x speed for the 2 s being undone, driven by `cleared` events from the trail logs or a renderer path you add, with a scanline tint and a REWIND banner. Then the replayed state is restored, the arena repaints, and a short countdown (2, 1, RUN) runs from your restored position.
   - A program's derez is never rewound.
   - With no snapshot left, the game ends with CORE DUMPED.
   - A level clear gives +1, up to a maximum of 3.
   - If a rewind lands within 30 ticks of another crash, that is fine: let the player try again while snapshots remain.
3. **SKIRMISH:** a menu to pick programs (1-3), tier (T0..T3, shown as BASIC / PASCAL / C / ASM), layout (OPEN plus the 8), and speed. Then first to 3 round wins with Achtung scoring (+1 for each cycle you outlive). No snapshots. A match result card, and A for a rematch.
4. **OPTIONS:**
   - SPEED (SLOW 80%, NORMAL, FAST 125%).
   - TRAILS (FULL / SNAKE).
   - GAPS (OFF/ON).
   - WRAP (OFF/ON).
   - HARDCORE (OFF/ON: rubber 4, no snapshots in the ladder).
   - They apply to the ladder and SKIRMISH, are kept for the session in RAM only, and are shown on the level intro when not default.
   - Pass them through `Config`. They do nothing until Track O lands.
5. **Debug exports and tools:**
   - Exports: `debug_snapshots`, `debug_rewinds`, `debug_force_crash` (derez the player now), `debug_options(bits)`.
   - A check that a forced crash rewinds and replays to the same hash as a recorded run, using the debug exports.
   - Add a rewind to the bench script (the rewind frames must stay under 12 ms).
   - Run the ladder bot with snapshots: each level cleared with 3 snapshots on 4 of 5 seeds.
6. **Render:** `render.zig` belongs to Track O in M2. If the retraction needs a renderer hook (a tint, a View field), make the minimal edit and list it.
7. **Previews:** `docs/preview_m2.gif` (a derez, the rewind retracting, the retry) and `docs/preview_skirmish.gif`. Update `docs/RUNNING.md`.

### Integration (lead)

- Merge O, then R.
- Turn every modifier on in R's rewind test and the options.
- Run the full gate and the ladder bot, tag `snouty-cycles/m2`, merge to main, push.

## M2.1 and M3: a fair ladder, then the link duel (two Opus tracks in parallel)

Both tracks start from `cycles/m0` at the M2 merge. Track F merges first.

### Track F: fairness and headroom

Owns `ai.zig`, the `levels.zig` table, `tools/ladder_bot.mjs`, the cart's
`build.zig`, and only the autopilot/pool call order in `game.zig`.

1. **Separate AI pools.** The programs get the same AI pool whether a
   human or the autopilot plays: the autopilot draws from a pool of its
   own (or decides after the programs). The bot then measures what a
   human faces. Keep rewind exactness: `history`'s replay rule and its
   tests must still hold, so update `CLAUDE.md`'s determinism contract.
2. **Retune the ladder** so the honest bot (T3 autopilot) clears every
   level on at least 4 of 5 seeds with snapshots, and on at least 7 of 10
   on seeds 6-15.
   - The curve rises: no later level is clearly easier than an earlier one.
     Report rewinds used per level as the measure.
   - Prefer preset knobs (reaction, mistakes, vision) over swapping tiers,
     and keep PROD the hardest.
   - Report the options-28 ladder; it is not gated.
3. **RAM headroom** for M3: at least 24 KB free under the ~268 KB window
   (`.text`+`.data`+`.bss`).
   - Try ReleaseSmall for the cart (snouty-gc did this), then put hot
     functions back to speed if needed.
   - Shrink `.bss` where it is slack.
   - The bench gate stays at 12 ms worst, including the WRAP runs
     (options 16 and 28 at level 12, and a WRAP SKIRMISH with 3 ASM programs).
4. Run `tools/check.sh` green, then record the status here.

### Track L: link duel (SPEC 10)

Owns a new `net.zig`, the link states in `game.zig`, `main.zig`, the
link wiring in `build.zig` (`lib/link.zig` import), HUD and banner text
in `render.zig`, `tools/check.sh` (a `link` step), and docs.

1. **Lockstep (`net.zig`).** The packet is tick, the inputs for t, t-1 and
   t-2, and the World CRC byte: at most 5 DATA bytes, SLIP escapes
   counted. Input delay is 3 ticks; a stall shows WAITING.
   - **A lost packet** is covered by the redundant inputs, and resent if
     a gap is longer.
   - **A CRC mismatch** ends the round as NO CONTEST and the next round
     resyncs from a fresh seed.
   - **The partner leaving** (session change, or disconnected for more than
     2 s): a T2 program takes their cycle until the round ends, then the menu.
2. **Match flow.**
   - LINK DUEL in the menu, then a waiting screen (searching, handshake,
     connected).
   - The lower nonce is host. The host picks arena, speed and options
     (SKIRMISH's setup) and sends the seed and config; the guest sees them.
   - First to 3 rounds, no snapshots, rematch or menu.
   - Each badge draws itself as cycle 0 colours (blue, you), the
     partner orange. The sim indices stay host = 0 so both Worlds are equal.
3. **Polling.** `l.poll` at the top of `update` and between the sim and
   render (the 8-byte FIFO, docs/LINK.md section 2).
   - The bench runs with no cable: the link must cost under 0.3 ms a frame
     there.
   - The wasm build has the link `.unavailable`: LINK DUEL shows NO LINK
     IN SIMULATOR.
4. **The gate** (`check.sh link`, host test):
   - Two Games on `lib/link_virtual.zig` play 50 rounds with random inputs
     and random modifiers, and no desync.
   - Then with 5% packet loss and random delay: still no desync, or a
     clean NO CONTEST and recovery.
   - Unplug in mid-round hands over to the AI.
5. Write the hardware check for Adrian in RUNNING.md: two badges, the
   UART cable, the snouty-link cart first.

### Integration (lead)

- Merge F, then L. Run the full gate plus `check.sh link`.
- Tag `snouty-cycles/m2.1` after F and `snouty-cycles/m3` after L.
- Merge each to main and push.

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
- 2026-10-05: **M1 done** (tag `snouty-cycles/m1`). Tracks S (rules), P (game) and
  A (programs) merged into `cycles/m0` and integrated by the lead.
  - Integration:
    - P's `compat.brain` shim became `brain()` = `ai.Brain.from(ai.preset(tier, level 0..3), seed)`.
    - Ladder presets moved to A's 0..3 scale (A's suggested table). The attract uses 4x T2 L3; the autopilot T3 L3.
    - `ladder` was added to `check.sh`'s default steps.
  - **Tuning by the lead:** C++ cleared 2 of 5 and RUST 0 of 5 on A's table, so the table was changed:
    - C++ is now 2x T2 L0 (was L1).
    - RUST is now T2 L2 + T2 L1 (was 2x T2 L3).
    - Both now clear 10 of 10 seeds while costing the bot about a life each.
  - Gate `tools/check.sh`: PASS on all steps (build, test, float, font, cycle, bench, lcd, ladder).
  - badge-bench, calibrated busy ms (worst):
    - Toml run: 9.39 at frame 0 (the title's full repaint plus four T2 first decisions).
    - Level 1: 5.68. Level 6: 7.05. Level 12: 7.13. Means 1.2-2.0.
    - `--lcd` equal on 1440 frames.
  - Ladder bot (autopilot T3 L3, seeds 1-5): every level 5 of 5. Levels 4, 7, 8 and 9 cost lives; 10-12 cost none.
  - ELF `.text` 85,312, `.data` 168, `.bss` 94,188: about 180 KB of the ~275 KB RAM window.
  - **M1 Track A numbers** (referenced from `ai.zig`):
    - T2 averages 2,650 work units per decision (about 1.7 ms), capped at 6,000.
    - T3 averages 5,950 units (about 3.3 ms), capped at 8,000.
    - `tick_pool` is 10,000 units per tick, with 2,000 kept for programs deciding on their last tick. A unit is about 0.5-0.6 us.
    - Fallback to T1 happens in about 0.1% of decisions.
    - 1v1 tournaments (40 rounds): T1 v T0 33-6-1, T2 v T1 33-7, T3 v T2 22-18 (23-16-1 on layouts), T3 v T1 36-4.
    - Attract worst frames: 3x T3 6.95 ms, 4x T2 7.12, 4x T3 7.52. AI scratch is 34.9 KB.

- 2026-10-05: **M2 done** (tag `snouty-cycles/m2`). The lead merged Track O
  (modifiers), then Track R (rewind, SKIRMISH, OPTIONS), then R's fix for
  the merge (`daf09a4d`: retract journals GAPS clears, so it undoes them
  exactly).
  - The only merge conflict was the cart `CLAUDE.md`; both sections are kept.
    `levels.Options.snake_len` now reads `sim.tuning.snake_len`.
  - Gate `tools/check.sh`: PASS on every step. That is 79 host tests,
    including rewind exactness under SNAKE, GAPS and WRAP, alone and together.
  - badge-bench, calibrated busy ms, worst:
    - Default runs: toml 9.60 at frame 0, level 1 5.63, level 6 5.49,
      level 12 6.90, SKIRMISH with 3 ASM programs 7.87. `--lcd` is equal.
    - WRAP+GAPS+SNAKE: level 12 9.51, level 6 8.80.
    - WRAP SKIRMISH, 3 ASM programs: 10.19.
  - Ladder bot, options 0: every level passes; levels 4, 8 and 9 are 4 of 5.
  - Ladder bot, options 28 (WRAP+GAPS+SNAKE): JAVA 3/5, RUST 3/5, ZIG 1/5,
    the rest pass. The modifiers are an opt-in challenge, so this is not a gate.
  - ELF `.text` 125,220, `.data` 176, `.bss` 140,188: about 259 KB of the
    ~268 KB RAM window (307 KB less the 32 KB stack). Only ~8 KB is left
    before M3's link code.
  - **Finding from Track R:** M1's ladder bot ran its autopilot before
    the programs, so it took most of each tick's shared AI pool. A human
    faces programs at full strength; with the programs deciding first,
    PROD cleared 0 of 10 seeds. M2.1 fixes the bot and the RAM headroom.

## Deferred questions for Adrian

See SPEC section 14. None block the build.

- **Difficulty curve (M1).** The T3 ladder bot finds ASM, ZIG and PROD easier than C++, JAVA and RUST: two hunting T2 programs gang up, and a lone T3 does not. A human may feel it the other way round. Default: keep the table and tune it after a badge play test.
