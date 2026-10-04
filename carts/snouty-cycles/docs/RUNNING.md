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
```

| Step | What it checks |
|---|---|
| `build`, `test`, `float` | the three `zig build` commands above |
| `font` | `tools/gen_font.py --check`: `cart/src/font8.zig` matches the OS font |
| `cycle` | headless runs on the debug exports: autopilot with slips reaches round 3; the same seed twice gives the same World hash and screen; with no input after A the first round still ends |
| `bench` | badge-bench, calibrated, `badge-bench/carts/snouty-cycles.toml` (1800 frames: title, A, a round on autopilot, the crash, the next round): worst `busy ms` frame <= 12 ms (`BENCH_MAX_MS`), on seed 1 plus seeds 2..6 (`BENCH_SEEDS`) |
| `lcd` | the toml run with and without `--lcd`, a PNG every 5th frame: the modelled badge LCD must equal the framebuffer in every one |

Why `lcd`: the cart never redraws the whole screen. The OS keeps the last
frame (`.copy_forward`) and sends only the marked dirty rect to the LCD,
so a pixel written without `mark_dirty_rect` stays in the framebuffer,
where the simulator shows it, but never reaches the badge's screen.

## 4. Controls

The title shows "SNOUTY CYCLES" over an attract round of four programs.
A (or B, Start, Select) starts a match: you (cyan) against one program
(orange, T1 AVOID; ladder level 3, PASCAL), rounds looping.

| Input | Action |
|---|---|
| D-pad | Heading, absolute: press a direction to turn that way at the next cell. The opposite direction is a safe U-turn (toward the side with more room, then back). Two presses queue. During the 3-2-1 countdown a press sets your first heading |
| A / B (hold) | Boost / brake (M1; ignored in M0) |
| Start | Pause; Start again resumes, B quits to the title |
| Select | Starts a match from the title; nothing in play |

Hit any wall and you derez; the banner names the crash (SEGFAULT: your
own trail, DEREZZED: another trail, OUT OF BOUNDS: the rim, RACE
CONDITION: two cycles into one cell, DEADLOCK: head-on). A dead cycle's
wall dims, stays 3/4 s, then fades from tail to head. The last cycle
riding wins the round; after the banner the next round starts. A round
that reaches 90 s is a draw (M1's sudden death replaces that).

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
node ../../tools/preview.mjs ../../zig-out/bin/snouty-cycles.wasm --seed 7 --frames 1720 --every 4 \
    --out out/gif --call debug_autopilot:2 --press A:90-91
python3 ../../tools/make_gif.py out/gif docs/preview_m0.gif --scale 2 --ms 67
```

`docs/preview_m0.gif` (real time, a GIF frame per 4 ticks): the title
over the attract round, A, the countdown, a round on autopilot against
the program, which boxes itself in and segfaults, YOU WIN.

`preview.mjs` runs `start()` and then `update()` N times (one update = one
60 Hz tick). Useful options: `--seed N`, `--press A:90-91`, `--script
FILE.json`, `--call debug_autopilot:2`, `--dump-exports NAME,...`,
`--expect "debug_round >= 3"`, `--until "..."`, `--sample NAME,...
--sample-every K` (its header lists all).

Debug exports (wasm only): `debug_tick`, `debug_state` (0 title, 1
countdown, 2 play, 3 round over, 4 paused), `debug_round` (0 on the
title), `debug_alive_mask` (bit i: cycle i riding; cycle 0 is you),
`debug_player_x`, `debug_player_y`, `debug_player_dir` (0 up, 1 right, 2
down, 3 left), `debug_score`, `debug_wins`, `debug_losses`,
`debug_world_tick`, `debug_world_hash`, `debug_render_us`,
`debug_pixel_checksum`; calls `debug_set_seed(s)` (restart on the title
with seed s) and `debug_autopilot(level)` (0 off, 1 T1 drives you, 2 T1
with random slips, so rounds end in tens of seconds rather than a
minute). The firmware has two hooks for badge-bench: `--poke
snouty_cycles_seed=N` and `--poke snouty_cycles_autopilot=2`.

## 7. Benchmark (badge-bench)

From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-cycles.elf --symbols          # 1800 frames, toml defaults
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
