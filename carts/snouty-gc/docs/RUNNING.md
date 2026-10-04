# Running the Snouty GC cart

Snouty GC (`snouty-gc`, subtitle GARBAGE COLLECTION) is a SYCL Badge V2
cart: a Mode 7 combat racer on the Snouty Zero engine (`../SPEC.md`). 60 fps
(`cart.set_vsync_enabled(1000.0 / 60.0)`), one `update()` per frame.

M0 is the fork: Zero's floor, horizon, fog, sprites, camera, font and AI,
retuned for wheels, with no rewind, no thermal bar and no traffic. The cart
boots to a placeholder splash and title (10 s idle starts an AI-only attract
race), a menu (QUICK RACE, SOUND), and a 3-lap race on **Landfill Loop** in
the Dumps league: SNOUTY (you, the purple car) against LEGACY, KIDDIE,
SYSADMIN, ROOTKIT and BOTNET driven by the AI, each on its own chassis
(SPEC 4.2). Every car is Zero's rival machine re-paletted in its racer's
livery until the art track's own cars land in M1. No weapons, armor or
pickups yet. The track: the board road (flattened circuit boards with cable
ruts), wreckage walls, an open pit edge down the east side (leave the road
and the car drops in: SEGMENT FAULT, out for 2 s, then back on the line),
a coolant spill (slippery), the ramp over a pit on the bottom straight, and
the dunes round the west bend (a swell of the floor). Results show the
field in order; Start goes back to the menu.

Controls at M0 (SPEC 5.1):

| Input | Race |
|---|---|
| (nothing) | the throttle is always on |
| Left / Right | steer (rate falls with speed) |
| Down | brake; with Left/Right the powerslide (less grip, faster turn) |
| Down + A, Down + B | do not brake (aim back; the rear weapon and pickups come in M1/M2) |
| Up | BURST: +35% top speed for 1 s, one charge per lap (the pip by BURST) |
| A / B | nothing yet (front weapon M1, pickup M2); A confirms and B backs out in menus |
| Select | nothing yet (hold to look back, M3) |
| Start | pause (Resume, Restart, Quit, Sound) |

Start+Select belongs to the OS (exit, or the settings box on newer
firmware): while both are held the cart reacts to neither. The joystick
click (the OS FPS overlay) is never read. The cart never writes the
neopixels and boots silent.

The cart lives in `carts/snouty-gc/`. Commands below run from that
directory unless noted; `zig build` and `badge-bench/bench.sh` run from the
repository root (`../..`), and build outputs are in the root `zig-out/`.

## 1. Pull and build

```sh
git fetch origin && git checkout gc/spec      # or the tag: git checkout snouty-gc/m0
git submodule update --init sycl-badge
zig build -Dcart=snouty-gc                    # from the repository root
```

This writes `zig-out/firmware/snouty-gc.uf2` (badge, RAM cart: the shipped
artifact), `snouty-gc.elf` (badge-bench, `size -A`) and
`zig-out/bin/snouty-gc.wasm` (simulator). Options: `-Ddebug_overlay=true`
(frame time top right), `-Dsound=true` (sound on at boot),
`-Dcart-mode=xip|both` (an XIP build exists as for every cart; XIP is a
no-go on SYCL hardware and nothing measures it).

The gate is `tools/check.sh` (build, host tests, check-float, generator
determinism, the headless preview runs, badge-bench plain and `--lcd`).
`zig build test-gc -Dcart=snouty-gc` runs this cart's host tests alone
(`zig build test` runs every cart's, and in a fresh worktree the emulator
carts' runners fail on their missing test ROMs).

## 2. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
node ../../tools/serve-cart.mjs   # serves ../../zig-out/bin/snouty-gc.wasm on :2468
```

Terminal 2 runs the simulator UI:

```sh
cd ../../sycl-badge/simulator && npm install && npm run dev
```

Then open <http://localhost:1234>. Keys: arrows/WASD joystick, Z/K = A,
X/J = B, Enter = Start, Backspace = Select.

## 3. Headless preview (no browser)

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 1300 --every 8 --start-skip 140 \
    --call debug_start_race:0 --call debug_set_autopilot:1 --out out/m0/
python3 ../../tools/make_gif.py out/m0/ docs/preview_m0.gif --scale 2 --ms 130
```

`docs/preview_m0.gif` is that run (the autopilot driving SNOUTY from the
grid through the first half lap: the coolant spill, the ramp over its
pit, the dunes; real time).

Input scripts in `tools/scripts/`:

- `m0_race.json` (600 frames): Start at 2 (splash), Start at 10 (title), A
  at 20 (QUICK RACE), then the autopilot's own drive recorded frame by frame
  by `tools/record_script.py` (the race seed comes from the frame counter,
  so the replay is the same race). The badge-bench default.

Debug exports (zero-argument wasm functions for `--dump-exports`,
`--expect`, `--at`, `--until`):

| Export | Meaning |
|---|---|
| `debug_frame`, `debug_render_us` | frames since start; render time (0 in wasm) |
| `debug_pixel_checksum` | sum of all framebuffer words |
| `debug_screen` | 0 splash, 1 title, 2 main menu, 3 race, 4 pause, 5 results |
| `debug_mode` | 0 quick race, 1 attract |
| `debug_follow` | the car this badge draws (0..5, = racer id) |
| `debug_px`, `debug_py`, `debug_heading`, `debug_speed` | followed car: world position, heading (u16 turn), speed in 1/100 px per tick (300 = a WORKSTATION's top speed) |
| `debug_lap`, `debug_progress`, `debug_rank`, `debug_best_lap`, `debug_burst` | followed car: laps done, centerline sample, rank 1..6, best lap ticks, BURST ticks * 256 + charges |
| `debug_phase`, `debug_tick` | 0 countdown, 1 racing, 2 finished; race clock in ticks since GO |
| `debug_wrecks` | cars wrecked right now (waiting for the WATCHDOG) |
| `debug_tile_under` | attribute under the followed car (0 off, 1 surface, 2 wall, 4 coolant, 5 bay, 6 vent, 7 ramp, 8 start, 9/10 sectors) |
| `debug_input` | the race byte human slot 0 got on the last tick |
| `debug_world_size`, `debug_world_sum` | `@sizeOf(World)`; a fingerprint of the world |
| `debug_car_px(i)`, `debug_car_py(i)`, `debug_car_lap(i)`, `debug_car_rank(i)`, `debug_car_racer(i)`, `debug_car_human(i)` | car i (one-argument exports) |
| `debug_set_autopilot(v)`, `debug_start_race(n)` | setup calls (`--call NAME:ARG`): the autopilot drives the player; skip to a Quick Race on track n |

## 4. Flashing

Copy `zig-out/firmware/snouty-gc.uf2` (repository root) onto the badge's
`SYCLBADGE` drive, eject, and pick the cart in the badge menu (see
`../../docs/INSTALL.md`). Start+Select returns to the menu.

## 5. Emulated cycle benchmark

From the repository root (`badge-bench/carts/snouty-gc.toml` sets the
script and 600 frames):

```sh
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --symbols
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --lcd --png 100
```

Read the `busy ms` column. Milestone numbers are in `PLAN.md`.

## 6. Regenerating the data

```sh
python3 tools/build_tracks.py     # Dumps tileset, palette, horizon, Landfill Loop -> assets/gen/, previews -> docs/
python3 tools/record_script.py    # tools/scripts/m0_race.json from the autopilot (after a build)
python3 tools/gen_sin.py          # cart/src/gen/sin.zig
python3 tools/gen_font.py         # assets/gen/font.bin from the SDK font
```

The engine's placeholder sprite sheets (`assets/gen/machine.png`,
`shadow.png`, `fx.png`, `snouty_head.png`) are Zero's, copied
(`../ASSETS_ENGINE.md`); the art track's sheets go in `assets/gen/art/`.
