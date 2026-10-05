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
tools/check.sh                  # build, test, float, font, cycle, bench, lcd
tools/check.sh cycle bench      # just those steps
tools/check.sh ladder           # the ladder bot (content gate; not in the default list yet)
```

| Step | What it checks |
|---|---|
| `build`, `test`, `float` | the three `zig build` commands above |
| `font` | `tools/gen_font.py --check`: `cart/src/font8.zig` matches the OS font |
| `cycle` | headless runs on the debug exports: through the menu into the ladder, the slipping autopilot plays 3 attempts; the same seed twice gives the same World hash and screen; with no input your first life still ends; `debug_set_level 12` starts PROD with four cycles |
| `bench` | badge-bench, calibrated: the toml run (`badge-bench/carts/snouty-cycles.toml`, 3600 frames: title, menu, level 1 on autopilot 3 through sudden death) plus ladder levels 1, 6 and 12 poked straight in (`BENCH_LEVELS`, seed `BENCH_SEED` = 2): worst `busy ms` frame <= 12 ms (`BENCH_MAX_MS`) in each |
| `lcd` | the toml run and the level-12 run with and without `--lcd`, a PNG every 5th frame: the modelled badge LCD must equal the framebuffer in every one |
| `ladder` | `tools/ladder_bot.mjs`: with autopilot 3 (T3), every level 1..12 cleared within 3 lives on at least 4 of 5 seeds (about 2 s; `--autopilot`, `--levels`, `--seeds`, `--json`) |

Why `lcd`: the cart never redraws the whole screen. The OS keeps the last
frame (`.copy_forward`) and sends only the marked dirty rect to the LCD,
so a pixel written without `mark_dirty_rect` stays in the framebuffer,
where the simulator shows it, but never reaches the badge's screen.

## 4. Controls and the game

The title shows "SNOUTY CYCLES" over an attract round of four programs.
Any button opens the menu: GRID LADDER, SKIRMISH and OPTIONS (greyed,
"SOON": M2), HOW TO PLAY (one card of controls). Up/Down move (over the
greyed items), A or Start selects, B or Select goes back.

**GRID LADDER** (SPEC 6): twelve levels named after programming
languages, BASIC to PROD, then the ladder loops at +10% speed. Each level
opens with its banner ("LEVEL 6 / C / 1 PROGRAM"; A skips it), a 3-2-1
countdown and RUN. Be the last cycle riding to clear it: the tally adds a
bonus of 1000 x the level, and a life comes back (up to 3). A derez costs
a life (the HUD's pips) and the level starts again; with none left it is
CORE DUMPED: score, level reached and the session high score; A retries
from BASIC, B returns to the title (it goes back by itself after 20 s).
From 30 s into a round sudden death closes red rings in from the rim.
Score: 500 for each program you derez, 250 for each that crashes on its
own.

| Input | Action |
|---|---|
| D-pad | Heading, absolute: press a direction to turn that way at the next cell. The opposite direction is a safe U-turn (toward the side with more room, then back). Two presses queue. During the intro and countdown a press sets your first heading |
| A (hold) | Boost, from the energy bar in the HUD (white while boosting) |
| B (hold) | Brake, from the same bar (orange while braking); the bar refills while neither is held |
| Start | Pause: RESUME / RESTART LEVEL (back to the level's starting score) / QUIT; Start or B resumes |
| Select | Nothing in play |

Riding next to a trail grinds: sparks, and speed. Running into a wall
stalls you a moment first (rubber: the head flickers red), long enough to
turn away. Crashes are named: SEGFAULT (your own trail), DEREZZED
(another trail), OUT OF BOUNDS (the rim), ACCESS VIOLATION (a block or the
sudden-death ring), RACE CONDITION (two cycles into one cell), DEADLOCK
(head-on). Yours is the big banner; a program's is a small tag beside it.

The HUD (2 px from the screen edges): level number and name, life pips,
the energy bar, the score.

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
node ../../tools/preview.mjs ../../zig-out/bin/snouty-cycles.wasm --seed 6 --frames 2800 --every 5 \
    --out out/gif --call debug_autopilot:2 --press A:60-61 --press A:90-91
python3 ../../tools/make_gif.py out/gif docs/preview_m1.gif --scale 2 --ms 83
```

`docs/preview_m1.gif` (real time, a GIF frame per 5 ticks): the title over
the attract round, the menu, GRID LADDER, BASIC's intro and countdown, a
round on the slipping autopilot with grind sparks, SEGFAULT (a life gone),
the retry, the program boxed in, LEVEL CLEAR with the tally and "+1 LIFE".
`docs/preview_m0.gif` is M0's.

`preview.mjs` runs `start()` and then `update()` N times (one update = one
60 Hz tick). Useful options: `--seed N`, `--press A:90-91`, `--script
FILE.json`, `--call debug_autopilot:2`, `--call debug_set_level:12`,
`--dump-exports NAME,...`, `--expect "debug_level >= 2"`, `--until
"..."`, `--sample NAME,... --sample-every K` (its header lists all).

Debug exports (wasm only; `tools/check.sh` and `tools/ladder_bot.mjs`
depend on these names):

| Export | Value |
|---|---|
| `debug_state` | `game.State`: 0 title, 1 menu, 2 how to play, 3 level intro, 4 countdown, 5 play, 6 derez (your crash or time up), 7 level clear, 8 CORE DUMPED, 9 paused |
| `debug_level` | ladder position (1-based; 13 = BASIC on the second loop; 0 off the ladder) |
| `debug_lives` | lives left (0..3) |
| `debug_score`, `debug_high` | score of this game, session high score |
| `debug_round` | worlds started this game (attempts at levels) |
| `debug_wins`, `debug_losses` | levels cleared, lives lost this game |
| `debug_alive_mask` | bit i: cycle i riding (cycle 0 is you) |
| `debug_player_x`, `debug_player_y`, `debug_player_dir` | your head cell and heading (0 up, 1 right, 2 down, 3 left) |
| `debug_sudden_death_ring` | the ring sudden death is laying (0 before 30 s) |
| `debug_tick`, `debug_world_tick`, `debug_world_hash` | updates since start, ticks into the current World, its rule-state hash |
| `debug_render_us`, `debug_pixel_checksum` | render time, framebuffer sum |

Calls: `debug_set_seed(s)` (restart on the title with seed s),
`debug_autopilot(level)` (0 off, 1 T1 drives you, 2 T1 with random slips,
3 T3 SEARCH, which plays T1 until the M1 AI tiers land; kept through
reseeds), `debug_set_level(n)` (a new ladder game at position n: 3 lives,
score 0, the level's intro). The firmware has three hooks for badge-bench:
`--poke snouty_cycles_seed=N`, `--poke snouty_cycles_autopilot=K` and
`--poke snouty_cycles_level=N` (skip the title, start the ladder at N).

The ladder bot (`node tools/ladder_bot.mjs`) runs each level on 5 seeds
from a fresh wasm instance with `debug_set_seed`, `debug_autopilot 3` and
`debug_set_level`, and reports per level how many seeds cleared it within
3 lives (`--json FILE` for the details).

## 7. Benchmark (badge-bench)

From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-cycles.elf --symbols          # 3600 frames, toml defaults
badge-bench/bench.sh zig-out/firmware/snouty-cycles.elf --frames 3600 --poke snouty_cycles_autopilot=3 \
    --poke snouty_cycles_level=12                                            # PROD straight away
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
