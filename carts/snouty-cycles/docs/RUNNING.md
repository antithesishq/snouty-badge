# Running the Snouty Cycles cart

The cart lives in `carts/snouty-cycles/` of the snouty-badge repository: a
top-down Tron light-cycle arena (`SPEC.md`). Commands below run from that
directory unless noted; only `zig build` runs from the repository root
(`../..`), and its outputs are in the root `zig-out/` (`../../zig-out/...`
from here).

## 1. Prerequisites

Zig `0.17.0-dev.1936+5a625d5f3`, Node.js 20+, Python 3 (with Pillow for
GIFs) and git: see [`docs/RUNNING.md`](../../../docs/RUNNING.md) at the
repository root, sections 1 and 2. badge-bench needs Python 3.9+ with the
`venv` module and makes its own environment on first run.

## 2. Get the code

Milestones merge to `main` on GitHub once their gate is green, so the
latest build is always `main`:

```sh
git clone --recursive git@github.com:antithesishq/snouty-badge.git   # first time
cd snouty-badge
git checkout main && git pull && git submodule update --init         # every time after
```

Milestones are annotated tags (`git tag -n1 'snouty-cycles/*'`). Before
M0 merges, its branch is `cycles/m0`.

## 3. Build and test

From the repository root:

```sh
zig build -Dcart=snouty-cycles                 # firmware + wasm (plain `zig build` builds every cart)
zig build test -Dcart=snouty-cycles            # host tests: rules, AI, renderer, game loop
zig build check-float -Dcart=snouty-cycles     # fails if f64 soft-float code reached the firmware
```

`zig build -Dcart=snouty-cycles` writes, in the root `zig-out/`:

- `zig-out/firmware/snouty-cycles.uf2` (for the badge, a RAM cart)
- `zig-out/firmware/snouty-cycles.elf` (the same program, for badge-bench)
- `zig-out/bin/snouty-cycles.wasm` (for the simulator and the headless tools)

`-Ddebug_overlay=true` shows the render time (µs) in the HUD's right
corner instead of the score.

The whole gate, from `carts/snouty-cycles/`:

```sh
tools/check.sh                  # build, test, float, font, cycle, bench, lcd, ladder
tools/check.sh cycle bench      # just those steps
tools/check.sh ladder           # only the ladder bot (the content gate)
```

| Step | What it checks |
|---|---|
| `build`, `test`, `float` | the three `zig build` commands above |
| `font` | `tools/gen_font.py --check`: `cart/src/font8.zig` matches the OS font |
| `cycle` | headless runs on the debug exports: through the menu into the ladder, the slipping autopilot reaches level 3; the same seed twice gives the same World hash and screen; with no input 3 derezzes rewind and the 4th is CORE DUMPED; `debug_set_level 12` starts PROD with four cycles; a forced derez (`debug_force_crash`) rewinds 2 s and resumes on the World hash a straight run had at that tick (levels 8 and 12, the second with every OPTIONS modifier on); a SKIRMISH match reaches its card |
| `bench` | badge-bench, calibrated: the toml run (`badge-bench/carts/snouty-cycles.toml`, 3600 frames: title, menu, level 1 on autopilot 3 through sudden death, a forced derez and rewind at World tick 900) plus ladder levels 1, 6 and 12 poked straight in (`BENCH_LEVELS`, seed `BENCH_SEED` = 2), each with a forced rewind at tick 1500 (`BENCH_CRASH_AT`), and a SKIRMISH match of 3 ASM programs (`BENCH_SKIRMISH`): worst `busy ms` frame <= 12 ms (`BENCH_MAX_MS`) in each |
| `lcd` | the toml run and the level-12 run with and without `--lcd`, a PNG every 5th frame: the modelled badge LCD must equal the framebuffer in every one |
| `ladder` | `tools/ladder_bot.mjs`: with autopilot 3 (T3), every level 1..12 cleared with its 3 snapshots on at least 4 of 5 seeds (about 2 s; `--autopilot`, `--levels`, `--seeds`, `--options`, `--json`) |

Why `lcd`: the cart never redraws the whole screen. The OS keeps the last
frame (`.copy_forward`) and sends only the marked dirty rect to the LCD,
so a pixel written without `mark_dirty_rect` stays in the framebuffer,
where the simulator shows it, but never reaches the badge's screen.

## 4. Controls and the game

The title shows "SNOUTY CYCLES" over an attract round of four programs.
Any button opens the menu: GRID LADDER, SKIRMISH, OPTIONS (a star while
any option is on), HOW TO PLAY (one card of controls). Up/Down move, A
or Start selects, B or Select goes back.

**GRID LADDER** (SPEC 6): twelve levels named after programming
languages, BASIC to PROD, then the ladder loops at +10% speed. Each level
opens with its banner ("LEVEL 6 / C / 1 PROGRAM", and the OPTIONS in
play; A skips it), a 3-2-1 countdown and RUN. Be the last cycle riding
to clear it: the tally adds a bonus of 1000 x the level, and a snapshot
comes back (up to 3). From 30 s into a round sudden death closes red
rings in from the rim. Score: 500 for each program you derez, 250 for
each that crashes on its own.

**Snapshots** (Antithesis time travel, SPEC 6 and 9; the HUD's pips):
when you derez with one left, time stops on the crash for a moment
(RESTORING SNAPSHOT), then the round runs backwards: a scanline tint
wipes down the screen, the trails pull back into the cycles newest
first at 3x, crashed programs ride again, and the World clock in the
HUD counts down. The World is then restored exactly as it was 2 s
before your crash (a keyframe plus a replay of your inputs: the
programs are deterministic) and a short 2, 1, RUN resumes it; a
direction pressed during the countdown is your first move. Derez again
within 3 s of resuming and that spot was already lost: the round starts
over from the top (the same round). With no snapshot left a derez is
CORE DUMPED: score, level reached and the session high score; A retries
from BASIC, B returns to the title (it goes back by itself after 20 s).
Pause QUIT ends the game as EXIT 0, with 2000 points for each snapshot
left.

**SKIRMISH**: pick PROGRAMS (1-3), TIER (BASIC, PASCAL, C, ASM: the
tiers T0-T3), ARENA (OPEN or one of the 8 layouts) and SPEED, then
START (or Start). First to 3 round wins; points are Achtung's, +1 for
each cycle you outlive (the HUD shows your round wins as pips and your
points). No snapshots. When you derez the programs ride on and you
watch (hold A to speed it up); each round ends on a card with the
standings, the match on a card with A for a rematch, B for the menu.

**OPTIONS** (the session only, RAM): SPEED (SLOW 80%, NORMAL, FAST
125%), TRAILS (FULL, or SNAKE: walls 200 cells long), GAPS (holes in the
walls), WRAP (no rim, the edges wrap), HARDCORE (rubber 4 and no
snapshots). Left/Right or A change a row. They apply to the ladder and
SKIRMISH from the next round.

| Input | Action |
|---|---|
| D-pad | Heading, absolute: press a direction to turn that way at the next cell. The opposite direction is a safe U-turn (toward the side with more room, then back). Two presses queue. During the intro and countdown a press sets your first heading |
| A (hold) | Boost, from the energy bar in the HUD (white while boosting) |
| B (hold) | Brake, from the same bar (orange while braking); the bar refills while neither is held |
| Start | Pause: RESUME / RESTART LEVEL (back to the level's starting score; SKIRMISH: RESTART MATCH) / QUIT; Start or B resumes |
| Select | Nothing in play |

Riding next to a trail grinds: sparks, and speed. Running into a wall
stalls you a moment first (rubber: the head flickers red), long enough to
turn away. Crashes are named: SEGFAULT (your own trail), DEREZZED
(another trail), OUT OF BOUNDS (the rim), ACCESS VIOLATION (a block or the
sudden-death ring), RACE CONDITION (two cycles into one cell), DEADLOCK
(head-on). Yours is the big banner; a program's is a small tag beside it.

The HUD (2 px from the screen edges): level number and name, snapshot
pips, the energy bar, the score.

The OS owns Start+Select (exit, or on newer firmware its settings box over
the running cart) and the joystick click (its FPS overlay); while Start and
Select are both held the cart reacts to neither.

## 5. Web simulator

Terminal 1, from `carts/snouty-cycles/`, serves the cart and live-reloads
it after every `zig build`:

```sh
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/snouty-cycles.wasm on :2468
```

Terminal 2 runs the simulator UI:

```sh
cd ../../sycl-badge/simulator
npm install                                # first time
npm run dev
```

Then open <http://localhost:1234>. Keys: arrows or WASD (d-pad), Z or K
(A), X or J (B), Enter or Y (Start), Backspace or T (Select). The
simulator build uses a fixed seed; the badge build mixes the microsecond
clock into its seed.

## 6. Headless preview and the review GIF

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-cycles.wasm --seed 3 --frames 1780 --every 2 --start-skip 1370 \
    --out out/gif_m2 --call debug_autopilot:2 --call debug_set_level:7
python3 ../../tools/make_gif.py out/gif_m2 docs/preview_m2.gif --scale 2 --ms 33
```

`docs/preview_m2.gif` (real time, a GIF frame per 2 ticks): C++ on the
slipping autopilot, SEGFAULT, the freeze, the rewind (the tint wiping
down, the trails retracting, the clock running back), 2-1-RUN and a
different ride from there. `docs/preview_skirmish.gif` (seed 11,
`tools/scripts/skirmish_gif.json` with `--call debug_autopilot:2
--every 4`, the round thinned): the menu, SKIRMISH's setup (3 C programs
on PILLARS), ROUND 1, your derez, watching on fast forward, the round
card. `docs/preview_m1.gif` and `docs/preview_m0.gif` are M1's and M0's.

`preview.mjs` runs `start()` and then `update()` N times (one update = one
60 Hz tick). Useful options: `--seed N`, `--press A:90-91`, `--script
FILE.json`, `--call debug_autopilot:2`, `--call debug_set_level:12`,
`--dump-exports NAME,...`, `--expect "debug_level >= 2"`, `--until
"..."`, `--sample NAME,... --sample-every K` (its header lists all).

Debug exports (wasm only; `tools/check.sh` and `tools/ladder_bot.mjs`
depend on these names):

| Export | Value |
|---|---|
| `debug_state` | `game.State`: 0 title, 1 menu, 2 how to play, 3 intro (level or SKIRMISH round), 4 countdown (3-2-1, or 2-1 after a rewind), 5 play, 6 derez (no snapshot left, or time up; SKIRMISH: watching), 7 level clear, 8 CORE DUMPED / EXIT 0, 9 paused, 10 frozen (your derez, a snapshot left), 11 rewind, 12 OPTIONS, 13 SKIRMISH setup, 14 round over, 15 match over |
| `debug_level` | ladder position (1-based; 13 = BASIC on the second loop; 0 off the ladder) |
| `debug_snapshots` (and `debug_lives`) | snapshots left (0..3) |
| `debug_rewinds`, `debug_rewind_target` | rewinds this game, the World tick the last one landed on |
| `debug_score`, `debug_high` | score of this game, session high score |
| `debug_round` | worlds started this game (levels or SKIRMISH rounds; a rewind is not one) |
| `debug_wins`, `debug_losses` | levels cleared, your derezzes this game |
| `debug_mode`, `debug_match` | 0 ladder, 1 SKIRMISH; SKIRMISH round wins (4 bits per cycle, you lowest) and your points above bit 16 |
| `debug_alive_mask` | bit i: cycle i riding (cycle 0 is you) |
| `debug_player_x`, `debug_player_y`, `debug_player_dir` | your head cell and heading (0 up, 1 right, 2 down, 3 left) |
| `debug_sudden_death_ring` | the ring sudden death is laying (0 before 30 s) |
| `debug_tick`, `debug_world_tick`, `debug_world_hash` | updates since start, ticks into the current World, its rule-state hash |
| `debug_render_us`, `debug_pixel_checksum` | render time, framebuffer sum |

Calls: `debug_set_seed(s)` (restart on the title with seed s),
`debug_autopilot(level)` (0 off, 1 T1 drives you, 2 T1 with random slips,
3 T3 SEARCH; kept through reseeds; after a rewind the autopilot rides T1
with slips for 5 s so it does not repeat itself), `debug_set_level(n)` (a
new ladder game at position n: 3 snapshots, score 0, the level's intro),
`debug_force_crash()` (derez now if a ladder round is in play: the rewind
follows), `debug_crash_at(t)` (derez when the World reaches tick t, once),
`debug_options(bits)` (OPTIONS: bits 0-1 speed 0 normal, 1 slow, 2 fast;
2 SNAKE, 3 GAPS, 4 WRAP, 5 HARDCORE; kept through reseeds),
`debug_skirmish(bits)` (a SKIRMISH match: bits 0-1 programs - 1, 2-3
tier, 4-7 arena). The firmware has six hooks for badge-bench: `--poke
snouty_cycles_seed=N`, `snouty_cycles_autopilot=K`,
`snouty_cycles_level=N` (skip the title, start the ladder at N),
`snouty_cycles_crash_at=T` (a derez at World tick T, once),
`snouty_cycles_options=B` and `snouty_cycles_skirmish=B+1` (a SKIRMISH
match instead of the ladder).

The ladder bot (`node tools/ladder_bot.mjs`) runs each level on 5 seeds
from a fresh wasm instance with `debug_set_seed`, `debug_options`
(`--options`, default none), `debug_autopilot 3` and `debug_set_level`,
and reports per level how many seeds cleared it with its 3 snapshots and
how many rewinds each clear took (`--json FILE` for the details).

## 7. Benchmark (badge-bench)

From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-cycles.elf --symbols          # 3600 frames, toml defaults
badge-bench/bench.sh zig-out/firmware/snouty-cycles.elf --frames 3600 --poke snouty_cycles_autopilot=3 \
    --poke snouty_cycles_level=12 --poke snouty_cycles_crash_at=1500         # PROD straight away, a rewind at 25 s
badge-bench/bench.sh zig-out/firmware/snouty-cycles.elf --lcd --png 10     # PNGs of the modelled LCD
```

Use the `busy ms` column (calibrated against a badge). The budget is
16.7 ms; the gate wants the worst frame at or under 12 ms.

## 8. Flash the badge

As in [docs/INSTALL.md](../../../docs/INSTALL.md): copy
`zig-out/firmware/snouty-cycles.uf2` (repository root) onto the badge's
`SYCLBADGE` drive, eject, and pick `snouty-cycles` in the badge menu.
Start+Select returns to the menu (newer firmware: opens the OS box, "Exit
cart"). A joystick click shows the OS FPS overlay.
