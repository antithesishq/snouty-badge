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
then back to the select).

M2 (pickups, SPEC 6.3): RMA crates in rows across the road (three rows on
Landfill Loop). Driving through one with the box empty starts the roulette
top right (`FETCHING...`, then the pickup's name); **B** uses it (Down+B
drops HONEYPOT and SPAGHETTI behind). The 15 pickups have their gags, and
the ones that hit you are drawn on your badge: the KERNEL PANIC blue
screen (`:(`, `YOUR RIG RAN INTO A PROBLEM`, the stop code naming who sent
it), then your car frozen blue; **CAPTCHA**, which you play (a cursor
sweeps the 3x3 grid: press A on each square with a traffic light; A on an
empty square clears the board, `TRY AGAIN`); BIT FLIP (Left and Right
swapped, `<R BIT FLIP L>` blinking mirrored, the floor jitters); DDOS
(drones orbit you, the speed reading stutters and serves a 503); a
RACE CONDITION glitch; the ZERO-DAY flash. In the world: crates, the fake
HONEYPOT crate with its flickering `?`, FORK BOMB `&`s that swell and
split, SPAGHETTI tangles and strands, the blue KERNEL PANIC packet, DDOS
drones, RUBBER DUCKs on tethers, DEADLOCK chains, SUDO's gold flash and
`#`, HEISENBUG's flicker, the HONEYPOT spin, the kill feed's pickup lines
(`KERNEL PANIC > KIDDIE`).

M3 (content and flow, SPEC 3, 8): six tracks over two leagues (the
Dumps: Landfill Loop, Monitor Dunes, Cathode Flats, each with the
Sweeper; the Runoff: Salt Pan Sprint, Outflow Canyon, Coolant Basin, with
exhaust vents). The title (SNOUTY GC over the Dumps horizon, the six
portraits along the bottom, PRESS START; 10 s idle starts the attract
demo) leads to the **main menu**: QUICK RACE, GARBAGE COLLECTION, LINK
(greyed, `NO LINK YET` until M4), SOUND. A picks, B goes back. Then the
racer select; Down to the track row, where Left/Right cycle the six
tracks and the panel shows the track's name, league, the mode's rule,
its hazards and its outline. **GARBAGE COLLECTION**: `SWEEP n` top left
with a bar filling as the leader nears the next sweep point, the MARKED
car in a red outline with `MARKED` over it (blinking red on the
minimap), `TAGGED!` when a hit passes the mark on, and at each sweep the
claw comes down from the top of the screen, closes on the collected car
and lifts it out (`GC: freed KIDDIE`). Collected yourself, you watch the
leader (`COLLECTED` bottom left). The survivor screen reads `LAST PROCESS
RUNNING`; the field is ranked in collection order (`SURVIVOR`, `SWEEP
n`, `WRECKED`). **Hazards**: the Sweeper, a huge crawler with a roof
beacon (flashing while it warns, steady while it crosses); a vent marks
its lane with blinking dashes and puffs steam before a blast of flame and
steam across the road. **Attract**: an AI race on the next track each
time, the camera cutting between cars every 5 s and onto a car a KERNEL
PANIC freezes (the blue screen), `PRESS START` blinking; any button goes
back to the title.

Controls at M1 (SPEC 5.1):

| Input | Race |
|---|---|
| (nothing) | the throttle is always on |
| Left / Right | steer (rate falls with speed) |
| Down | brake; with Left/Right the powerslide (less grip, faster turn) |
| A | front weapon (hold to auto-fire PING, hold and release for FIBER LANCE, SPEAR PHISH fires on its lock) |
| Down + A | rear weapon (drop behind); does not brake |
| Up | BURST: +35% top speed for 1 s, one charge per lap (the bolt by the ammo) |
| B | use the held pickup; Down+B drops it behind (HONEYPOT, SPAGHETTI); B backs out of the select and the menu |
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

The M2 preview (`docs/preview_m2.gif`): an autopilot race (mode 2 lets the
pad's A and B through) where, from frame 1300, a CAPTCHA is forced on
SNOUTY and solved with A on its lit squares (a miss at 1312 shows `TRY
AGAIN`), the roulette lands a FORK BOMB, a rival's FORK BOMB lands ahead,
and a KERNEL PANIC blue-screens SNOUTY while the `&` ahead forks into 2,
then 4, before he drives into them:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 1630 --every 2 --start-skip 1270 \
    --call debug_start_race:0 --call debug_set_autopilot:2 \
    --call-at "1300 debug_effect:3" --call-at "1360 debug_roll_pickup:5" \
    --call-at "1410 debug_effect:17" --call-at "1413 debug_effect:1" \
    --press A:1307-1307,A:1312-1312,A:1317-1317,A:1332-1332,A:1352-1352 --out out/m2/
python3 ../../tools/make_gif.py out/m2/ docs/preview_m2.gif --scale 2 --ms 33
```

The lit squares come from the world PRNG at the call, so the A frames
were read off a dry run's `--sample debug_captcha_cursor,debug_captcha_lit`.

The M3 preview (`docs/preview_m3.gif`) is cut from four runs: the menu
flow (title, main menu, GARBAGE COLLECTION, the select's track row up to
Cathode Flats), a GARBAGE COLLECTION race on Cathode Flats with the
autopilot (the Sweeper crossing, LEGACY marked at the first sweep, SNOUTY
marked, SNOUTY's tag passing the mark to ROOTKIT, the claw lifting SNOUTY
out at the fourth sweep and the leader's camera after it, the last
collection, the survivor card and the table), a Quick Race on Salt Pan
Sprint (a vent firing across the road) and the attract demo's blue screen:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 300 --every 3 \
    --press START:2-2 --press START:90-90 --press DOWN:130-130 --press A:160-160 \
    --press DOWN:200-200 --press RIGHT:220-220,RIGHT:240-240 --press A:285-285 --out out/m3menu/
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 6080 --every 3 \
    --call debug_start_gc:2 --call debug_set_autopilot:1 --press A:5990-5990 --out out/g2/
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 2400 --every 3 --start-skip 300 \
    --call debug_start_race:3 --call debug_set_autopilot:1 --out out/vent/
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 3600 --every 3 --start-skip 3420 \
    --press START:2-2 --out out/att/
```

then frames 30..297 of `m3menu`, 930..1005, 1320..1350, 1854..1890,
2124..2175, 3849..3966, 5763..5790, 5916..5970 and 5994..6075 of `g2`,
1239..1296 of `vent` and 3459..3561 of `att` (every third) copied in
that order into one directory and `make_gif.py --scale 2 --ms 50`.

Input scripts in `tools/scripts/` (`tools/record_script.py [--track N]
[--gc] --frames F --out ...` records the autopilot's drive through the M3
menus: Start at 2, Start at 10, Down at 12 for GARBAGE COLLECTION, A at
14, then Down at 16 and Right every 2 frames for the track, A 4 frames
later; the race seed comes from the frame counter, so the replay is the
same race):

- `m0_race.json` (600 frames): a Quick Race on Landfill Loop (A, A at 14
  and 20), the autopilot's drive. The badge-bench default.
- `m1_render_stress.json` (600 frames, with `--poke gc_stress=1`): the
  render stress scene, Select (look back) held at 400..460. Since M2 the
  scene also has crates, drones, FORK BOMBs, a chain, ducks and the car
  states, and runs SNOUTY's gags in turn (150 frames each: the CAPTCHA
  board, BIT FLIP, DDOS, the roulette).
- `m2_race.json` (3,000 frames): `record_script.py --frames 3000`, an
  autopilot race with pickups in play (the gate benches it).
- `m3_outflow_race.json` (1,500 frames): `--track 4`, Outflow Canyon,
  the busiest track (Track A's, re-recorded on the M3 menus).
- `m3_gc_race.json` (3,600 frames): `--gc --track 1`, a GARBAGE
  COLLECTION race on Monitor Dunes (marks, two collections, SNOUTY
  collected and watching, the Sweeper). The stress scene (since M3) also
  has a Sweeper, two firing vents, a MARKED car, tags and claws.

Debug exports (zero-argument wasm functions for `--dump-exports`,
`--expect`, `--at`, `--until`):

| Export | Meaning |
|---|---|
| `debug_frame`, `debug_render_us` | frames since start; render time (0 in wasm) |
| `debug_pixel_checksum` | sum of all framebuffer words |
| `debug_screen` | 0 splash, 1 title, 2 racer select, 3 race, 4 pause, 5 results, 6 main menu |
| `debug_mode` | 0 quick race, 1 attract, 2 the render stress scene, 3 GARBAGE COLLECTION |
| `debug_me` | the player's car (`debug_follow` differs in the attract demo and once a GC race has collected the player) |
| `debug_gc_marked`, `debug_gc_sweeps`, `debug_gc_collected`, `debug_gc_survivor`, `debug_alive` | GARBAGE COLLECTION: the marked car (255 none), sweeps passed, collected bits, the survivor (255 none), cars still running |
| `debug_hazard_state` | a hex digit per hazard slot (slot 0 lowest): state (0 idle, 1 warn, 2 active) + 4 * kind (1 vent, 2 Sweeper) |
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
| `debug_start_gc(n)`, `debug_start_attract(n)` | setup calls: a GARBAGE COLLECTION race (the player SNOUTY) or the attract demo on track n |
| `debug_set_autopilot(v)`, `debug_start_race(n)`, `debug_stress(v)` | setup calls (`--call NAME:ARG`): the autopilot drives the player (v = 2: the pad's A, B and Select join it, and the pad alone plays a CAPTCHA board); skip to a Quick Race on track n; v = 1 starts the render stress scene (stress.zig: the World's pools filled without the sim) |
| `debug_give_pickup(p)`, `debug_roll_pickup(p)`, `debug_give_ahead(p)` | M2 preview hooks (`--call-at "T NAME:P"`, P in SPEC 6.3 order: 0 PREFETCH .. 14 ZERO-DAY): pickup P into the followed car's slot, the same behind the 45-tick roulette, or to the nearest car ahead (its AI uses it) |
| `debug_effect(k)` | M2 preview hook: `stress.Effect` k & 255 on the followed car (or car (k >> 8) - 1): 1 KERNEL PANIC, 2 BIT FLIP, 3 CAPTCHA, 4 DDOS, 5 DEADLOCK, 6 HEISENBUG, 7 SUDO, 8 RACE CONDITION, 9 SPAGHETTI, 10 RUBBER DUCK, 11 PREFETCH, 12 HONEYPOT spin, 13 ZERO-DAY, 14 duck pop, 15 HOT PATCH, 16 crate pop, 17 a rival's FORK BOMB ahead. These write the World (debug only); the sim runs the state on |
| `debug_pickup`, `debug_frozen`, `debug_captcha`, `debug_captcha_cursor`, `debug_captcha_lit`, `debug_forks` | followed car: held pickup (16 none), frozen ticks, CAPTCHA ticks left, cursor cell, lit cells; live FORK BOMB `&`s |

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
# M3: Outflow Canyon, and a GARBAGE COLLECTION race
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 1500 --script carts/snouty-gc/tools/scripts/m3_outflow_race.json
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 3600 --script carts/snouty-gc/tools/scripts/m3_gc_race.json
```

`gc_stress` is an exported global the cart reads in `start()`.

Read the `busy ms` column. Milestone numbers are in `PLAN.md`.

## 6. Regenerating the data

```sh
python3 tools/build_tracks.py     # leagues and tracks -> cart/src/gen/tracks/, previews -> docs/
python3 tools/record_script.py    # tools/scripts/m0_race.json from the autopilot (after a build; --track, --gc)
python3 tools/gen_sin.py          # cart/src/gen/sin.zig
python3 tools/gen_font.py         # assets/gen/font.bin from the SDK font
```

The engine sheets left from Zero (`assets/gen/shadow.png`, and
`exhaust.png`, Zero's `fx.png` renamed) are described in
`../ASSETS_ENGINE.md`; the art track's sheets (`python3
tools/draw_art.py`) are in `assets/gen/art/` (`../ASSETS.md`).
