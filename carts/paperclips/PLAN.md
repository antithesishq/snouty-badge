# Universal Paperclips: plan

Design in `SPEC.md`. Worktree `/home/exedev/snouty-badge-paperclips`,
branch `paperclips/m1`, from origin/main 4ab9e616.

## Milestones

- **M1: stage 1 on the badge.** The human era complete: making and selling
  clips, wire, AutoClippers, MegaClippers, marketing, trust, processors,
  memory, operations, creativity, quantum computing, every stage-1
  project, investments, strategic modeling, all the way to "Release the
  HypnoDrones". Title screen, all stage-1 pages, message ticker and log.
  Past the HypnoDrones the cart shows "Stage 2 arrives in M2" and keeps
  the sim stopped. Merge to main when green: this is what booth visitors
  play anyway.
- **M2: the rest.** Stage 2 (factories, harvesters, wire drones, power,
  swarm), stage 3 (probes, probe design, exploration, drifters, combat,
  honor), the ending (dismantle sequence) and prestige for the session.
  Cheats page behind the title code.
- **M3: polish** after Adrian plays it (deferred questions below).

## Tracks (Opus agents in the one worktree, disjoint files)

All three work in `/home/exedev/snouty-badge-paperclips` on branch
`paperclips/m1`. Each commits only its own paths (`git add <own paths>;
git commit`); if the index is locked, wait and retry. Nobody pushes; the
lead merges.

- **L, the logic port** owns `cart/src/game/**`. Ports `reference/*.js`
  to Zig per SPEC sections 1, 4, 5: all of it, stage 1 first (commit as
  soon as stage 1 runs so U can integrate), then stages 2 and 3, combat and
  the ending. Host tests in `cart/src/game/tests.zig` (formulas, project
  triggers and effects, fmt against JS output), plus an autoplayer test
  that plays stage 1 to the HypnoDrones, and later the whole game to the
  end, within a bounded virtual time.
- **U, the cart and UI** owns `build.zig`, `cart/src/main.zig`,
  `cart/src/ui/**`, `assets/**`, `tools/gen_*.py`, `tools/check.sh`,
  `tools/scripts/**`, `docs/**`, `CLAUDE.md`, and the root registrations
  (root `build.zig` carts list, README.md table, CLAUDE.md cart list,
  docs/INSTALL.md, badge-manager/sets.default.toml). Builds the cart
  shell from `badge-manager/template-cart/` conventions (wasm shims, 60
  fps, `.no_copy_full_frame`), the font, title, pages and controls of
  SPEC section 3, wired to `game/` through the interface below. Until L's
  first commit, U works against its own throwaway stub of the interface.
  `build.zig` gives the cart a `game` module rooted at
  `cart/src/game/game.zig`, adds `cart/src/game/tests.zig` (L's) and
  U's own host tests to `zig build test`, and an
  `oracle` step: `zig build paperclips-oracle` builds
  `tools/oracle_runner.zig` (O's) on the host with the `game` module and
  installs it as `zig-out/bin/paperclips-oracle`.
- **O, the oracle** owns `tools/js_oracle.mjs`, `tools/oracle_runner.zig`,
  `tools/compare.mjs`, `tools/oracle/**`. Runs `reference/*.js` in Node
  (`vm` context, a stub DOM where every `getElementById` returns a
  harmless element and records `innerHTML`/`style.display`/`disabled`,
  `Math.random` = the SPEC RNG, `setInterval`/`setTimeout` = the SPEC
  virtual clock, no `localStorage`), applies an action script, dumps the
  game variables at checkpoints. `oracle_runner.zig` does the same
  through `game/`. `compare.mjs` diffs them (exact for integers and
  flags, relative 1e-12 for floats unless a field is known noisy).
  Also a JS bot that plays the original deep (stage 1 to the HypnoDrones,
  then stages 2-3) to produce long action scripts. O reports mismatches
  to the lead with the first diverging field and ms; L fixes them.

### Interface between `game/` and the rest (L implements, U and O use)

```zig
// cart/src/game/game.zig
pub const Game = struct { ... };   // JS globals as snake_case fields, same meaning
pub fn init(g: *Game, seed: u64) void;        // the page load: globals, projects, timers
pub fn advance_ms(g: *Game, ms: u32) void;    // run the virtual clock ms forward
pub const Action = union(enum) { ... };       // one per onclick handler (+ args), e.g.
    // make_paperclip, lower_price, raise_price, buy_ads, buy_wire,
    // toggle_wire_buyer, make_clipper, make_mega_clipper, add_proc, add_mem,
    // q_compute, buy_project: u8 (index into projects), invest_deposit,
    // invest_withdraw, invest_upgrade, set_invest_strat: enum{low,med,hi},
    // set_strat_pick: u8, new_tourney, run_tourney, toggle_auto_tourney,
    // make_factory, make_harvester: u32, make_wire_drone: u32, ...reboots,
    // make_farm: u32, make_battery: u32, feed/teach/entertain/clad/synch,
    // set_slider: u8 (0..200 like the range input), make_probe,
    // probe_stat_up/down: ProbeStat, increase_probe_trust,
    // increase_max_trust, cheat_*: one per cheat button
pub fn act(g: *Game, a: Action) void;
pub fn enabled(g: *const Game, a: Action) bool;   // the button's !disabled
// Visibility: g.panels.<div_id_snake> : bool for every element the JS
// shows/hides with style.display (business_div, comp_div, q_compute_div...).
// Projects: g.active_projects (display order) of indices into
// projects.defs (title, price_tag, description; dynamic texts via
// projects.title(idx, buf) etc.).
// Messages: g.msgs ring (newest last) + g.msg_count; the 5 console lines.
// Stocks, tournament grid and results, quantum chips, combat ships: plain
// arrays on Game in the units the JS uses.
// The end: g.dismantle, g.end_timer*, g.final_clips as in the JS.
```

L may extend this (more fields, more actions) but not rename what is
listed without telling U and O through the lead.

## Gate (tools/check.sh)

- `zig build -Dcart=paperclips`, `zig build test`.
- Oracle: every script in `tools/oracle/scripts/` matches the JS at every
  checkpoint (`compare.mjs` exit 0). M1: scripts to the HypnoDrones.
- Autoplayer reaches its target (M1: HypnoDrones; M2: the end).
- Headless preview: no trap over a 10-minute scripted run; golden-free,
  but the GIF is looked at.
- badge-bench: `update()` worst under 10 ms, mean under 5 ms (busy ms,
  calibrated) on a late-stage state; `size -A` total under 200 KB.

## Status

- 2026-10-04: SPEC + PLAN written; tracks L, U, O starting.
- 2026-10-05: **M1 and M2 done together** (tag paperclips/m2; paperclips/m1
  on the same commit). The whole game runs on the badge: stage 1, stage 2,
  stage 3, combat, the ending, credits and session prestige; CHEATS page
  behind the title code. `tools/check.sh` PASS:
  - oracle: all 6 scripts MATCH the original JS at every checkpoint
    (short, stage1, stage1b, deep = the whole game to the credits in
    10.2 h virtual, prestige = the next universe, misc = cheats and edge
    clicks). Math is bit-exact with V8 (`game/jsmath.zig` ports V8's
    pow/sin/log), number printing exact (`game/fmt.zig`, 1.1M cases).
  - autoplayer (seed 2026): HypnoDrones 7,880 s, space 12,748 s, credits
    25,891 s virtual; 8 more seeds all reach the credits.
  - badge-bench busy ms (mean / worst): stage-1 pages 2.1-2.6 / 2.6-3.2,
    stage 2 2.30 / 2.82, live stage-3 battle 7.25 / 17.95 (COMBAT page)
    and 5.35 / 16.48 (SPACE), new game's opening battle 6.37 / 28.17.
    Battles must move every ship in exact soft f64 (their positions feed
    the dice), so those three have their own limits (20 / 8, 30 / 8); the
    badge clock follows real time, so only the frame rate dips. Own
    soft-float add/mul/compare (`game/softfloat*.zig`, bit-exact, ~68
    cycles an add vs compiler_rt's ~155).
  - size 172.2 KB (ReleaseSmall).

## Deferred questions (defaults taken)

- Battle frames: kept exact (16-28 ms worst during live stage-3 battles
  and the first seconds of a game). Options if they bother on hardware:
  the RP2350's double-precision coprocessor (DCP) for f64 add/mul (not
  modelled by badge-bench), or single-precision drift for the finished
  battle's flock on the COMBAT page (picture only, mean 7.25 -> ~5 ms).
- After the credits the original offers nothing more; leave through the
  OS chord (Start+Select).

- Saves: none (no OS save region). Default: session only.
- Hold-to-repeat on buy rows (0.4 s, 8/s); none on Make Paperclip.
- Font 5x7 in 6x8 cells. Look: black on white like the original.
