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

## M1-M3

Planned after M0 lands. The track split will be sim (grinding, rubber, energy,
sudden death, layouts), AI (T0, T2, T3, budget), and game/presentation (ladder,
score, title and attract, menus, effects, HUD), plus a ladder bot as the content
gate.

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
