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
restarts the race from there. M3 is the game around it: splash, title (10
s idle starts the attract demo: the autopilot races and rewinds), the menu
(Quick Race, Grand Prix, Sound), league and track pickers over six tracks
(Edge: Cold Aisle, Substation Sprint, Exhaust Ridge; Spine: Fiber
Backbone, Rack Row 7, Tape Vault), the pause menu, and the Antithesis
mechanic: hold B to run the race backwards (2 ticks a frame, every other
scanline dark, `<<` by the cyan snapshot bar) while the snapshot bar
drains; it refills 1 tick per 10 and fills at the start line. A crash
(SEGMENT FAULT off an open edge, THERMAL SHUTDOWN, a hard COLLISION)
freezes the world for 20 frames with its cause, then rewinds 120 ticks
automatically if the bar holds 90 (which it costs); with less, JOB KILLED
ends the race with RETIRED on the results. Grand Prix: the league's three
tracks, points 9/6/4/3/2, standings between tracks, a champion line.
M4 adds hills (Exhaust Ridge, Fiber Backbone, Substation Sprint: the
floor rises to a crest and falls away, visual only), the rail-hit shake,
spark bursts and exhaust flames, the blinking horizon LEDs, an own font
blit and a rewind that costs at most 10 replayed ticks a frame. M5 adds
the Core league (Hot Aisle, Kernel Ring, Weights Loop: hot-aisle grating
over orange glow, red haze) and a MACHINE row in the main menu (drive the
Anteater with a rival's physics: ARGMAX fast and slow-turning, DROPOUT,
BACKPROP cornering, OVERFIT brittle; Left/Right or A cycle it). From M5
the cart is an XIP cart: code and data execute from the cart flash
window, maps are stored packed and the selected track is unpacked into
RAM at race start.

Controls (SPEC section 4) at M2:

| Input | Race |
|---|---|
| Left / Right | steer (rate falls with speed) |
| A (hold) | accelerate |
| Down | brake; with Left/Right the tight turn (more yaw, less grip) |
| Up | Overclock: 90 ticks of boost for 250 thermal (needs 100 left) |
| B (hold) | rewind while the snapshot bar lasts |
| Start | pause menu (Resume, Restart, Quit, Sound); confirm in menus |
| Select | toggle the minimap size (32 / 48 px) |
| A | confirm in menus; B backs out |

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
zig build -Dcart=snouty-zero -Dcart-mode=xip   # only this cart; plain `zig build` builds every cart (XIP for this one)
```

The cart builds as an XIP cart only (M5): `-Dcart=snouty-zero` without
`-Dcart-mode=xip` stops with a message saying so.

Options (all from the root):

| Option | Values (default first) | Meaning |
|--------|------------------------|---------|
| `-Dzero_floor` | `row`, `column` | floor inner loop (SPEC 18 measurement; `row` won in the bench, `column` kept for a hardware check) |
| `-Ddebug_overlay` | `false`, `true` | draws the render time in microseconds and the camera height, top right |
| `-Dsound` | `false`, `true` | initial value of the sound toggle (M3) |
| `-Dcart-mode` | `xip` (`both` builds the same) | the cart is XIP only; `ram` named explicitly stops the build |

This writes `zig-out/firmware/snouty-zero-xip.uf2` (badge),
`snouty-zero-xip.elf` (badge-bench, `size -A`) and
`zig-out/bin/snouty-zero.wasm` (simulator).
`zig build check-float -Dcart=snouty-zero -Dcart-mode=xip` must pass
(integer-only cart); `zig build test -Dcart=snouty-zero` runs the host tests.

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

- `m3_menus.json` (600 frames): Start at 130 (title), Down Down A (Sound
  on) at 160-180, Up Up A (Quick Race) at 200-220, Down A (league 2,
  Spine) at 240-250, Down A (track 2, Rack Row 7) at 270-280; Start at 400
  (pause), Down A at 420-430 (Restart). `debug_screen` reads 5 (race)
  from 281 and `debug_track` 4.
- `m3_bench.json` (1700 frames): Start, Start, A, A, A through the splash,
  title and menus into a Quick Race on Cold Aisle (race from frame 200),
  then the M1 drive with B held 1100-1160. The badge-bench default from
  M3 (badge-bench cannot make `--call` setup calls).
- `m3_rewind.json` (3600 frames, with `--call debug_start_race:0 --call
  debug_set_autopilot:1`): the autopilot drives Cold Aisle (the script's
  steers are ignored while it drives) and B is held 900-960: a 120-tick
  hold-B rewind (`debug_tick` goes from 700 back to 579, `debug_rewinds`
  1); add `--call-at 1500 debug_force_crash` for a SEGMENT FAULT at tick
  ~1180 followed by the 20-frame hit-stop and the 120-tick auto rewind
  (`debug_rewinding` 3, then 2, then 0; `debug_rewinds` 2).

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
| `debug_screen` | 0 splash, 1 title, 2 main menu, 3 league pick, 4 track pick, 5 race, 6 pause, 7 results, 8 standings |
| `debug_machine_px(i)`, `debug_machine_py(i)`, `debug_machine_lap(i)` | machine i (0 player, 1..4 rivals, 5..10 traffic); one-argument exports |
| `debug_set_autopilot(v)`, `debug_set_freecam(v)` | setup calls (`--call NAME:1`) |
| `debug_set_machine(n)`, `debug_machine` | machine select: 0 Anteater (base physics), 1..4 the rivals' characters |
| `debug_start_race(n)` | setup call: skip the menus into a Quick Race on track n (0..8 in `track.tracks` order: Edge 0..2, Spine 3..5, Core 6..8) |
| `debug_force_crash` | `--call-at T debug_force_crash`: the player falls (SEGMENT FAULT) |
| `debug_snapshot` | snapshot bar in ticks, 0..180 |
| `debug_rewinds` | rewinds this race (hold-B holds + auto rewinds) |
| `debug_rewinding` | 0 live, 1 hold-B rewind, 2 auto-rewind playback, 3 crash hit-stop, 4 JOB KILLED |
| `debug_active` | 1 while the player's machine is alive |
| `debug_sound`, `debug_mode`, `debug_track`, `debug_gp_points` | sound flag; 0 quick / 1 GP / 2 attract; current track index; SNOUTY's GP points |
| `debug_rebuilds`, `debug_replay_calls`, `debug_replay_max` | rewind cost: keyframe rebuilds this race (0 expected), simulate calls by restores and prefills in the last frame, and the most in one frame since boot |

## 6. Flashing

1. Put the badge in bootloader mode and connect it over USB-C; it shows up
   as a USB drive.
2. Copy `zig-out/firmware/snouty-zero-xip.uf2` onto the drive (the XIP
   cart; up to M4 the file was `snouty-zero.uf2`).
3. Pick the cart in the badge menu. Start+Select returns to the menu.

## 7. Emulated cycle benchmark

badge-bench (`../../badge-bench/README.md`) runs the ELF on an emulated
Cortex-M33 with the badge-calibrated cycle model; read the `busy ms`
column. `../../badge-bench/carts/snouty-zero.toml` sets the defaults.
From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-zero-xip.elf --config badge-bench/carts/snouty-zero.toml --script carts/snouty-zero/tools/scripts/m3_bench.json --frames 1700 --every 60 --symbols
```

The defaults file is keyed by ELF basename, so the XIP ELF needs
`--config`. The bench charges XIP instruction fetches at SRAM cost
(`--flash-cycles 0`, its XIP default) and never charges data loads from
the flash window; the cart copies the active track's art into RAM at
race start so the per-pixel loops never read flash anyway.

Milestone numbers are in `PLAN.md` under each milestone's status.

## 8. Regenerating the data

```sh
python3 tools/build_tracks.py     # tilesets, horizon strips, every .track -> assets/gen/
python3 tools/gen_sin.py          # cart/src/gen/sin.zig
python3 tools/gen_font.py         # assets/gen/font.bin from the SDK font
python3 tools/prepare_assets.py   # sprite sheets (assets/gen/*.png), ASSETS.md
```
