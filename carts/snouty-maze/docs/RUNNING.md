# Running the Snouty Maze cart

## 1. Prerequisites

- git
- Zig **0.17.0-dev.1936+5a625d5f3** exactly (upstream sycl-badge pins it). Nightly
  tarballs are named `zig-<arch>-<os>-<version>.tar.xz`; the Linux x86_64 one is
  <https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1936+5a625d5f3.tar.xz>.
  Nightlies rotate off ziglang.org; if the URL 404s, try the machengine.org
  mirror or `zigup`. Unpack it and put the `zig` binary on `PATH`.
- Node.js 20 or newer (for the simulator and the tools in `tools/`)
- Optional: Python 3 with Pillow (GIF previews) and numpy (placeholder art)

## 2. Getting the code

There is no git remote yet. The repo lives on the exe.dev VM
`animated-badge.exe.xyz` at `/home/exedev/snouty-maze`. Copy it next to a
checkout of `sycl-badge` (the two must be siblings: `build.zig.zon` points at
`../sycl-badge`, and `src/os/system/tracy_protocol.zig` is a symlink into it):

```sh
mkdir -p work && cd work
git clone https://github.com/ZigEmbeddedGroup/sycl-badge.git
scp -r exedev@animated-badge.exe.xyz:/home/exedev/snouty-maze .
# later, to update: rsync -a --exclude zig-out --exclude .zig-cache --exclude zig-pkg \
#   exedev@animated-badge.exe.xyz:/home/exedev/snouty-maze/ snouty-maze/
```

```
work/
  sycl-badge/
  snouty-maze/
```

Milestones are annotated tags (`git tag -n1`); `git checkout m1` gives the
M1 build.

## 3. Build and test

```sh
cd snouty-maze
zig build                  # firmware + wasm
zig build test             # host tests: maze generator, run merging, clipper, camera
zig build check-float      # fails if f64 soft-float code reached the firmware
node tools/check_golden.mjs   # golden-image regression (needs zig build first)
node tools/check_cycle.mjs    # screensaver loop: finishes a maze, shows the overhead name strip
```

`zig build` writes:

- `zig-out/firmware/snouty-maze.uf2` (for the badge)
- `zig-out/firmware/snouty-maze.elf`
- `zig-out/bin/snouty-maze.wasm` (for the simulator and the headless tools)

A clean build takes about 4 minutes; incremental builds take seconds.
`zig build -Ddebug_overlay=true` starts with the timing overlay on (Select
toggles it either way).

## 4. Controls (M2 screensaver)

From M2 the cart is a screensaver: the autopilot walks the maze with a
left-hand wall follower, and at the finish cell pauses, rises to an overhead
view (with the name strip in the bottom 24 px), swaps in a new maze and
descends to its start cell. The M1 debug camera survives as fly mode.

| Input        | Autopilot states                                  | Fly (debug)                        |
|--------------|---------------------------------------------------|------------------------------------|
| Select       | Toggle the debug overlay                          | same                               |
| Start        | Toggle the name strip permanently on/off          | Reset the camera to the start cell |
| A            | Skip to PAUSE (start the finish sequence now)     | + Up/Down: pitch                   |
| B + Select   | Toggle fly mode                                   | Back to autopilot (resumes WALK from the nearest cell centre, heading = nearest quadrant) |
| Stick        | ignored                                           | Walk / turn (M1 controls: 2 cells/s, 90 degrees/s; B + Up/Down rises/sinks) |

B+Select is a debug chord; it goes away in M4 when takeover lands.

The OS owns Start+Select (back to the menu) and the joystick click (its FPS
overlay); the cart never binds either.

## 5. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
node tools/serve-cart.mjs            # serves zig-out/bin/snouty-maze.wasm on :2468
# or: node tools/serve-cart.mjs path/to/other.wasm --port 2468
```

This serves `http://localhost:2468/cart.wasm` (with CORS) and
`ws://localhost:2468/ws`; after every `zig build` it tells the page to reload.

Terminal 2 runs the simulator UI:

```sh
cd ../sycl-badge/simulator
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
node tools/preview.mjs zig-out/bin/snouty-maze.wasm --frames 600 --every 6 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 100
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
node tools/preview.mjs zig-out/bin/snouty-maze.wasm --frames 1 --out out/pose \
  --call debug_set_size:16 --pose 8,17.5,8,0,90,0
```

The M1 fly-through (walks 3 cells, turns right, walks 3, then climbs with B+Up
while pitching down with A+Down, ending overhead). It drives the M1 debug
camera, so from M2 on it only does this on the `m1` tag (the autopilot
ignores the stick):

```sh
node tools/preview.mjs zig-out/bin/snouty-maze.wasm --script tools/scripts/m1_fly.json \
  --frames 600 --every 6 --out out/fly
python3 tools/make_gif.py out/fly docs/preview_m1.gif --scale 3 --ms 100
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

The M2 screensaver loop (A pressed at tick 240 skips to the finish
sequence: pause, rise, overhead with the name strip, descend into the new
maze, walk):

```sh
node tools/preview.mjs zig-out/bin/snouty-maze.wasm --script tools/scripts/m2_cycle.json \
  --frames 1000 --every 10 --out out/m2
python3 tools/make_gif.py out/m2 docs/preview_m2.gif --scale 3 --ms 100
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
  6 TELEPORT (M3), 7 FLY), ticks in it, mazes completed, heading (0 N, 1 E, 2 S, 3 W), and
  whether the name strip is showing

### Screensaver loop: `tools/check_cycle.mjs`

```sh
node tools/check_cycle.mjs                # runs A, B and C
node tools/check_cycle.mjs --only B       # just the overhead/name-strip check
node tools/check_cycle.mjs --frames 20000 # longer unattended run for A
```

Each run is one `preview.mjs --quiet` with `--expect`s:

- A: no input for 9000 ticks; `debug_cycles >= 1` (walked a maze to the
  finish and went round the finish sequence)
- B: A at tick 0, 241 ticks; `debug_state == 4` (OVERHEAD: after 30 pause
  and 150 rise ticks it runs from tick 180 to 299, so tick 240 is its
  middle) and `debug_name_strip == 1`
- C: A at tick 0, 1000 ticks; `debug_cycles >= 1`

It prints PASS/FAIL per run with the final state, cycle count, cell and
heading, plus preview's error lines on a FAIL. Options `--wasm FILE`,
`--seed S` (default 1). Exit 0 all pass, 2 usage error, 3 any failure.

### Placeholder art

```sh
python3 tools/prepare_assets.py --placeholders --contact docs/placeholders.png
python3 tools/prepare_assets.py --check       # validate delivered art in assets/gen/
```

Draws and validates the eight sheets in `assets/gen/` (sizes, cell grid,
colour counts after RGB565, magenta key, 1 px empty border); `zig build`
converts them into the `gfx` module.

## 7. Flash the badge

1. Connect the badge over USB-C. It shows up as a USB mass-storage drive.
2. Copy `zig-out/firmware/snouty-maze.uf2` onto the drive (replacing
   `CURRENT.UF2`). The badge reboots into the cart.

## 8. Reading performance on the badge

- Joystick click shows the OS FPS overlay (the OS draws it; it works in any
  cart).
- Select toggles the cart's overlay: render time in microseconds and fps on
  the first line, the camera cell and heading (`x,z  N/E/S/W`) on the second,
  so a photo of the screen records where the camera was.

For the M1 hardware gate (SPEC.md section 16), report fps and render
microseconds at the start cell looking down the longest corridor and at the
overhead view (B+Up to about height 13, A+Down until looking straight down;
with a 16x16 maze if the build offers one).
