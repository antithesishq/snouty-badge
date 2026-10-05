# Running the Snouty GCP cart

Snouty GCP (Snouty Garbage Collection Prix; the cart and binary are
`snouty-gc`) is a SYCL Badge V2 cart: a Mode 7 combat racer on the Snouty Zero engine (`../SPEC.md`). 60 fps
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
exhaust vents). The title (SNOUTY GCP, GARBAGE COLLECTION PRIX over the
Dumps horizon, the six portraits along the bottom, PRESS START; 10 s idle starts the attract
demo) leads to the **main menu**: QUICK RACE, GARBAGE COLLECTION,
CIRCUIT (M5, below), PICKUPS, LINK (M4, below), SOUND, with a line about
the row under the cursor over the `A SELECT  B BACK` footer. A picks, B
goes back. **PICKUPS** is a
reference page: the 15 pickups' icons in a grid, a row per roll tier
(Up/Down/Left/Right move the coral cursor and wrap), and under it the
pickup's name, three lines on what it does and one on who tends to roll
it; B goes back to the menu, and the cursor stays where it was until the
cart stops. Then the
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

M4 (LINK, SPEC 7): two badges joined by a JST-SH 3-pin cable on their
UART headers race in one field, LINK RACE or LINK GC, with 4, 2 or no AI
racers: the LINK screen (cable state, host and guest, the host's rules),
the shared racer select (`TAKEN`, `READY`, the host's `A START`), a
pause either badge opens and closes, `WAITING FOR PEER`, `PEER LEFT, AI
DRIVING`, `DESYNC`. `docs/LINK_PLAY.md` is how to play it and the
two-badge hardware check (never run on two badges yet). In the simulator
LINK is greyed: `NO LINK IN SIMULATOR`.

M5 (CIRCUIT, SPEC 8.2, 9; the SNOUTY GCP): **A on the title** opens the
Quick Race select (A, A to a race; Start still opens the menu; the
title's `A  QUICK RACE` blinks in turn with PRESS START). The main menu
gains **CIRCUIT**, its third row. CIRCUIT opens the racer select (no track row: `A ENTER THE
PRIX`), then the **garage**: the racer's portrait, the car turning under
it, the slots FRONT, REAR, PLATING, CLOCK, TRACTION, BURST, WATCHDOG with
their levels as pips, and RACE. Up/Down a slot, Left/Right a gun on FRONT
and REAR (another gun is a swap at L1, the car's own its next level), A
buys (the price turns coral when the wallet is short), and the portrait
answers every press with a line (`NO CYCLES. I'LL GO HUNT SOME.`); Start
or A on RACE races the league's next track, B goes back to the menu with
the Prix kept (CIRCUIT resumes it). A CIRCUIT race has **cycle chips**
(green chips in trails along the road, 10 CYCLES each, a `+10` pops; they
come back every 4 s) and the AIs drive their upgraded cars. After the
results: the **standings** (the league table with this race's points, and
the race's CYCLES: place, kills, chips, the wallet), then the garage.
After a league's third race the **league card** (PRIX WON with +1500, a
PODIUM place, or out of the top 3: the league again, CYCLES kept), then
the **unlock card** over the Runoff's floor, and after the Runoff the
**end card** (`YOU REACHED THE FENCE. THE HYPERSCALERS DID NOT NOTICE.`).
Pause QUIT in a CIRCUIT race goes back to the garage (the race is not
booked). The Prix lives in RAM: switching the badge off loses it. The
BURST pips show up to four bolts (BURST BUFFER), and `TAGGED!` no longer
runs off the screen edge.

M6 (BATTLE, `KILL -9`, SPEC 8.3): the main menu's third row is
**BATTLE** (`ARENA, MOST KILLS`). It opens the racer select (no track
row: `A  TO THE ARENA`), then the **setup** over the arena's own floor:
the arena (`THE SANDBOX`), `LIVES: 1 / 3 / 5 / 9 / INF`, `TIME: 2 / 3 / 5
MIN / NONE` (NONE is skipped with INF lives), `CREWS: 5..1 AI`, and
`FIGHT!`; Up/Down a row, Left/Right its value, A (or Start) on any row
fights, B goes back to the select. The **KILL -9** card (`$ kill -9 -1`
typing itself, `no cleanup handler` / `no appeal`, the arena and the
rules) covers the countdown's first two steps; `2`, `1`, `GO` follow. The
battle HUD: `ELIM n` top left (cyan for the kill leader), the lives as
pips under it (coral on the last; `INF`), the round clock in the middle
(time left, blinking coral in the last 10 s; with TIME NONE the time
played in grey), the standing beside it; a sweep between the front and
rear ammo rows fills to the next ammo and BURST refill; the minimap is
the whole arena (walls, the bit bucket and the gap pits, bays, ramps,
waiting crates, the Sweeper, every car, the kill leader ringed cyan).
The feed reads `SNOUTY kill -9 KIDDIE` for an elimination (the victim
flashing red when it was its last life), `KIDDIE REAPED` for a last life
nobody was credited with, `SNOUTY SMASHED KIDDIE` for a STACK SMASH
(`SMASH!` rises over the victim). The bar: `SAFE MODE` blinking after a
respawn (the car blinks too), `STACK SMASH!` / `STACK SMASHED` /
`CLEAN LANDING` pops, and at the end `TIME UP` or `LAST ONE STANDING`.
On a last life the GC claw lifts the hulk out; once yours is gone,
`REAPED` sits bottom left and the camera rides with the kill leader (its
name under the clock). Results: the winner card (`TOP KILLER`, or `LAST
PROCESS UP` when the lives ran out; eliminations, lives or wrecks, the
taunt, how it ended, your own standing), then the **standings** by
eliminations, lives and time survived (`LIVES 2`, `WRECKS 3` with INF,
`OUT 1:42`). Pause works as in a race (RESTART is a new round with the
same rules; QUIT goes back to the select). **LINK BATTLE**: the LINK
lobby's mode row also offers it, with the arena and LIVES / TIME rows
(`docs/LINK_PLAY.md`); the link protocol is version 1, so an M5.1 badge
and this one show `WRONG VERSION`.

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
git fetch origin && git checkout gc/present   # or a tag: git checkout snouty-gc/m5
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

The M4 preview (`docs/preview_m4.gif`) is two runs: the menu (LINK
greyed, `NO LINK IN SIMULATOR`) and the made-up LINK screens
(`debug_link_view`: searching, the host's lobby changing the rules, the
guest's, another cart, the host's select with both ready, the guest's on
a taken racer), then a Quick Race with the link notices forced over it
(`debug_link_notice`: WAITING FOR PEER, PEER LEFT, AI DRIVING):

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 470 --every 2 --start-skip 12 \
    --press START:2-2 --press START:10-10 --press DOWN:14-14,DOWN:16-16,DOWN:18-18 --press A:24-24 \
    --call-at "75 debug_link_view:1" --call-at "130 debug_link_view:2" \
    --press RIGHT:150-150 --press DOWN:165-165 --press RIGHT:175-175,RIGHT:185-185 --press DOWN:200-200 \
    --press RIGHT:210-210 --press DOWN:225-225 --call-at "245 debug_link_view:3" --call-at "295 debug_link_view:4" \
    --call-at "335 debug_link_view:5" --press RIGHT:355-355 --press A:375-375 --call-at "425 debug_link_view:6" --out out/m4a/
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 560 --every 2 --start-skip 240 \
    --call debug_start_race:1 --call debug_set_autopilot:1 \
    --call-at "400 debug_link_notice:1" --call-at "480 debug_link_notice:2" --out out/m4b/
```

then `out/m4a` and `out/m4b` frames in that order into one directory and
`make_gif.py --scale 2 --ms 50` (recorded before CIRCUIT and PICKUPS
joined the menu, with two Downs to LINK; four now). The pump-gap probe in badge-bench (from
the repository root): `badge-bench/bench.sh zig-out/firmware/snouty-gc.elf
--json --poke gc_pump_probe=1 --frames 3600 --script
carts/snouty-gc/tools/scripts/m3_gc_race.json` (the `gc gaps:` traces in
`bench.json`: the worst gap ending at each site, us: top, after the
tick, horizon, floor, floor lines, sprites, HUD, after the HUD).

The M5 preview (`docs/preview_m5.gif`, 644 frames at 60 ms) is two runs
of one script: the menus (CIRCUIT), the select, the garage (3,000 CYCLES
given; SPEAR PHISH L2 with its reaction, PING shown as an 800 swap,
PLATING L1 and L2, then too poor for L3), a CIRCUIT race with the
autopilot (chips, every 4th frame of 880..1400), then the real results,
the standings, and made-up results (`debug_prix_skip`) through the Dumps'
league card, the Runoff's unlock card, its league card and the end card:

```sh
A='--call debug_set_autopilot:1 --press START:2-2 --press START:20-20 --press DOWN:40-40,DOWN:55-55 --press A:80-80
   --press A:120-120 --call-at "125 debug_prix_give:3000" --press A:150-150 --press RIGHT:250-250
   --press DOWN:290-290,DOWN:310-310 --press A:330-330,A:430-430,A:530-530 --press START:650-650'
eval node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 1400 --every 4 $A --out out/m5a/
eval node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 8500 --every 4 --start-skip 7140 $A \
    --press A:7230-7230,A:7320-7320,A:7470-7470,A:7600-7600,A:7720-7720,A:7870-7870,A:8020-8020,A:8080-8080,A:8120-8120,A:8200-8200,A:8320-8320 \
    --call-at "'7520 debug_prix_skip:1'" --call-at "'7640 debug_prix_skip:1'" --call-at "'8060 debug_prix_skip:1'" \
    --call-at "'8100 debug_prix_skip:2'" --call-at "'8140 debug_prix_skip:1'" --out out/m5b/
```

then frames 8..700 and 880..1400 of `m5a` and all of `m5b`, in that
order, into one directory and `make_gif.py --scale 2 --ms 60`.

The PICKUPS page preview (`docs/preview_pickups.gif`): the menu, Down
three times and A (PICKUPS is the fourth row), then the cursor walks all 15 pickups a second each, and B:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-gc.wasm --frames 1010 --every 3 --start-skip 15 \
    --press START:2-2 --press START:10-10 --press DOWN:30-30,DOWN:45-45,DOWN:60-60 --press A:70-70 \
    --press RIGHT:120-120,RIGHT:180-180,RIGHT:240-240,RIGHT:300-300,DOWN:360-360,LEFT:420-420,LEFT:480-480 \
    --press LEFT:540-540,LEFT:600-600,LEFT:660-660,DOWN:720-720,LEFT:780-780,LEFT:840-840,LEFT:900-900 \
    --press B:960-960 --out out/pickups/
python3 ../../tools/make_gif.py out/pickups/ docs/preview_pickups.gif --scale 2 --ms 50
```

The M6 preview (`docs/preview_m6.gif`, every third update at 50 ms, so
real time) is one run cut by `tools/m6_gif.py`: the title, the menu's
BATTLE row, the racer select (`A  TO THE ARENA`), the setup (TIME to 2
MIN, LIVES to 5), FIGHT!, the KILL -9 card and the countdown, then
SNOUTY on the autopilot: a STACK SMASH, a CLEAN LANDING, a kill -9 line,
a wreck and the respawn in SAFE MODE, the last life (the claw, REAPED)
and the kill leader's camera, the clock running out (TIME UP), the
winner card and the standings. The FIGHT press's frame picks the seed;
`scan` lists what each round has, `cut` records one (fight at frame
344 for the committed GIF):

```sh
python3 tools/m6_gif.py scan 320 360 4
python3 tools/m6_gif.py cut 344 out/m6gif docs/preview_m6.gif
```

Input scripts in `tools/scripts/` (`tools/record_script.py [--track N]
[--gc] [--circuit] --frames F --out ...` records the autopilot's drive through the M3
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
  collected and watching, the Sweeper).
- `m5_circuit_race.json` (3,000 frames, M5): `--circuit`, Start, Start,
  Down x3 (M6: BATTLE is the third row now), A (CIRCUIT), A (SNOUTY),
  the garage, Start at 30: the Dumps' first CIRCUIT race with chips.
- `m5_cards.json` (600 frames, with `--poke gc_cards=1`, M5): the garage
  with 5,000 CYCLES at boot, three purchases, then Start (which books a
  made-up 1st place under the poke) and A through the standings, the
  league card, the unlock card, the Runoff and the end card. The stress scene (since M3) also
  has a Sweeper, two firing vents, a MARKED car, tags and claws.

Debug exports (zero-argument wasm functions for `--dump-exports`,
`--expect`, `--at`, `--until`):

| Export | Meaning |
|---|---|
| `debug_frame`, `debug_render_us` | frames since start; render time (0 in wasm) |
| `debug_pixel_checksum` | sum of all framebuffer words |
| `debug_screen` | 0 splash, 1 title, 2 racer select, 3 race, 4 pause, 5 results, 6 main menu, 7 LINK lobby, 8 garage, 9 standings, 10 CIRCUIT card, 11 PICKUPS page, 12 BATTLE's setup (M6) |
| `debug_menu_row` | the main menu's cursor (0 QUICK RACE, 1 GARBAGE COLLECTION, 2 BATTLE, 3 CIRCUIT, 4 PICKUPS, 5 LINK, 6 SOUND) |
| `debug_link_view(k)` | a made-up LINK screen (the simulator's link is offline): 1 searching, 2 the host's lobby, 3 the guest's, 4 WRONG CART, 5 the host's select with both ready, 6 the guest's select (TAKEN), 7 WRONG VERSION; 0 the real one |
| `debug_link_mode(m)`, `debug_lobby_rules` | M6: the lobby's mode (0 LINK RACE, 1 LINK GC, 2 LINK BATTLE) for the made-up lobby; its rules as mode \| track << 4 \| crews << 8 \| lives << 16 \| minutes << 24 |
| `debug_start_battle(n)`, `debug_battle_minutes(m)`, `debug_battle_crews(k)` | M6 setup calls (they return their value, so `--call-at` works too): a BATTLE round on The Sandbox with the select's racer and n lives (0 INF); the next round's TIME (0 NONE) and AI cars |
| `debug_setup_row`, `debug_battle_arena` | M6: the setup's cursor (0 arena, 1 LIVES, 2 TIME, 3 CREWS, 4 FIGHT!), the arena picked |
| `debug_battle_left`, `debug_battle_refill`, `debug_battle_out`, `debug_battle_leader`, `debug_battle_end` | M6: ticks left on the clock (-1 with TIME NONE), ticks to the next refill, out-of-lives bits, the kill leader (255 none), why it ended (0 running, 1 lives, 2 time) |
| `debug_battle_lives(i)`, `debug_battle_elims(i)`, `debug_battle_safe(i)` | M6: car i's lives, eliminations, SAFE MODE ticks |
| `debug_me_out`, `debug_safe`, `debug_stunt` | M6: the player is out of lives; the followed car's SAFE MODE ticks; the bar's stunt pop (kind * 256 + ticks: 1 STACK SMASH, 2 smashed, 3 CLEAN LANDING) |
| `debug_battle_set_lives(v)`, `debug_battle_kill(v)`, `debug_battle_clock(t)` | M6 preview hooks (debug writes of the World): car \| lives << 8 sets a car's lives; victim \| killer << 8 wrecks the victim with the killer credited (255 nobody; returns 1 when it did); t ticks left on the clock |
| `debug_battle_stress` | M6: the render stress scene in the arena with the battle HUD's stress (badge-bench `--poke gc_battle=2`) |
| `debug_pickup_cursor` | the PICKUPS page's cursor (`world.Pickup`: 0 PREFETCH .. 14 ZERO-DAY) |
| `debug_mode` | 0 quick race, 1 attract, 2 the render stress scene, 3 GARBAGE COLLECTION, 4 a CIRCUIT race, 5 BATTLE (M6) |
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
| `debug_start_circuit(r)`, `debug_prix_skip(p)`, `debug_prix_give(c)` | M5 setup and preview hooks: a new CIRCUIT with racer r in the garage; book the next race as place p (the others in racer order) and show the standings; add c CYCLES to the wallet |
| `debug_prix_cycles`, `debug_prix_league`, `debug_prix_race`, `debug_prix_done`, `debug_card`, `debug_garage_row` | M5: the wallet, the league (0 the Dumps, 1 the Runoff), the next race in it, the Prix over; the card shown (0 league, 1 unlock, 2 end); the garage's row (7 RACE). `debug_screen` 8 garage, 9 standings, 10 card; `debug_mode` 4 a CIRCUIT race |
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
# M5: a CIRCUIT race from the menus and the garage; the garage, standings and every card
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 3000 --script carts/snouty-gc/tools/scripts/m5_circuit_race.json
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 600 --poke gc_cards=1 --script carts/snouty-gc/tools/scripts/m5_cards.json
# M6: a BATTLE round on The Sandbox (SNOUTY on the autopilot, 3 lives, 3 min), and the
# arena stress scene with the battle HUD at its busiest (kill -9 lines, claws, stunt pops, SAFE MODE)
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 3600 --poke gc_battle=1
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 300 --poke gc_battle=2
```

`gc_stress`, `gc_cards` (M5) and `gc_battle` (M6) are exported globals the cart reads in `start()`.

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

## 7. Saves (branch `saves/gcp`)

With the patched badge OS that stores cart saves (sycl-badge branch
`cart-saves`, root `docs/SAVES.md`), the SNOUTY GCP survives switching the
badge off. On stock firmware, in the web simulator and in wasm builds
nothing of this shows: the cart is the one described above.

- **What is kept**: one key, `gcp/career` (181 bytes, one 4 KB store
  block): the whole `career.Career` (racer, league and next race, open
  leagues, tries, the wallet, every racer's league points, loadout, CYCLES
  earned and spent, each AI's place in its plan, the circuit totals, the
  last race's award, the last league's outcome). Quick Race, GARBAGE
  COLLECTION, BATTLE, LINK and the SOUND toggle keep nothing. Format and
  rules: `cart/src/career_save.zig`.
- **When it saves**: when a race is booked (A on the results' field
  table, as the standings come up), when B leaves the garage for the menu,
  and when the settings box's **Exit cart** is picked (the OS waits for
  the cart). Each time only if the career changed since the last save, so
  B in and out of the garage costs nothing. A `SAVING` mark top right
  holds the screen for the ~110 ms the badge is parked. Never mid-race,
  and never during a LINK session (lobby, link select, link race). Leaving
  the end card deletes the save (the circuit is over). Garage purchases
  are saved by the next save point; switching off between buying and the
  race result undoes them (with the CYCLES refunded).
- **CIRCUIT in the main menu** opens `CONTINUE CAREER` / `NEW CAREER`
  when there is a career (saved, or in this session). CONTINUE picks it
  up in the garage (or on the standings, if the badge went off after a
  league's third race; A then closes the league as before). NEW CAREER
  asks first (`NO, KEEP IT` / `YES, START OVER`, NO under the cursor),
  then opens the racer select; the old save is replaced at the new
  career's first save point. Up/Down, A or Start, B back. Without saves
  CIRCUIT works as before (straight to the garage while a Prix is on).
- **A save it cannot use** (another build's format: `OLD SAVE: UNUSABLE`;
  a bad checksum or field: `SAVE IS DAMAGED`) leaves NEW CAREER alone on
  the chooser; the new career's first save replaces it.
- **Errors**: the store's rate limit (8 commits, then one per 10 s) is
  retried quietly at the next save point; any other failure shows once in
  a red line at the top (`SAVE: NO SPACE`, `SAVE: FLASH ERROR`, ...), off
  the race.
- **The probe**: the cart asks the OS once, on its second frame (the
  splash or the title). Stock firmware never answers, so that frame takes
  250 ms; nothing moves on the splash then.

Host tests: `cart/src/career_save_test.zig` (in `zig build test-gc`)
against lib/save.zig's fake store. Bench (the recorded CIRCUIT race to its
standings, `tools/scripts/saves_circuit_race.json`):

```sh
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 6100 \
    --script carts/snouty-gc/tools/scripts/saves_circuit_race.json --saves /tmp/gcp.json
# the next boot: CIRCUIT, CONTINUE CAREER, the garage; then Exit cart
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 120 \
    --script carts/snouty-gc/tools/scripts/saves_continue.json --saves /tmp/gcp.json --exit-at 100
# stock firmware: the same race, no save request answered, no SAVING
badge-bench/bench.sh zig-out/firmware/snouty-gc.elf --frames 6100 \
    --script carts/snouty-gc/tools/scripts/saves_circuit_race.json --no-saves
```

`tools/check_saves.sh` runs those three and checks the results.
