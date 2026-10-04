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

## Deferred questions for Adrian

See SPEC section 14. None block the build.
