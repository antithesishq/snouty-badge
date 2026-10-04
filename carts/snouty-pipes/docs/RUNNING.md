# Running the Snouty Pipes cart

The cart lives in `carts/snouty-pipes/` of the snouty-badge repository: a
clone of the Windows 3D Pipes screensaver (`SPEC.md`). Commands below run
from that directory unless noted; only `zig build` runs from the repository
root (`../..`), and its outputs are in the root `zig-out/`
(`../../zig-out/...` from here).

## 1. Prerequisites

Zig `0.17.0-dev.1936+5a625d5f3`, Node.js 20+, Python 3 (with Pillow for
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
| `cycle` | `tools/check_cycle.mjs`: boot, grow, scene end, dissolve, teapot, determinism and the controls, on the debug exports |
| `bench` | badge-bench, calibrated, `badge-bench/carts/snouty-pipes.toml` (boot, growth, A at 400 forces a dissolve, the next scene): worst `busy ms` frame <= 12 ms (`BENCH_MAX_MS`), on seed 1 plus timing-only runs on seeds 2..10 (`BENCH_SEEDS` overrides) |
| `lcd` | the same run with and without `--lcd`, a PNG every 10th frame: the modelled badge LCD must equal the framebuffer in every one |

Why `lcd`: the cart never redraws the screen. The OS keeps the last frame
(`.copy_forward`) and sends only the marked dirty rect to the LCD, so a
pixel the cart writes without `mark_dirty_rect` stays in the framebuffer,
where the simulator shows it, but never reaches the badge's screen.
`badge-bench --lcd` models what the LCD receives.

## 4. Controls

The screensaver runs by itself and never needs input: pipes grow, a scene
ends when 45% of the grid is full (or nothing fits, or after 75 s), the
screen dissolves in 4x4 blocks and a new scene starts from another view.
The name strip "SNOUTY PIPES" with the Iris mark shows for the first 2 s.

| Input | Action |
|---|---|
| A | New scene now (dissolve) |
| B | Joint style: mixed (default: elbows, now and then a ball, rarely a teapot) -> elbows only -> balls only |
| Up / Down | Growth speed 1x / 2x / 4x / 8x |
| Left / Right | Orbit the camera 45 degrees; the same pipes regrow fast from the new angle |
| Start | Pause / resume |
| Select | Debug overlay (fps, primitives, cells filled), only in a `-Ddebug_overlay=true` build |

The OS owns Start+Select (exit, or on newer firmware its settings box over
the running cart) and the joystick click (its FPS overlay); while Start and
Select are both held the cart reacts to neither.

The teapot: in mixed mode 1 turn in 300 is a Utah teapot, at most one per
scene (SPEC section 7). `--call debug_force_teapot` (section 6) makes the
next turn one.

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
2 dissolve, 3 rebuild), `debug_scene` (scenes started, 1 after boot),
`debug_filled` (cells filled this scene), `debug_alive`, `debug_pipes`,
`debug_view`, `debug_teapots`, `debug_name_strip`, `debug_cmds`,
`debug_render_us`, `debug_pixel_checksum`, `debug_orbit`, `debug_speed`,
`debug_joint_style`, `debug_paused`, `debug_history`; calls
`debug_set_seed(s)`, `debug_force_teapot`.

The M1 GIF `docs/preview_m1.gif` was made with the two commands above: seed 1, 18 s at real speed (one GIF frame per 6 ticks): boot with the name strip, scene 1 growing to 45%, the block dissolve at tick 865 and scene 2 from another view.

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
node tools/check_cycle.mjs                    # runs A..J
node tools/check_cycle.mjs --only C,E --seed 3
```

Runs A..J are listed in the script's header: boot and name strip, boot to
grow, an unattended scene end with dissolve and a new view, A, a forced
teapot, determinism, pause, the Start+Select chord, orbit, joint style and
speed.

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
