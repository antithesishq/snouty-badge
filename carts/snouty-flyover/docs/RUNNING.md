# Running the Snouty Flyover cart

Snouty Flyover (`snouty-flyover`, working title Memory Lane) is a SYCL
Badge V2 cart: a Comanche-style voxel heightfield flight over a strip of
terrain generated on the badge as the camera flies. The cart is locked to
30 fps (`cart.set_vsync_enabled(1000.0 / 30.0)`, the `-Dflyover_fps` knob),
so one `update()` is one frame and everything moves by frame count, not
wall time.

M0 is the scaffold: a noise floor with a grid every 64 cells and a row of
eight test blocks (heights 16 to 128) every 128 rows, the sky and the Iris
sun, and manual flight. Districts, text and the autopilot come in M1.

Controls (SPEC.md section 3; the last column is what M0 does):

| Input        | Design                                                   | M0                                   |
|--------------|----------------------------------------------------------|--------------------------------------|
| Left / Right | Bank and steer across the strip (roll shears the horizon) | yes: roll, bank-to-turn, x wraps     |
| Up / Down    | Pitch: dive / climb (altitude clamped above the terrain)  | yes: horizon 40..88, cruise altitude |
| A            | Boost while held                                          | yes: 0.75 -> 1.9 cells per frame     |
| B            | The district verb                                         | nothing yet                          |
| Select       | Skip to the next district                                 | nothing yet                          |
| Start        | Toggle autopilot / manual flight                          | nothing yet                          |

Start+Select returns to the badge menu and the joystick click toggles the
OS FPS overlay; both belong to the OS. The cart has no sound and never
writes the neopixels.

The cart lives in `carts/snouty-flyover/` of the snouty-badge repository.
Commands below run from that directory unless noted; only `zig build` and
`badge-bench/bench.sh` run from the repository root (`../..`), and build
outputs are in the root `zig-out/` (`../../zig-out/...` from here).

## 1. Prerequisites

Zig, Node.js, Python with Pillow and git: see `../../docs/RUNNING.md` at the
repository root. The emulated benchmark (section 7) also needs Python 3.9 or
newer with the `venv` module (Debian/Ubuntu: `apt install python3-venv`); it
installs its own packages into `badge-bench/.venv` on the first run.

## 2. Checkout layout

Cloning the repository with its `sycl-badge/` submodule is described in
`../../docs/RUNNING.md` at the repository root. Milestones are annotated
tags (`git tag -n1 'snouty-flyover/*'`, from `snouty-flyover/m0`). From the
exe.dev VM the remote is reached through the GitHub integration host
`github.int.exe.xyz`.

## 3. Build

From the repository root:

```sh
zig build -Dcart=snouty-flyover   # only this cart; plain `zig build` builds every cart
```

Options (all from the root):

| Option | Values (default first) | Meaning |
|--------|------------------------|---------|
| `-Dflyover_fps` | `30`, `60` | vsync lock; SPEC section 10 decides 60 from the M1/M2 bench |
| `-Dflyover_depth` | `256`, `128` | map ring depth in rows; 128 halves the map memory and the view distance (`world.gen_ahead`) |
| `-Ddebug_overlay` | `false`, `true` | draws the frame time in microseconds, the fps it implies and the camera row, top right |

```sh
zig build -Dcart=snouty-flyover -Ddebug_overlay=true
zig build -Dcart=snouty-flyover -Dflyover_fps=60 -Dflyover_depth=128
```

A clean build of this cart takes about 2.5 minutes (all carts: several).
This writes, in the root `zig-out/`:

- `zig-out/firmware/snouty-flyover.uf2` (for the badge)
- `zig-out/firmware/snouty-flyover.elf` (for badge-bench and `size -A`)
- `zig-out/bin/snouty-flyover.wasm` (for the simulator)

`zig build check-float -Dcart=snouty-flyover` (also from the root) runs the
shared `tools/check_float.mjs` on the ELF; the cart is all-integer, so it
must pass.

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd carts/snouty-flyover
node ../../tools/serve-cart.mjs   # serves ../../zig-out/bin/snouty-flyover.wasm on :2468
```

This serves `http://localhost:2468/cart.wasm` (with CORS) and
`ws://localhost:2468/ws`. When the file changes, which happens after every
`zig build`, it sends `reload` to the page.

Terminal 2 runs the simulator UI:

```sh
cd ../../sycl-badge/simulator
npm install
npm run dev
```

Then open <http://localhost:1234>. The simulator calls `update()` 60 times a
second whatever the cart's vsync says, so the 30 fps build flies twice as
fast there; judge the picture, not the speed.

Simulator keys (from `sycl-badge/simulator/README.md`):

| Badge            | Keyboard           |
|------------------|--------------------|
| Joystick         | Arrow keys or WASD |
| Joystick click   | Shift              |
| A                | Z or K             |
| B                | X or J             |
| Start            | Enter or Y         |
| Select           | Backspace or T     |
| System menu      | Escape             |

The upstream simulator quirks (it shows a fixed memory region at 0x20 with
red and blue swapped and writes buttons to 0x04, which the cart API no
longer reads) are handled by `present_wasm()` and `read_controls()` in
`cart/src/main.zig`, as in every cart here; `../snouty-reflections/docs/RUNNING.md`
section 4 has the long version.

## 5. Headless preview (no browser)

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-flyover.wasm --frames 600 --every 100 \
    --script tools/scripts/m0_fly.json --out out/ \
    --dump-exports debug_frame,debug_cam_x,debug_cam_y,debug_cam_alt
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 33
```

`preview.mjs` runs `start()` and then `update()` N times, writing every K-th
frame to `out/frame_XXXX.png` and metadata to `out/frames.json`. The full
option list (`--press`, `--expect`, `--at`, `--quiet`, ...) is in its header
comment and in `../snouty-reflections/docs/RUNNING.md` section 5. One update
is one 30 fps frame, so `--every 1 --ms 33` is real speed.

Input scripts live in `tools/scripts/`: `m0_fly.json` is 600 frames of
cruise with the stick right for frames 120-200, left 300-380 and A held
450-540 (the bench script too).

Debug exports (zero-argument wasm functions unless noted, usable with
`--dump-exports`, `--expect` and `--at`):

| Export                 | Meaning                                                          |
|------------------------|------------------------------------------------------------------|
| `debug_frame`          | frame counter (number of `update()` calls so far)                |
| `debug_render_us`      | world + render time of the last frame in microseconds; always 0 in wasm |
| `debug_pixel_checksum` | sum of all framebuffer words, for render regression tests        |
| `debug_cam_x`, `debug_cam_y` | camera cell (x wraps at 256, y only grows)                 |
| `debug_cam_alt`        | camera altitude in cells                                         |
| `debug_cam_yaw`        | heading in 1/1024 turn, positive toward +x, capped at +-64       |
| `debug_cam_roll`       | horizon shear in rows, negative when banked right                |
| `debug_horizon`        | horizon screen row, 64 level                                     |
| `debug_world_check`    | regenerates every row the ring should hold and counts mismatching cells; 0 is correct |
| `debug_map_height(x, y)`, `debug_map_colour(x, y)` | one ring cell (two arguments, so not for `--dump-exports`); 0xFFFF if row y is not in the ring |

With the script above, frame 599 reads `debug_cam_y` 541 and
`debug_world_check` 0; `--at "599 debug_world_check == 0"` makes that a check.

## 6. Flashing

1. Put the badge in bootloader mode and connect it over USB-C. It shows up
   as a USB mass-storage drive.
2. Copy `zig-out/firmware/snouty-flyover.uf2` (repository root) onto the drive.
3. Pick the cart in the badge menu. Start+Select returns to the menu.

For on-badge timing flash a `-Ddebug_overlay=true` build, or press the
joystick for the OS FPS overlay.

## 7. Emulated cycle benchmark

badge-bench (`../../badge-bench/README.md`) runs the ELF on an emulated
Cortex-M33 with the badge-calibrated cycle model; read the `busy ms`
column. `../../badge-bench/carts/snouty-flyover.toml` sets the defaults
(budget 22 ms, 600 frames, `m0_fly.json`). From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-flyover.elf --script carts/snouty-flyover/tools/scripts/m0_fly.json --frames 600 --every 60 --symbols
```

The first run creates `badge-bench/.venv` (needs network, under a minute);
a 600-frame run takes about 20 s at M0. The milestone numbers are in
`PLAN.md` under each milestone's status.
