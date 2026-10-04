# Running the Snouty GC cart

Snouty GC (`snouty-gc`, subtitle GARBAGE COLLECTION) is a SYCL Badge V2
cart: a Mode 7 combat racer on the Snouty Zero engine (`../SPEC.md`). 60 fps
(`cart.set_vsync_enabled(1000.0 / 60.0)`), one `update()` per frame.

M1 (guns and racers) on top of the M0 fork (Zero's floor, horizon, fog,
camera, font and AI, retuned for wheels; no rewind, thermal bar or
traffic): the cart boots to a splash of Snouty's eyepatched portrait and
the title (10 s idle starts an AI-only attract race). **Start** opens the
**racer select**: Left/Right cycle SNOUTY, LEGACY, KIDDIE, SYSADMIN,
ROOTKIT and BOTNET (portrait, car on a turntable, SPD/ARM/DMG, the two
weapons, the bio), Down moves to the track row (Landfill Loop, the only
track so far), **A** races the racer shown against the other five, each in
its own car with its own weapons (SPEC 4.1). The race is a 3-lap fight on
**Landfill Loop** in the Dumps (board road, wreckage walls, the open pit
edge on the east side, a coolant spill, the ramp over a pit, the dunes):
armor, ramming, wrecks that burn as hulks and respawn after the WATCHDOG
delay, the kill feed, taunt pop-ups, `ACK` over cars you hit, smoke as
armor drops. Results: the winner's card, then the field (A steps through,
then back to the select). Pickups are M2 (the box top right stays empty).

Controls at M1 (SPEC 5.1):

| Input | Race |
|---|---|
| (nothing) | the throttle is always on |
| Left / Right | steer (rate falls with speed) |
| Down | brake; with Left/Right the powerslide (less grip, faster turn) |
| A | front weapon (hold to auto-fire PING, hold and release for FIBER LANCE, SPEAR PHISH fires on its lock) |
| Down + A | rear weapon (drop behind); does not brake |
| Up | BURST: +35% top speed for 1 s, one charge per lap (the bolt by the ammo) |
| B | nothing yet (pickups, M2); B backs out of the select |
| Select (hold) | look back: the camera turns round, `BEHIND` over the horizon |
| Start | pause (Resume, Restart, Quit, Sound) |

HUD: LAP and rank along the top, the pickup box top right, the kill feed
and the taunt pop-up under them, bottom left the speed, `A` and the front
ammo with the BURST bolts, `Down+A` and the rear ammo pips, the armor bar;
the minimap bottom right.

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
pit, the dunes; real time). The M1 previews:

```sh
# the splash, title, all six racers on the select, the track row, the pick
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 400 --every 4 \
    --press START:60-60 --press START:80-80 \
    --press RIGHT:130-130,RIGHT:170-170,RIGHT:210-210,RIGHT:250-250,RIGHT:290-290,RIGHT:330-330 \
    --press DOWN:350-350 --press A:375-375 --out out/m1s/
python3 ../../tools/make_gif.py out/m1s/ docs/preview_m1_select.gif --scale 2 --ms 66
# a combat race, the autopilot driving SNOUTY, look back held at 1000..1090
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 1300 --every 5 --start-skip 300 \
    --call debug_start_race:0 --call debug_set_autopilot:1 --press SELECT:1000-1090 --out out/m1r/
python3 ../../tools/make_gif.py out/m1r/ docs/preview_m1_race.gif --scale 2 --ms 83
# the render stress scene
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 200 --every 20 --call debug_stress:1 --out out/stress/
```

Input scripts in `tools/scripts/`:

- `m0_race.json` (600 frames): Start at 2 (splash), Start at 10 (title), A
  at 20 (QUICK RACE), then the autopilot's own drive recorded frame by frame
  by `tools/record_script.py` (the race seed comes from the frame counter,
  so the replay is the same race). The badge-bench default. Start at 10
  opens the racer select on SNOUTY and A at 20 races him, so the M0 script
  still drives the same flow.
- `m1_render_stress.json` (600 frames, with `--poke gc_stress=1`): the
  render stress scene, Select (look back) held at 400..460.

Debug exports (zero-argument wasm functions for `--dump-exports`,
`--expect`, `--at`, `--until`):

| Export | Meaning |
|---|---|
| `debug_frame`, `debug_render_us` | frames since start; render time (0 in wasm) |
| `debug_pixel_checksum` | sum of all framebuffer words |
| `debug_screen` | 0 splash, 1 title, 2 racer select, 3 race, 4 pause, 5 results |
| `debug_mode` | 0 quick race, 1 attract, 2 the render stress scene |
| `debug_select_racer`, `debug_results_card` | the racer the select shows; results card (0 winner, 1 field) |
| `debug_drawn`, `debug_gathered` | objects the depth list drew (cap 64) / gathered last frame |
| `debug_event_seq` | the World's next event seq |
| `debug_follow` | the car this badge draws (0..5, = racer id) |
| `debug_px`, `debug_py`, `debug_heading`, `debug_speed` | followed car: world position, heading (u16 turn), speed in 1/100 px per tick (300 = a WORKSTATION's top speed) |
| `debug_lap`, `debug_progress`, `debug_rank`, `debug_best_lap`, `debug_burst` | followed car: laps done, centerline sample, rank 1..6, best lap ticks, BURST ticks * 256 + charges |
| `debug_phase`, `debug_tick` | 0 countdown, 1 racing, 2 finished; race clock in ticks since GO |
| `debug_wrecks` | cars wrecked right now (waiting for the WATCHDOG) |
| `debug_tile_under` | attribute under the followed car (0 off, 1 surface, 2 wall, 4 coolant, 5 bay, 6 vent, 7 ramp, 8 start, 9/10 sectors) |
| `debug_input` | the race byte human slot 0 got on the last tick |
| `debug_world_size`, `debug_world_sum` | `@sizeOf(World)`; a fingerprint of the world |
| `debug_car_px(i)`, `debug_car_py(i)`, `debug_car_lap(i)`, `debug_car_rank(i)`, `debug_car_racer(i)`, `debug_car_human(i)`, `debug_car_armor(i)` | car i (one-argument exports) |
| `debug_set_autopilot(v)`, `debug_start_race(n)`, `debug_stress(v)` | setup calls (`--call NAME:ARG`): the autopilot drives the player; skip to a Quick Race on track n; v = 1 starts the render stress scene (stress.zig: the World's pools filled without the sim) |

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
# the render stress scene (six cars, every projectile and drop slot, explosions)
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --symbols --poke gc_stress=1 \
    --script carts/snouty-gc/tools/scripts/m1_render_stress.json
```

`gc_stress` is an exported global the cart reads in `start()`.

Read the `busy ms` column. Milestone numbers are in `PLAN.md`.

## 6. Regenerating the data

```sh
python3 tools/build_tracks.py     # Dumps tileset, palette, horizon, Landfill Loop -> assets/gen/, previews -> docs/
python3 tools/record_script.py    # tools/scripts/m0_race.json from the autopilot (after a build)
python3 tools/gen_sin.py          # cart/src/gen/sin.zig
python3 tools/gen_font.py         # assets/gen/font.bin from the SDK font
```

The engine sheets left from Zero (`assets/gen/shadow.png`, and
`exhaust.png`, Zero's `fx.png` renamed) are described in
`../ASSETS_ENGINE.md`; the art track's sheets (`python3
tools/draw_art.py`) are in `assets/gen/art/` (`../ASSETS.md`).
