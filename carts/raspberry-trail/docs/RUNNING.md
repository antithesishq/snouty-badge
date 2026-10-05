# Running The Raspberry Trail

The cart lives in `carts/raspberry-trail/` of the snouty-badge repository:
a faithful port of the 1978 MECC BASIC listing of the wagon-trail game
(`reference/oregon.bas`, `SPEC.md`) to the SYCL badge. Commands below run
from that directory unless noted; only `zig build` runs from the
repository root (`../..`), and its outputs are in the root `zig-out/`.

## 1. Prerequisites

Zig `0.17.0-dev.1936+5a625d5f3`, Node.js 20+, Python 3 (with Pillow for
the generators and GIFs) and git: see the root
[`docs/RUNNING.md`](../../../docs/RUNNING.md), sections 1 and 2.
badge-bench makes its own Python environment on first run.

## 2. Get the code

```sh
git clone --recursive git@github.com:antithesishq/snouty-badge.git   # first time
cd snouty-badge
git checkout main && git pull && git submodule update --init         # every time after
```

Milestones are annotated tags (`git tag -n1 'raspberry-trail/*'`).

## 3. Build and test

From the repository root:

```sh
zig build -Dcart=raspberry-trail              # firmware + wasm
zig build test -Dcart=raspberry-trail         # host tests: the engine and the UI
zig build raspberry-trail-oracle -Dcart=raspberry-trail   # the oracle's engine runner
```

Outputs, in the root `zig-out/`:

- `zig-out/firmware/raspberry-trail.uf2`: for the badge (a RAM cart)
- `zig-out/firmware/raspberry-trail.elf`: the same program, for badge-bench
- `zig-out/bin/raspberry-trail.wasm`: for the simulator and the headless tools

The whole gate, from `carts/raspberry-trail/`:

```sh
tools/check.sh                 # build test gen oracle preview bench size
tools/check.sh preview bench   # just those steps
```

| Step | What it checks |
|---|---|
| `build`, `test` | the `zig build` commands above |
| `gen` | the committed generated files match their generators (`gen_font.py --check`, `gen_art.py --check`) |
| `oracle` | the engine against the unmodified listing run by `tools/oracle/basic.py`: `compare.py` (every named script) and `fuzz.py --games 2000 --seed 1` (2000 random games plus the coverage report; `ORACLE_FUZZ_ARGS` overrides) |
| `preview` | headless wasm runs without a trap: an autoplayed game (frames in `out/check/game/`), plain A presses (`tools/scripts/press_a.json`), a starvation, the careful autoplayer until it arrives, the hunting autoplayer for 8 shots |
| `bench` | badge-bench, calibrated, on autoplayed games (seeds 1-3 fast, 4 at a human pace, 5 hunting; 3000 frames each): worst `busy ms` <= 8 (`BENCH_MAX_MS`), mean <= 3 (`BENCH_MEAN_MS`) |
| `size` | `size -A`: `.text` + `.data` + `.bss` (+ unwind tables) <= 160 KB (`SIZE_MAX_KB`) |

## 4. Flash it

Copy `zig-out/firmware/raspberry-trail.uf2` to the badge as the root
[`docs/INSTALL.md`](../../../docs/INSTALL.md) describes. A game lasts while
the cart runs: the badge OS has no save storage for carts.

## 5. Controls

The screen, top to bottom: the HUD (the date and the mileage as the
original last printed them, then `F` food, `B` bullets, `C` clothing, `M`
miscellaneous supplies, `$` cash), the trail strip (the wagon at the true
mileage; the ticks are South Pass and the Blue Mountains), the log (what
the program printed, word-wrapped, a dated divider per turn, your answers
in raspberry), and at the bottom either `A: MORE` or the prompt box.

| Screen | Input | Action |
|---|---|---|
| Title | A | Start a game (seeded from the clock at that press) |
| Reading | A | Next page (`A: MORE`); after the last page the prompt appears |
| Any game screen | Select | The log history (released, not pressed): Up/Down scroll (held: repeat), A, B or Select close it |
| Menu (YES/NO, choices) | Up / Down, A | Move the cursor (held: repeat), pick |
| Amount | Left / Right | Move the caret to a higher / lower place |
| Amount | Up / Down | Add / subtract at the caret's place (carries; clamped to what you can spend; held: repeat after 0.4 s, 10 per second) |
| Amount | B, A | Back to the default, enter |
| Shooting | the cued buttons | `GET READY`, then the word appears with one button per letter (arrows, A, B): press them in order. A press before the cue is a misfire, a wrong button misses (the original's wrong word). Time is counted from the cue: seconds = frames / 60 x 0.75 (`shot_time_scale`), capped at 10 s |
| End | A | Back to the title |

Start and Select together belong to the OS (exit, or its settings box):
no button does anything while both are held. The joystick click belongs to
the OS too.

## 6. Web simulator

Terminal 1, from `carts/raspberry-trail/`:

```sh
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/raspberry-trail.wasm on :2468
```

Terminal 2:

```sh
cd ../../sycl-badge/simulator
npm install                                # first time
npm run dev
```

Open <http://localhost:1234>. Keys: arrows or WASD (joystick), Z or K
(A), X or J (B), Enter or Y (Start), Backspace or T (Select).

## 7. Headless preview and the GIF

`--raw-colors` shows the cart's own framebuffer as the badge does (the
default shows what the simulator's compositor would).

```sh
node ../../tools/preview.mjs ../../zig-out/bin/raspberry-trail.wasm --seed 11 --frames 4720 --every 20 \
    --raw-colors --script tools/scripts/gif.json --call-at "131 debug_autoplay:1" --out out/gif
python3 ../../tools/make_gif.py out/gif docs/preview_m1.gif --scale 2 --ms 200
```

That is `docs/preview_m1.gif`: A on the title, YES to the instructions,
then the autoplayer plays a whole game (a starvation for seed 11).

`--call debug_autoplay:V` (or `--call-at "T debug_autoplay:V"`) hands the
buttons to the autoplayer (`cart/src/ui/autoplay.zig`), which presses them
through the same input path as a player: V's bits 0-1 are the pace (1
human, 2 fast; the shooting cue keeps human reaction times), bits 4-5 the
policy (0 normal, 1 careful: plenty of food and clothing, arrives most
games; 2 starve: buys no food; 3 hunter: hunts whenever it can). It plays
game after game. Examples: 1 (human, normal), 18 (fast, careful), 34
(fast, starve), 50 (fast, hunter).

Debug exports (wasm only): `debug_frame`, `debug_screen` (0 title, 1 game,
2 log history), `debug_phase` (0 paging, 1 prompt, 2 GET READY, 3 the cue,
4 the shot's result), `debug_prompt_kind` (0 yes_no, 1 number, 2 choice,
3 shoot, 4 game_over), `debug_prompt_line` (the BASIC INPUT line),
`debug_turn`, `debug_mileage` (shown), `debug_mileage_true`, `debug_food`,
`debug_cash`, `debug_cursor`, `debug_value` (the spinner), `debug_answers`,
`debug_shots`, `debug_shots_hit`, `debug_shots_wrong`, `debug_misfires`,
`debug_games_started`, `debug_games_over`, `debug_arrivals`,
`debug_deaths`, `debug_outcome` (the last finished game's `Outcome`: 1
arrived, 2 starved, 3 no money for a doctor, 4 no medical supplies, 5
pneumonia, 6 injuries, 7 winter, 8 massacred, 9 snakebite),
`debug_log_rows`, `debug_autoplay(V)`, `cart_framebuffer_address`.

## 8. badge-bench

```sh
../../badge-bench/bench.sh ../../zig-out/firmware/raspberry-trail.elf --no-config \
    --poke raspberry_trail_autoplay=2 --poke raspberry_trail_seed=1 --frames 3000 --symbols
```

`raspberry_trail_autoplay=V` lets the autoplayer play from the title, game
after game (V as above); `raspberry_trail_seed=N` seeds game k with N + k
instead of the clock. The badge emulator runs about 25 frames a second.
