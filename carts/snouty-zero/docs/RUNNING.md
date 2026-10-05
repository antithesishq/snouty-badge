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
over orange glow, red haze) and a MACHINE row in the main menu (Left/Right
or A cycle it; the line under the menu says how it handles): the Anteater,
or a rival's machine drawn in its livery (ARGMAX 1.18x top speed and 0.75x
turn, DROPOUT sharp turns but half the grip, BACKPROP slower with 1.3x turn
and 1.5x grip, OVERFIT 1.1x top speed and fragile in contact). Maps are
stored packed and the selected track is unpacked into RAM at race start.
M5 made the cart XIP only; M5.1 brought the RAM cart back (the XIP
variant's copy of the league art was what overflowed cart RAM) and keeps
the XIP cart beside it for a hardware comparison. M5.5 adds knockouts
(ram a rival into a meltdown or off the track and it is out). M6 adds
LINK RACE: two badges joined by a cable on their UART headers race each
other on one track in lockstep (SPEC 8.1, section 9 below); it is greyed
in the simulator, where there is no link.

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
zig build -Dcart=snouty-zero   # only this cart, RAM and XIP; plain `zig build` builds every cart
```

Options (all from the root):

| Option | Values (default first) | Meaning |
|--------|------------------------|---------|
| `-Dzero_floor` | `row`, `column` | floor inner loop (SPEC 18 measurement; `row` won in the bench, `column` kept for a hardware check) |
| `-Ddebug_overlay` | `false`, `true` | draws the render time in microseconds and the camera height, top right |
| `-Dsound` | `false`, `true` | initial value of the sound toggle (M3) |
| `-Dcart-mode` | `ram` (builds both), `both`, `xip` | `ram` and `both` write the RAM and the XIP cart, `xip` only the XIP one |

This writes `zig-out/firmware/snouty-zero.uf2` (badge, RAM cart),
`snouty-zero-xip.uf2` (the XIP cart: code runs from the cart flash
window and the active league's art is copied to RAM at race start), the
two `.elf` files (badge-bench, `size -A`) and
`zig-out/bin/snouty-zero.wasm` (simulator).
`zig build check-float -Dcart=snouty-zero` must pass for both ELFs
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

- `m3_menus.json` (600 frames): Start at 130 (title), Down Down A at
  160-180 (written for an older menu: since M6 it lands on the greyed
  LINK RACE row and does nothing), Up Up A (Quick Race) at 200-220, Down A (league 2,
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
| `debug_set_machine(n)`, `debug_machine` | machine select: 0 Anteater (base physics), 1..4 the rivals' machines (`ai.player_machines`) |
| `debug_start_race(n)` | setup call: skip the menus into a Quick Race on track n (0..8 in `track.tracks` order: Edge 0..2, Spine 3..5, Core 6..8) |
| `debug_force_crash` | `--call-at T debug_force_crash`: the player falls (SEGMENT FAULT) |
| `debug_force_ko`, `debug_kos` | `--call-at T debug_force_ko`: the live machine nearest the player melts down credited to the player, a knockout (SPEC 5.5), returns its index; knockouts this race |
| `debug_snapshot` | snapshot bar in ticks, 0..180 |
| `debug_rewinds` | rewinds this race (hold-B holds + auto rewinds) |
| `debug_rewinding` | 0 live, 1 hold-B rewind, 2 auto-rewind playback, 3 crash hit-stop, 4 JOB KILLED |
| `debug_active` | 1 while the player's machine is alive |
| `debug_sound`, `debug_mode`, `debug_track`, `debug_gp_points` | sound flag; 0 quick / 1 GP / 2 attract; current track index; SNOUTY's GP points |
| `debug_rebuilds`, `debug_replay_calls`, `debug_replay_max` | rewind cost: keyframe rebuilds this race (0 expected), simulate calls by restores and prefills in the last frame, and the most in one frame since boot |
| `debug_link_view(k)` | made-up LINK RACE lobby (the simulator's link is offline): 1 searching, 2 the host's lobby, 3 the guest's, 4 another cart, 5 the host with both ready (START: GO), 6 the guest ready, 7 no link; the lobby's controls work on it |
| `debug_link_race(k)` | a made-up two-human link race without the lockstep: k bit 0 the view (0 the host's machine 0, 1 the guest's machine 1), k >> 1 the track; the host drives the menu's machine, the guest BACKPROP; with `debug_set_autopilot:1` both views show the same race |
| `debug_link_notice(k)` | over a made-up link race: 1 WAITING FOR PEER, 2 PEER LEFT, AI DRIVING, 3 a desync (the results with the DESYNC band), 0 none |
| `debug_link_state`, `debug_linked`, `debug_view`, `debug_link_waits`, `debug_human_lap(s)` | the lockstep state (0 offline, 1 searching, 2 wrong cart, 3 wrong version, 4 lobby, 5 racing, 6 waiting, 7 peer left, 8 desync; 0xFF before LINK RACE opened); 1 in a link race (3 made up); the machine the camera follows; link race frames without a tick; laps of human slot s |

## 6. Flashing

Install it as in [docs/INSTALL.md](../../../docs/INSTALL.md): copy
`zig-out/firmware/snouty-zero.uf2` (repository root) onto the badge's
`SYCLBADGE` drive (not the RP2350 bootloader drive), eject, and pick the
cart in the badge menu. Start+Select returns to the menu.
`snouty-zero-xip.uf2` is the same game as an XIP cart (M5 shipped only
that one); XIP carts have not yet been confirmed on a badge. To compare
the two, put both on the drive, build with `-Ddebug_overlay=true` (render
time top right) and click the joystick for the OS FPS overlay (fps, and
the flash cache hit rate in the XIP cart).

## 7. Emulated cycle benchmark

badge-bench (`../../badge-bench/README.md`) runs the ELF on an emulated
Cortex-M33 with the badge-calibrated cycle model; read the `busy ms`
column. `../../badge-bench/carts/snouty-zero.toml` sets the defaults.
From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-zero.elf --config badge-bench/carts/snouty-zero.toml --script carts/snouty-zero/tools/scripts/m3_bench.json --frames 1700 --every 60 --symbols
```

The XIP ELF (`snouty-zero-xip.elf`) needs `--config`, because the
defaults file is keyed by ELF basename. The bench charges XIP instruction
fetches at SRAM cost (`--flash-cycles 0`, its XIP default) and never
charges data loads from the flash window, so both ELFs give the same
numbers; the XIP cart copies the active league's art into RAM at race
start so its per-pixel loops never read flash anyway.

Milestone numbers are in `PLAN.md` under each milestone's status.

## 8. Regenerating the data

```sh
python3 tools/build_tracks.py     # tilesets, horizon strips, every .track -> assets/gen/
python3 tools/gen_sin.py          # cart/src/gen/sin.zig
python3 tools/gen_font.py         # assets/gen/font.bin from the SDK font
python3 tools/prepare_assets.py   # sprite sheets (assets/gen/*.png), ASSETS.md
```

## 9. Link race on two badges (M6)

SPEC 8.1 is the design, root `docs/LINK.md` the cable and
`docs/LOCKSTEP.md` the shared lockstep. The simulator has no link, so
LINK RACE is greyed there; the host tests (`cart/src/link_race_test.zig`,
in `zig build test`) run two badges over a virtual cable.

**Hardware check (two badges).**

1. Flash `zig-out/firmware/snouty-zero.uf2` from main onto both badges
   (section 6) and start Snouty Zero on both.
2. Join the two UART headers (J4, the 3-pin JST-SH) with a JST-SH 3-pin
   to 3-pin cable; crossed or straight both work. Not the Qwiic (I2C)
   header.
3. On both: Start through the title, then LINK RACE in the main menu.
   Expected within a second: the lobby says HOST on one badge and GUEST
   on the other, with CROSSED or STRAIGHT top right. `PLUG IN THE CABLE`
   that does not go away means no link (check the cable and the header);
   `WRONG CART: ...` means the other badge runs another link cart.
4. On the host, pick the track: the TRACK row, Left/Right (any track of
   the three leagues). The guest's TRACK line follows it live.
5. On both, pick a machine on the MACHINE row (Left/Right) and press A:
   YOU ... READY, and the other badge shows PEER <machine> READY.
6. On the host, Start (`START: GO` blinks): both badges run the
   countdown together. Each follows its own machine (host: machine 0,
   guest: machine 1, side by side on the back row); the other human is
   the cyan dot on the minimap.
7. Worth trying: ram each other and the rivals (a knockout counts for
   whoever did it); Start on either badge pauses both on the same tick,
   RESUME on either resumes both; pull the cable mid-race: both say
   `PEER LEFT, AI DRIVING` and finish with the AI driving the other
   machine. At the finish each badge shows both humans' place and time;
   A goes back to the lobby for a rematch.

Report anything that says `WAITING FOR PEER` for long stretches with the
cable in, or `DESYNC: RACE ENDED` (that is a determinism bug: note the
track, the machines and roughly when).

**Preview without a cable.** The debug exports make up what the link
would show (section 5). The M6 GIF (`docs/preview_m6.gif`): the lobbies,
then one race on Exhaust Ridge from the host's view and from the
guest's, then the guest's results:

```sh
W=../../zig-out/bin/snouty-zero.wasm
node ../../tools/preview.mjs $W --frames 600 --every 6 --out out/a \
    --call debug_link_view:1 --call-at "90 debug_link_view:2" \
    --press RIGHT:130-131 --press RIGHT:160-161 --press DOWN:200-201 --press A:270-271 \
    --call-at "330 debug_link_view:5" --call-at "420 debug_link_view:3" --call-at "510 debug_link_view:6"
node ../../tools/preview.mjs $W --frames 1560 --every 15 --out out/b --call debug_link_race:4 --call debug_set_autopilot:1
node ../../tools/preview.mjs $W --frames 1560 --every 15 --out out/c --call debug_link_race:5 --call debug_set_autopilot:1 \
    --call-at "1250 debug_link_notice:1" --call-at "1340 debug_link_notice:0"
node ../../tools/preview.mjs $W --frames 7000 --every 12 --start-skip 6550 --out out/d --call debug_link_race:5 --call debug_set_autopilot:1
# number out/a, b, c, d's frames into one out/all/frame_NNNNN.png sequence, then:
python3 ../../tools/make_gif.py out/all docs/preview_m6.gif --scale 2 --ms 100
```
