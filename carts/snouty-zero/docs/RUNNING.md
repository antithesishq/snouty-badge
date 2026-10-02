# Running the Snouty Zero cart

Snouty Zero (`snouty-zero`) is a SYCL Badge V2 cart: an F-Zero style Mode 7
hover racer set on a planet-sized AI datacenter. 60 fps
(`cart.set_vsync_enabled(1000.0 / 60.0)`), one `update()` per frame.

M0 is the floor renderer: the Cold Aisle map drawn as a per-row affine
floor with four fog banks, a two-layer parallax horizon strip and a free
camera. M1 is the drive: the cart boots straight into a solo 3-lap race on
Cold Aisle (countdown PROVISIONING, 3, 2, 1, DEPLOY), with the Anteater
sprite, rails that bounce, a fall off an open edge or a thermal meltdown
costing a 20-tick hit-stop and a reset to the centerline (the rewind
replaces that in M3), lap and sector counting, and the HUD (lap, clock,
speed, thermal bar). M2 is the race: four named rivals (ARGMAX red,
DROPOUT yellow, BACKPROP green, OVERFIT magenta) and six grey batch
traffic machines, machine collisions, Overclock on Up (costs 250 of the
1000 thermal, needs 100), overclock pads, throttled zones, hot spots,
hops, the rank top-right, the minimap bottom-right, and a results screen
2.5 s after the finish (rank, time, best lap, rewinds, thermal); Start
restarts the race from there. The rewind (B) and the menus arrive with M3.

Controls (SPEC section 4) at M2:

| Input | Race |
|---|---|
| Left / Right | steer (rate falls with speed) |
| A (hold) | accelerate |
| Down | brake; with Left/Right the tight turn (more yaw, less grip) |
| Up | Overclock: 90 ticks of boost for 250 thermal (needs 100 left) |
| Start | on the results screen: new race |
| Select | toggle the minimap size (32 / 48 px) |
| B | rewind arrives with M3 |

The M0 free camera is still there for debugging the floor through the
`debug_set_freecam` export (`--call debug_set_freecam:1`: Left/Right
yaw, A forward, B back, Up/Down height while the race runs unsteered).

Start+Select returns to the badge menu and the joystick click toggles the
OS FPS overlay; both belong to the OS. The cart never writes the neopixels
and boots silent.

The cart lives in `carts/snouty-zero/` of the snouty-badge repository.
Commands below run from that directory unless noted; only `zig build` and
`badge-bench/bench.sh` run from the repository root (`../..`), and build
outputs are in the root `zig-out/` (`../../zig-out/...` from here).

## 1. Prerequisites

Zig, Node.js, Python with Pillow and numpy, git: see `../../docs/RUNNING.md`
at the repository root. The emulated benchmark (section 7) also needs
Python 3.9 or newer with the `venv` module.

## 2. Checkout layout

Cloning the repository with its `sycl-badge/` submodule is described in
`../../docs/RUNNING.md`. Milestones are annotated tags (`git tag -n1
'snouty-zero/*'`).

## 3. Build

From the repository root:

```sh
zig build -Dcart=snouty-zero   # only this cart; plain `zig build` builds every cart
```

Options (all from the root):

| Option | Values (default first) | Meaning |
|--------|------------------------|---------|
| `-Dzero_floor` | `row`, `column` | floor inner loop (SPEC 18 measurement; `row` won in the bench, `column` kept for a hardware check) |
| `-Ddebug_overlay` | `false`, `true` | draws the render time in microseconds and the camera height, top right |
| `-Dsound` | `false`, `true` | initial value of the sound toggle (M3) |
| `-Dcart-mode` | `ram`, `xip`, `both` | RAM cart (the primary) or the execute-in-place variant |

This writes `zig-out/firmware/snouty-zero.uf2` (badge), `.elf` (badge-bench,
`size -A`) and `zig-out/bin/snouty-zero.wasm` (simulator).
`zig build check-float -Dcart=snouty-zero` must pass (integer-only cart);
`zig build test -Dcart=snouty-zero` runs the host tests.

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd carts/snouty-zero
node ../../tools/serve-cart.mjs   # serves ../../zig-out/bin/snouty-zero.wasm on :2468
```

Terminal 2 runs the simulator UI:

```sh
cd ../../sycl-badge/simulator
npm install
npm run dev
```

Then open <http://localhost:1234>. Keys: arrows/WASD joystick, Z/K = A,
X/J = B, Enter = Start, Backspace = Select.

## 5. Headless preview (no browser)

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-zero.wasm --frames 600 --every 10 \
    --script tools/scripts/m0_fly.json --out out/ \
    --dump-exports debug_frame,debug_cam_x,debug_cam_y,debug_cam_yaw
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 170
```

Input scripts live in `tools/scripts/`:

- `m2_player.json` (6000 frames): A held throughout, Up (Overclock) at
  300, Right 330-400, Right+Down 520-600, Left 700-760, Select at 1800
  (large minimap). The badge-bench default from M2 (1500 frames: the
  grid start has every machine on screen).
- `m2_race.json`: `[]`, no input; with `--call debug_set_autopilot:1` the
  autopilot races the rivals to the results screen (about 5800 frames).

- `m1_drive.json` (3600 frames): A held throughout, Right 330-400,
  Right+Down 520-600, Left 700-760: the countdown (200 ticks), the top
  straight, the first corner. The badge-bench default from M1.
- `m0_fly.json` (600 frames, M0): A held throughout, Right 100-220, Left
  350-470. Press Select first (`--press SELECT:0-0`) to get the free camera
  it was written for.

Debug exports (zero-argument wasm functions, usable with `--dump-exports`,
`--expect` and `--at`):

| Export | Meaning |
|---|---|
| `debug_frame` | frames since start |
| `debug_render_us` | render time of the last frame in microseconds; always 0 in wasm |
| `debug_pixel_checksum` | sum of all framebuffer words |
| `debug_cam_x`, `debug_cam_y` | camera world position (0..1023) |
| `debug_cam_yaw` | heading, u16 turn (0 = +x, 16384 = +y) |
| `debug_cam_height` | camera height over the floor |
| `debug_tile_under` | attribute of the tile under the player (0 off, 1 surface, 2 rail, 3 pad, 4 throttled, 5 cold, 6 hot, 7 hop, 8 start, 9/10 sectors) |
| `debug_px`, `debug_py`, `debug_heading` | player world position and heading (u16 turn) |
| `debug_speed` | player speed in 1/100 world px per tick (360 = top speed) |
| `debug_lap`, `debug_progress` | laps completed; nearest centerline sample 0..255 |
| `debug_phase` | 0 countdown, 1 racing, 2 finished |
| `debug_tick` | race clock in ticks since DEPLOY |
| `debug_thermal` | thermal bar 0..1000 |
| `debug_crashes` | crash hit-stops started since boot |
| `debug_best_lap` | best lap in ticks (0 until a lap is done) |
| `debug_rank` | player rank 1..5 |
| `debug_screen` | 0 race, 1 results |
| `debug_machine_px(i)`, `debug_machine_py(i)`, `debug_machine_lap(i)` | machine i (0 player, 1..4 rivals, 5..10 traffic); one-argument exports |
| `debug_set_autopilot(v)`, `debug_set_freecam(v)` | setup calls (`--call NAME:1`) |

## 6. Flashing

1. Put the badge in bootloader mode and connect it over USB-C; it shows up
   as a USB drive.
2. Copy `zig-out/firmware/snouty-zero.uf2` onto the drive.
3. Pick the cart in the badge menu. Start+Select returns to the menu.

## 7. Emulated cycle benchmark

badge-bench (`../../badge-bench/README.md`) runs the ELF on an emulated
Cortex-M33 with the badge-calibrated cycle model; read the `busy ms`
column. `../../badge-bench/carts/snouty-zero.toml` sets the defaults.
From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-zero.elf --script carts/snouty-zero/tools/scripts/m0_fly.json --frames 600 --every 60 --symbols
```

Milestone numbers are in `PLAN.md` under each milestone's status.

## 8. Regenerating the data

```sh
python3 tools/build_tracks.py     # tilesets, horizon strips, every .track -> assets/gen/
python3 tools/gen_sin.py          # cart/src/gen/sin.zig
```
