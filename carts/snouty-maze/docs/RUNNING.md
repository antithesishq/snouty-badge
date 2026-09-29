# Running the Snouty Maze cart

The cart lives in `carts/snouty-maze/` of the snouty-badge repository.
Commands below run from that directory unless noted; only `zig build` runs
from the repository root (`../..`), and its outputs are in the root
`zig-out/` (`../../zig-out/...` from here).

## 1. Prerequisites

Zig, Node.js, Python with Pillow and git: see `../../docs/RUNNING.md` at the
repository root. This cart also uses numpy (optional, for the placeholder
art in `tools/prepare_assets.py --placeholders`).

## 2. Getting the code

Cloning the repository with its `sycl-badge/` submodule is described in
`../../docs/RUNNING.md` at the repository root. Until the `monorepo` branch
is on GitHub it lives on the exe.dev VM `animated-badge.exe.xyz` at
`/home/exedev/snouty-badge`:

```sh
git clone -b monorepo exedev@animated-badge.exe.xyz:/home/exedev/snouty-badge
cd snouty-badge && git submodule update --init
# later, to update: git pull (or rsync -a --exclude zig-out --exclude .zig-cache --exclude zig-pkg \
#   exedev@animated-badge.exe.xyz:/home/exedev/snouty-badge/ snouty-badge/)
```

Milestones are annotated tags (`git tag -n1 'snouty-maze/*'`:
`snouty-maze/a1`, `/a2`, `/m0`..`/m3`); `git checkout snouty-maze/m1` gives
the M1 build.

## 3. Build and test

From the repository root:

```sh
zig build -Dcart=snouty-maze   # firmware + wasm (plain `zig build` builds every cart)
zig build test             # host tests: maze generator, run merging, clipper, camera, autopilot, actors (and the other carts')
zig build check-float      # fails if f64 soft-float code reached the firmware
```

Then from `carts/snouty-maze/`:

```sh
node tools/check_golden.mjs   # golden-image regression (needs zig build first)
node tools/check_cycle.mjs    # screensaver loop, actor triggers and LEDs (runs A..F)
```

`zig build` writes, in the root `zig-out/`:

- `zig-out/firmware/snouty-maze.uf2` (for the badge)
- `zig-out/firmware/snouty-maze.elf`
- `zig-out/bin/snouty-maze.wasm` (for the simulator and the headless tools)

A clean build of this cart takes about 4 minutes (all carts: several);
incremental builds take seconds.
`zig build -Dcart=snouty-maze -Ddebug_overlay=true` starts with the timing overlay on (Select
in fly mode toggles it either way; see section 4) and compiles in the
B+Select fly chord. `-Dmaze_size=N` (4..16, default 12) sets the maze size;
16x16 is not the default because its worst frame is 14.6 ms modelled
(PLAN.md, "A4 result").

## 4. Controls (M4)

From M2 the cart is a screensaver: the autopilot walks the maze with a
left-hand wall follower, and at the finish cell pauses, rises to an overhead
view (with the name strip in the bottom 24 px), swaps in a new maze and
descends to its start cell. The M1 debug camera survives as fly mode. From
M3 the maze is inhabited: Snouty wanders the corridors, the smiley flips the
view upside down (a second one rights it) when the camera walks into its
cell, the sphere teleports the camera to a random cell, the Zig mark spins
in a junction and the Start button spins in the first cell. From M4 the
new maze carves itself during the overhead view (the pink tile is the
carving head), the Iris mark sits beside the name strip, and the stick takes
the camera over.

| Input        | Autopilot states                                  | Takeover (MANUAL)                  | Fly (debug builds only)            |
|--------------|---------------------------------------------------|------------------------------------|------------------------------------|
| Stick        | While walking or turning: take the camera over    | Up / Down: one cell forward / back (held repeats); Left / Right: pivot 90 degrees; a wall blocks the move | Walk / turn (M1 controls: 2 cells/s, 90 degrees/s; B + Up/Down rises/sinks) |
| Select       | Toggle the neopixels (default off)                | Toggle the neopixels               | Toggle the debug overlay           |
| Start        | Toggle the name strip permanently on/off          | Same                               | Reset the camera to the start cell |
| A            | Skip to PAUSE (start the finish sequence now; ignored during TELEPORT) | Same         | + Up/Down: pitch                   |
| B + Select   | Toggle fly mode (only with `-Ddebug_overlay=true`) | Same                              | Back to autopilot (resumes WALK from the nearest cell centre, heading = nearest quadrant) |

Takeover: a stick press during WALK or TURN starts MANUAL (other states
ignore the stick). Mid-cell the camera finishes the step to the next cell
centre (Down reverses it), and a turn in progress finishes first; a tap
during a move is queued for the next cell centre. After 5 s (300 ticks)
with no stick input the autopilot resumes from the current cell and
heading. Walking into the finish cell starts the finish sequence; the
smiley and sphere still work, and a teleport returns to MANUAL.

The overlay flag persists across the mode switch, so in a
`-Ddebug_overlay=true` build (which starts with it on anyway) B+Select,
Select, B+Select toggles it during the screensaver.

### LEDs

The five neopixels are off at start; Select (in any autopilot state)
toggles them. They are dim on purpose: every channel stays at or below
10/255, because the badge LEDs are painfully bright above that. All five
show the same colour:

| When | Colour |
|------|--------|
| WALK, TURN, PAUSE, RISE, DESCEND, FLY | dim brick (r 6, g 2, b 1) |
| MANUAL (takeover) | amber (r 6, g 4, b 0) |
| smiley flip | purple (r 6, b 10) added on top, fading out over 90 ticks (1.5 s) |
| TELEPORT | white (10, 10, 10) |
| OVERHEAD | brick hue breathing, red 1..10, one breath per 3 s |

B+Select is a debug chord, compiled in only with `-Ddebug_overlay=true` (M4).

The OS owns Start+Select (back to the menu) and the joystick click (its FPS
overlay); the cart never binds either.

## 5. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/snouty-maze.wasm on :2468
# or: node ../../tools/serve-cart.mjs path/to/other.wasm --port 2468
```

This serves `http://localhost:2468/cart.wasm` (with CORS) and
`ws://localhost:2468/ws`; after every `zig build` it tells the page to reload.

Terminal 2 runs the simulator UI:

```sh
cd ../../sycl-badge/simulator
npm install
npm run dev
```

Then open <http://localhost:1234>. (<https://badgesim.microzig.tech/> also
fetches from `localhost:2468`; not verified with this cart.)

| Badge            | Keyboard           |
|------------------|--------------------|
| Joystick         | Arrow keys or WASD |
| Joystick click   | Shift              |
| A                | Z or K             |
| B                | X or J             |
| Start            | Enter or Y         |
| Select           | Backspace or T     |
| System menu      | Escape             |

Upstream simulator quirks, worked around in `cart/src/main.zig` exactly as in
snouty-bugs: the simulator displays only the fixed region at 0x20, so
`present_wasm()` copies each frame there (pre-swapping red and blue, which
the simulator's compositor has backwards); and it writes buttons to 0x04,
which `read_controls()` reads on wasm. Upstream demo carts show garbage and
get no input; this one should look and behave as on hardware. If the red
bricks ever look blue, the swap and the simulator have gotten out of step.
The simulator's frame rate says nothing about the badge's.

## 6. Headless preview (no browser)

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-maze.wasm --frames 600 --every 6 --out out/
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 100
```

`preview.mjs` runs `start()` and then `update()` N times, writing every K-th
frame to `out/frame_XXXX.png` plus `out/frames.json` (metadata). Options:

- `--start-skip S`: skip the first S updates
- `--fb-addr auto|dwarf|sim|0xADDR`: choose which framebuffer to dump
- `--seed N`: seed for `cart.rand()`; the maze is generated from it, so the
  same seed gives the same maze
- `--controls BITS`, `--press UP:0-59,LEFT:60-119`, `--script FILE.json`:
  inputs, OR-ed per tick. A script is a JSON array of
  `{ "from": 60, "to": 99, "hold": ["B", "UP"] }` entries (inclusive ticks,
  buttons `A B START SELECT UP DOWN LEFT RIGHT`; `CLICK` is refused)
- `--call NAME[:ARG]` (repeatable): after `start()`, call a wasm export with
  no argument or one integer, in command-line order, e.g.
  `--call debug_set_size:16`, `--call debug_set_seed:7`
- `--pose x,y,z,yaw,pitch,roll`: after the `--call`s and before the first
  update, place the camera with `debug_set_camera` (cells, degrees; yaw 0
  faces north, positive pitch looks down, roll 180 is upside down)
- `--dump-exports debug_cell_x,debug_cell_z` and
  `--expect "debug_state == 0"`: read zero-argument exports after the last
  update; a failed expectation exits 3
- `--quiet`: no PNGs (soak runs); `--raw-colors`: no red/blue swap

Fixed views, e.g. the hardware-gate overhead pose of a 16x16 maze:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-maze.wasm --frames 1 --out out/pose \
  --call debug_set_size:16 --pose 8,17.5,8,0,90,0
```

The M1 fly-through (walks 3 cells, turns right, walks 3, then climbs with B+Up
while pitching down with A+Down, ending overhead). It drives the M1 debug
camera, so it only does this on the `snouty-maze/m1` tag (M2 and M3 ignore the
stick; from M4 holding Up takes the camera over instead):

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-maze.wasm --script tools/scripts/m1_fly.json \
  --frames 600 --every 6 --out out/fly
python3 ../../tools/make_gif.py out/fly docs/preview_m1.gif --scale 3 --ms 100
```

Exit codes: 1 the cart cannot be loaded, 2 usage error (including a `--call`
or `--pose` export the cart does not have), 3 the cart trapped or an
expectation failed. One update is one 60 Hz tick.

### Golden images: `tools/check_golden.mjs`

```sh
node tools/check_golden.mjs                   # compare every pose
node tools/check_golden.mjs --only overhead,rolled
node tools/check_golden.mjs --tolerance 20    # allow 20 differing pixels
node tools/check_golden.mjs --update          # accept the current renders
```

`tests/golden/poses.json` lists the poses
(`{ name, seed, pose, calls, frames }`). Each is rendered through
`preview.mjs` into `out/golden/<name>/` and compared pixel for pixel with
`tests/golden/<name>.png`; a FAIL prints the number of differing pixels and
the first one, and writes `out/golden/<name>/diff.png` (differences in red).
Exit 0 all pass, 1 a golden is missing (run `--update`), 3 any failure.
Only run `--update` after looking at the new frames: it is how a deliberate
rendering change is accepted.

The M3 poses `actors` and `overhead_actors` place all four actors with
`debug_place` in the seed 1 corridor at x = 11 (cells (11, 0)-(11, 6), the
longest straight run of that maze): Snouty in (11, 1), the logo in (11, 2),
the smiley in (11, 3), the sphere in (11, 5). `actors` looks south down
that corridor from its north end, raised and off to one side
(`11.88,0.95,0.08,190,14,0`) so the four stack up the screen (the sphere
shows only above the smiley); `overhead_actors` is the overhead pose with
the same calls (Snouty as the floor sprite, the quads edge-on). Poses run
in fly mode, where the smiley and sphere triggers are off.

The M2 screensaver loop (A pressed at tick 240 skips to the finish
sequence: pause, rise, overhead with the name strip, descend into the new
maze, walk):

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-maze.wasm --script tools/scripts/m2_cycle.json \
  --frames 1000 --every 10 --out out/m2
python3 ../../tools/make_gif.py out/m2 docs/preview_m2.gif --scale 3 --ms 100
```

Debug knobs (wasm exports for `--call`):

- `--call debug_fade:N` (N 0..16): darkens every frame through a 4x4 Bayer
  mask, N of every 16 pixels black (the M3 teleport dissolve), e.g.
  `--call debug_fade:8 --frames 1` gives a checkerboard of black
- `--call debug_set_roll:N` (degrees): rolls the camera, to exercise the
  roll cap (after 1200 ticks rolled, the camera unrolls over 30 ticks)
- `--call debug_skip`: same as pressing A (only acts once updates run)
- `--dump-exports debug_state,debug_state_tick,debug_cycles,debug_heading,debug_name_strip`:
  autopilot state (0 WALK, 1 TURN, 2 PAUSE, 3 RISE, 4 OVERHEAD, 5 DESCEND,
  6 TELEPORT, 7 FLY), ticks in it, mazes completed, heading (0 N, 1 E, 2 S, 3 W), and
  whether the name strip is showing

M3 actor and LED exports:

- `--call debug_place:CODE`: move an actor to a cell, `CODE = kind * 10000
  + x * 100 + z` with kind 0 Snouty, 1 smiley, 2 sphere, 3 logo; e.g.
  `debug_place:10100` puts the smiley in (1, 0), `debug_place:20400` the
  sphere in (4, 0), `debug_place:200` Snouty in (2, 0)
- `debug_snouty_x/z`, `debug_smiley_x/z`, `debug_sphere_x/z`,
  `debug_logo_x/z`: the actors' cells
- `debug_flips`, `debug_teleports`: smiley and sphere triggers so far
- `debug_roll_deg`: camera roll, 0..359 (180 after one flip)
- `debug_fade_level`: current dissolve level, 0..16 (the larger of
  `debug_fade` and the teleport fade)
- `debug_leds` (1 when the LEDs are on), `debug_led_max` (largest channel
  written this tick, never above 10)

### Screensaver loop: `tools/check_cycle.mjs`

```sh
node tools/check_cycle.mjs                # runs A..I
node tools/check_cycle.mjs --only B,D     # just the overhead and flip checks
node tools/check_cycle.mjs --frames 20000 # longer unattended run for A
```

Each run is one `preview.mjs --quiet` with `--call`s, `--press`es and
`--expect`s:

- A: no input for 9000 ticks; `debug_cycles >= 1` (walked a maze to
  the finish and went round the finish sequence)
- B: A at tick 0, 241 ticks; `debug_state == 4` (OVERHEAD: after 30 pause
  and 150 rise ticks it runs from tick 180 to 299, so tick 240 is its
  middle) and `debug_name_strip == 1`
- C: A at tick 0, 1000 ticks; `debug_cycles >= 1`
- D flip: `--call debug_place:10100` (smiley in (1, 0), the first cell the
  seed 1 camera walks into), 100 ticks; `debug_flips == 1`,
  `debug_roll_deg == 180`, and the smiley has left (1, 0) (checked by
  check_cycle itself, since `--expect` cannot say "x != 1 or z != 0")
- E teleport: `--call debug_place:20100` (sphere in (1, 0)), 100 ticks;
  `debug_teleports == 1`, `debug_state < 2` (walking again) and
  `debug_fade_level == 0`
- F leds: Select at tick 0, 10 ticks; `debug_leds == 1` and
  `0 < debug_led_max <= 10`
- G takeover: Up held for ticks 0..44; `debug_state == 8` (MANUAL) and
  the camera moved to cell (1, 0)
- H idle return: Right at tick 0, 400 ticks; back in WALK or TURN
  (`debug_manual_idle` counts the idle ticks)
- I carving: A at tick 0, 200 ticks (OVERHEAD tick 19); `debug_state == 4`
  and `debug_carve_shown < debug_carve_count`

It prints PASS/FAIL per run with the final state, cycle count, cell and
heading (plus the run's own exports), and preview's error lines on a
FAIL. Options `--wasm FILE`, `--seed S` (default 1). Exit 0 all pass, 2
usage error, 3 any failure. D and E place the actor in (1, 0) because that
is the first cell the seed 1 camera walks into; with other seeds they are
not meaningful (seed 4, for one, never enters (1, 0) in 100 ticks).

Teleports restart the walk from a random cell, so the unattended finish
time now varies more than in M2. First tick with `debug_cycles >= 1`
(the walk, the 450-tick finish sequence and the descent all done), no
input, measured on the M3 build (smallest N for which `preview.mjs --quiet
--seed S --frames N --expect "debug_cycles >= 1"` passes):

| Seed | Ticks | Minutes |
|------|-------|---------|
| 1 | 2622 | 0.7 |
| 2 | 3277 | 0.9 |
| 3 | 5307 | 1.5 |
| 4 | 3193 | 0.9 |
| 5 | 3811 | 1.1 |

Run A keeps its 9000-tick default (3.4x the seed 1 time, 1.7x the slowest
of these five); `--frames` raises it for other seeds.

The M3 tour (seed 1: the smiley in (1, 0) flips the view on the first step
(tick 20), the camera walks the (2, 0)-(6, 0) corridor upside down towards
the sphere in (4, 0), which teleports it at tick 340, then A at tick 700
skips to the finish sequence):

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-maze.wasm --script tools/scripts/m3_tour.json \
  --frames 1000 --every 10 --out out/m3 --call debug_place:10100 --call debug_place:20400
python3 ../../tools/make_gif.py out/m3 docs/preview_m3.gif --scale 3 --ms 100
```

### Art

```sh
python3 tools/prepare_assets.py --from-w95 assets/src/w95 --art ../../snouty-art/out/maze \
  --contact docs/w95_assets.png                 # what assets/gen/ is built from
python3 tools/prepare_assets.py --placeholders --contact docs/placeholders.png
python3 tools/prepare_assets.py --check       # validate delivered art in assets/gen/
```

`--from-w95` (the committed default since A1) downsamples the textures
extracted from the original screensaver (`assets/src/w95/SOURCE.md`) to
the 32x32 4-bit sheets in `assets/gen/`; `--art DIR` takes Snouty, the
Zig mark (`logo`), the Iris mark (`iris`) and the Start button from the
snouty-art maze pack (`python3 tools/build_maze.py` there, output in
`out/maze/`); the finish tile stays procedural.
`--placeholders` draws every sheet procedurally instead. Both validate (sizes, cell grid, colour counts after
RGB565, magenta key, 1 px empty border); `zig build` converts the PNGs into
the `gfx` module. Goldens in `tests/golden/` are baselined on the w95 art.

## 7. Flash the badge

1. Connect the badge over USB-C. It shows up as a USB mass-storage drive.
2. Copy `zig-out/firmware/snouty-maze.uf2` (repository root) onto the drive (replacing
   `CURRENT.UF2`). The badge reboots into the cart.

## 8. Reading performance on the badge

- Joystick click shows the OS FPS overlay (the OS draws it; it works in any
  cart).
- The cart's own overlay shows render time in microseconds and fps on the
  first line, the camera cell and heading (`x,z  N/E/S/W`) on the second,
  so a photo of the screen records where the camera was. Build with
  `zig build -Dcart=snouty-maze -Ddebug_overlay=true` to have it on (from
  M4 that build is also the only one with the B+Select fly chord).

For the M1 hardware gate (SPEC.md section 16), report fps and render
microseconds at the start cell looking down the longest corridor and at the
overhead view (in a `-Ddebug_overlay=true` build: B+Select into fly, B+Up to about height 13, A+Down until looking straight down;
with a 16x16 maze if the build offers one). For M3, also report the
screensaver's render microseconds while an actor is in view (Snouty close
up is the worst case) and during the overhead view.
