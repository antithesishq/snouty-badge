# Running the Snouty Pipes cart

The cart lives in `carts/snouty-pipes/` of the snouty-badge repository: a
clone of the Windows 3D Pipes screensaver (`SPEC.md`). Commands below run
from that directory unless noted; only `zig build` runs from the repository
root (`../..`), and its outputs are in the root `zig-out/`
(`../../zig-out/...` from here).

## 1. Prerequisites

Zig `0.17.0`, Node.js 20+, Python 3 (with Pillow for
GIFs) and git: see [`docs/RUNNING.md`](../../../docs/RUNNING.md) at the
repository root, sections 1 and 2. badge-bench needs Python 3.9+ with the
`venv` module and makes its own environment on first run.

## 2. Get the code

Milestones merge to `main` on GitHub as soon as their gate is green, so the
latest build is always `main`:

```sh
git clone --recursive git@github.com:antithesishq/snouty-badge.git   # first time
cd snouty-badge
git checkout main && git pull && git submodule update --init         # every time after
```

Milestones are annotated tags (`git tag -n1 'snouty-pipes/*'`);
`git checkout snouty-pipes/m1` gives the M1 build.

## 3. Build and test

From the repository root:

```sh
zig build -Dcart=snouty-pipes                 # firmware + wasm (plain `zig build` builds every cart)
zig build test -Dcart=snouty-pipes            # host tests: grid walk, director, tracers, teapot, camera
zig build check-float -Dcart=snouty-pipes     # fails if f64 soft-float code reached the firmware
```

`zig build -Dcart=snouty-pipes` writes, in the root `zig-out/`:

- `zig-out/firmware/snouty-pipes.uf2` (for the badge, a RAM cart)
- `zig-out/firmware/snouty-pipes.elf` (the same program, for badge-bench)
- `zig-out/bin/snouty-pipes.wasm` (for the simulator and the headless tools)

`-Ddebug_overlay=true` starts with the debug overlay on and lets Select
toggle it (section 4).

The whole gate, from `carts/snouty-pipes/`:

```sh
tools/check.sh                  # build, test, check-float, teapot, goldens, cycle, bench, lcd
tools/check.sh golden cycle     # just those steps
```

`tools/check.sh` steps (its header has the details):

| Step | What it checks |
|---|---|
| `build`, `test`, `float` | the three `zig build` commands above |
| `teapot` | `tools/gen_teapot.py --check`: the committed `cart/src/render/teapot_mesh.zig` matches the generator |
| `golden` | `tools/check_golden.mjs`: fixed seeds at fixed ticks, pixel exact against `tests/golden/*.png` |
| `cycle` | `tools/check_cycle.mjs`: boot, grow, scene end, dissolve, teapot, determinism, the controls, the nametag and its coin flip, and steer mode (enter, a scripted run, crash -> rewind -> crash -> game over, A again, Select out), on the debug exports |
| `bench` | badge-bench, calibrated, `badge-bench/carts/snouty-pipes.toml` (boot, growth, A at 400 forces a dissolve, the next scene): worst `busy ms` frame <= 12 ms (`BENCH_MAX_MS`), on seed 1 plus timing-only runs on seeds 2..10 (`BENCH_SEEDS` overrides); plus the steer run `tools/scripts/bench_steer.json` (3100 frames: a long run, crash + rewind, game over, A again, Select out, the nametag) |
| `lcd` | the M1 run and the steer run, each with and without `--lcd`, a PNG every 10th frame: the modelled badge LCD must equal the framebuffer in every one |

Why `lcd`: the cart never redraws the screen. The OS keeps the last frame
(`.copy_forward`) and sends only the marked dirty rect to the LCD, so a
pixel the cart writes without `mark_dirty_rect` stays in the framebuffer,
where the simulator shows it, but never reaches the badge's screen.
`badge-bench --lcd` models what the LCD receives.

## 4. Controls

The screensaver runs by itself and never needs input: pipes grow, a scene
ends when 45% of the grid is full (or nothing fits, or after 75 s), the
screen dissolves in 4x4 blocks and a new scene starts from another view.
The strip "SNOUTY PIPES" / "SELECT: STEER" with the Iris mark shows for
the first 2 s of every scene.

| Input | Action |
|---|---|
| A | New scene now (dissolve) |
| B | Nametag strip on/off: "ADRIAN HATCH" / "ANTITHESIS" beside the Iris mark, in the boot strip's style; it stays up through new scenes, orbits and speed changes until B again (entering steer mode hides it) |
| Up / Down | Growth speed 1x / 2x / 4x / 8x |
| Left / Right | Orbit the camera 45 degrees; the same pipes regrow fast from the new angle |
| Start | Pause / resume |
| Select | Steer mode (below) |
| Select + B | Debug overlay (fps, primitives, cells filled), only in a `-Ddebug_overlay=true` build |

The Iris mark on either strip flips like a coin about its vertical axis
45 ticks after the strip appears and every 5 s after that (one turn in
half a second, the grey back face past a quarter turn).

### Steer mode (M3)

Select dissolves into a run: an 8 x 8 x 8 play box seen from a fixed
three-quarter view, its back edges and floor grid outlined, two autopilot
pipes and yours, in silver. READY holds everything for a moment, then your
pipe grows by itself, 3 cells/s at first and 1 cell/s faster every 15
cells, up to 8.

| Input | Action |
|---|---|
| Up / Down / Left / Right | Turn that way on screen at the next cell centre (a press is buffered, two deep; a held direction keeps applying; a reversal is ignored) |
| A / B | Dive into / come out of the screen |
| Start | Pause / resume |
| Select | Back to the screensaver |

The mapping is screen-relative: the grid axis most aligned with the view
is A/B, of the other two the one most aligned with the screen's
horizontal is Left/Right, the last Up/Down. Blinking yellow brackets mark
your pipe's tip and a grey spot on the floor shows where it is over the
floor. Top left: your score (cells) and the rewind token `<<` (cyan while
you still have it).

Hitting a pipe or the wall crashes (CRASH!). The first crash of a run
rewinds time 6 of your cells: the scene regrows from its history up to
that moment ("<< REWIND"), then READY and play on, everything else exactly
as it was. The second crash ends the run: the card shows SCORE and this
session's BEST; A plays again, Select goes back to the screensaver.

The OS owns Start+Select (exit, or on newer firmware its settings box over
the running cart) and the joystick click (its FPS overlay); while Start and
Select are both held the cart reacts to neither.

The teapot: in mixed mode 1 turn in 300 is a Utah teapot, at most one per
scene (SPEC section 7). `--call debug_force_teapot` (section 6) makes the
next turn one. No button changes the joint style (B is the nametag):
each screensaver scene picks mixed, elbows only or balls only at random,
like the original's "Cycle" joint type, so teapots show only in mixed
scenes.

## 5. Web simulator

Terminal 1, from `carts/snouty-pipes/`, serves the cart and live-reloads it
after every `zig build`:

```sh
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/snouty-pipes.wasm on :2468
```

Terminal 2 runs the simulator UI:

```sh
cd ../../sycl-badge/simulator
npm install                                # first time
npm run dev
```

Then open <http://localhost:1234>.

| Badge            | Keyboard           |
|------------------|--------------------|
| Joystick         | Arrow keys or WASD |
| Joystick click   | Shift              |
| A                | Z or K             |
| B                | X or J             |
| Start            | Enter or Y         |
| Select           | Backspace or T     |
| System menu      | Escape             |

`cart/src/main.zig` works around two upstream simulator quirks, as every
cart here does: `present_wasm()` copies each frame to the region at 0x20
that the simulator shows (pre-swapping red and blue), and
`read_controls()` reads the simulator's button word at 0x04. The
simulator's frame rate says nothing about the badge's, and it shows the
whole framebuffer, so it cannot show a missed dirty rect (section 3, `lcd`).
The simulator build uses a fixed seed (the same pipes every reload); the
badge build mixes the microsecond clock into its seed.

## 6. Headless preview and the review GIF

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-pipes.wasm --frames 1080 --every 6 --out out/preview
python3 ../../tools/make_gif.py out/preview docs/preview_m1.gif --scale 3 --ms 100
```

`preview.mjs` runs `start()` and then `update()` N times (one update = one
60 Hz tick), writing every K-th frame to `out/preview/frame_XXXX.png` plus
`frames.json`. Useful options (the tool's header lists all):

- `--seed N`: seed for `cart.rand()`; the same seed gives the same pipes
- `--press A:400-400`, `--script tools/scripts/bench_m1.json`: buttons per
  tick (inclusive ranges; `A B START SELECT UP DOWN LEFT RIGHT`)
- `--call debug_force_teapot`, `--call debug_set_seed:7`: call a debug
  export after `start()`
- `--dump-exports debug_state,debug_scene,debug_filled` and
  `--expect "debug_scene >= 2"`, `--at "230 debug_state == 2"`,
  `--until "debug_scene >= 2"`: read exports, assert, stop early
- `--quiet`: no PNGs (soak runs)

Debug exports (wasm only): `debug_tick`, `debug_state` (0 boot, 1 grow,
2 dissolve, 3 rebuild, 4 steer, 5 rewind, 6 game over), `debug_scene`
(screensaver scenes started, 1 after boot), `debug_filled` (cells filled
this scene or run, walls not counted), `debug_alive`, `debug_pipes`,
`debug_view`, `debug_teapots`, `debug_name_strip`, `debug_cmds`,
`debug_render_us`, `debug_pixel_checksum`, `debug_orbit`, `debug_speed`,
`debug_joint_style` (this scene's: 0 mixed, 1 elbow, 2 ball), `debug_paused`, `debug_history`;
nametag: `debug_nametag` (1 while up), `debug_iris_width` (width the strip's
Iris mark was last drawn at, 24 at rest); steer mode: `debug_steer` (1 in
states 4..6), `debug_score`, `debug_best`, `debug_rewinds_left`,
`debug_crashes`, `debug_head_x/y/z` (the head cell), `debug_steer_map` (3
bits per control, up down left right A B, each a grid direction 0 +x,
1 -x, 2 +y, 3 -y, 4 +z, 5 -z), `debug_heading`, `debug_occupied(x, y, z)`,
`debug_steer_rate` (progress units per tick, 240 a cell); calls
`debug_set_seed(s)`, `debug_force_teapot`. The firmware has one hook for
badge-bench: `--poke snouty_pipes_seed=N` starts from seed N (the wasm
build's seed for `preview.mjs --seed 1` is 270369).

The M1 GIF `docs/preview_m1.gif` was made with the two commands above: seed 1, 18 s at real speed (one GIF frame per 6 ticks): boot with the name strip, scene 1 growing to 45%, the block dissolve at tick 865 and scene 2 from another view.

The M3 GIFs:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-pipes.wasm --seed 1 --frames 1320 --every 3 --start-skip 120 \
    --script tools/scripts/steer_gif.json --out out/preview_m3
python3 ../../tools/make_gif.py out/preview_m3 docs/preview_m3.gif --scale 3 --ms 50
node ../../tools/preview.mjs ../../zig-out/bin/snouty-pipes.wasm --seed 2 --frames 580 --every 3 --start-skip 180 \
    --press B:200-200 --out out/preview_nametag
python3 ../../tools/make_gif.py out/preview_nametag docs/preview_nametag.gif --scale 3 --ms 50
```

`docs/preview_m3.gif` (real time, a GIF frame per 3 ticks): Select, a steer run
played by the bot, a crash into the wall, the rewind regrow, READY, play
on, the second crash and the game-over card. `docs/preview_nametag.gif`:
B puts up the nametag, its Iris mark flips at +45 ticks and again 5 s
later.

### Steer bot: `tools/steer_bot.mjs`

```sh
node tools/steer_bot.mjs --seed 1 --frames 1400 --out tools/scripts/steer_survive.json
node tools/steer_bot.mjs --seed 1 --frames 1700 --idle 700-800 --idle 1150-1700 --out tools/scripts/steer_gif.json
node tools/steer_bot.mjs --seed 1 --frames 3100 --idle 2050-2150 --idle 2400-2700 \
    --press A:2700-2700 --press SELECT:2900-2900 --press B:3000-3000 --out tools/scripts/bench_steer.json
```

Plays steer mode headless through the debug exports (a flood-fill bot:
the free turn with the most room, straight on wins ties), `--idle` ranges
let it crash on purpose, and writes what it pressed as an input script.
The cart is deterministic, so `preview.mjs --script` (same seed) replays
it exactly, and badge-bench does too with `--poke
snouty_pipes_seed=270369`. The three committed scripts come from the
commands above; re-run them after a change to the director moves the
runs (check_cycle M, the steer goldens and the GIF depend on them).

### Golden images: `tools/check_golden.mjs`

```sh
node tools/check_golden.mjs                   # compare every entry
node tools/check_golden.mjs --only grow_s1_t300
node tools/check_golden.mjs --update          # accept the current renders
```

`tests/golden/poses.json` lists `{ name, seed, frames, calls, press }`
entries; each renders through `preview.mjs` into `out/golden/<name>/` and is
compared pixel for pixel with `tests/golden/<name>.png` (a FAIL writes
`diff.png`, differences in red). The picture builds up frame by frame, so a
golden pins the walk, the timing and the renderer together. Only run
`--update` after looking at the new frames.

### Screensaver loop: `tools/check_cycle.mjs`

```sh
node tools/check_cycle.mjs                    # runs A..N
node tools/check_cycle.mjs --only C,E --seed 3
```

Runs A..N are listed in the script's header: boot and name strip, boot to
grow, an unattended scene end with dissolve and a new view, A, a forced
teapot, determinism, pause, the Start+Select chord, orbit, B and speed,
the nametag with its coin flip (K), and steer mode: enter (L), a scripted
run that survives (M), crash -> rewind -> crash -> game over, A again,
Select out (N).

### Teapot mesh: `tools/gen_teapot.py`

`cart/src/render/teapot_mesh.zig` is generated from Newell's Bezier patches
(embedded in the script) and committed, so the build does no comptime work
on it. Change the cuts in the script's `CUTS` table, run
`python3 tools/gen_teapot.py`, and commit both files. To look at the
teapot alone, the host test writes a four-view PPM:

```sh
PIPES_TEAPOT_PPM=/tmp/teapot.ppm zig build test -Dcart=snouty-pipes   # from the repository root
```

## 7. Benchmark (badge-bench)

From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-pipes.elf --symbols          # 720 frames, toml defaults
badge-bench/bench.sh zig-out/firmware/snouty-pipes.elf --lcd --png 10     # PNGs of the modelled LCD
```

Use the `busy ms` column (calibrated against a badge). The budget is
16.7 ms; the gate wants the worst frame at or under 12 ms.

## 8. Flash the badge

As in [docs/INSTALL.md](../../../docs/INSTALL.md): copy
`zig-out/firmware/snouty-pipes.uf2` (repository root) onto the badge's
`SYCLBADGE` drive, eject, and pick `snouty-pipes` in the badge menu.
Start+Select returns to the menu (newer firmware: opens the OS box, "Exit
cart"). A joystick click shows the OS FPS overlay.
