# Running the Snouty Flyover cart

Snouty Flyover (`snouty-flyover`, working title Memory Lane) is a SYCL
Badge V2 cart: a Comanche-style voxel heightfield flight over a strip of
terrain generated on the badge as the camera flies. The cart is locked to
30 fps (`cart.set_vsync_enabled(1000.0 / 30.0)`, the `-Dflyover_fps` knob),
so one `update()` is one frame and everything moves by frame count, not
wall time.

M1 is the world engine: the strip is a sequence of 64-row Bus segments and
192-row districts (Bus 0..63, HEAP 64..255, Bus 256..319, SORT 320..511,
then HEAP again at 576, SORT at 832, and so on), generated on the badge as
the camera flies. The HEAP mallocs and frees blocks as you pass and its B
verb sweeps a white GC wall down the district; the SORT runs a live
quicksort on the band ahead of the camera (white pivot, two swaps per
frame) and B shuffles that band and re-sorts it at eight swaps per frame.
Palette pulses run along the Bus lanes and the free list, a title card
names each segment as you enter it and the caption at the bottom names
the B verb (on a Bus: the district ahead). The autopilot flies by default
(a slow serpentine, a district's own cruise altitude, B pressed once per
district); any stick, A or B input takes over and 15 s without input hands
back. Tree, Hash, Stack, Pipeline and water come in M2.

Controls (SPEC.md section 3; the last column is what M1 does):

| Input        | Design                                                   | M1                                   |
|--------------|----------------------------------------------------------|--------------------------------------|
| Left / Right | Bank and steer across the strip (roll shears the horizon) | roll, bank-to-turn, x wraps; takes manual control |
| Up / Down    | Pitch: dive / climb (altitude clamped above the terrain)  | horizon 40..88 and cruise altitude; takes manual control |
| A            | Boost while held                                          | 0.75 -> 1.9 cells per frame; takes manual control |
| B            | The district verb                                         | HEAP: collect garbage, SORT: shuffle the band; nothing on a Bus yet (M3); takes manual control |
| Select       | Skip to the next district                                 | nothing yet (M3)                     |
| Start        | Toggle autopilot / manual flight                          | toggles (on the press); 450 frames (15 s) without input also returns to autopilot |

The autopilot (on at boot) steers toward x = 128 on a Bus and
128 + 16 sin(frame / 512 turn) in a district, with the stick clamped to
1/3 so the roll stays within about 6 rows; it holds `floor` + the live
district's altitude (HEAP 40, SORT 110), looks down a little in the SORT
(horizon row 52), and presses B when the camera crosses the district's
`verb_at` row (HEAP local row 30, SORT 60).

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

Input scripts live in `tools/scripts/`:

- `attract.json`: `[]`, no input; the autopilot flies. Used with
  `--frames 1800` (rows 0..1322: Bus, HEAP, Bus, SORT, Bus, HEAP, Bus,
  SORT, Bus) and by badge-bench.
- `m1_manual.json` (1200 frames): stick right 60-120 (takes manual
  control), B at 200 (HEAP garbage collection), stick left 400-460, B at
  600 (SORT shuffle; the camera is at row ~439, inside the SORT), Start at
  900 (autopilot back on).
- `m0_fly.json` (600 frames, kept from M0): stick right 120-200, left
  300-380, A held 450-540. The autopilot flies frames 0-119, then the
  stick takes over; frame 599 still reads `debug_cam_y` 540.

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
| `debug_world_check`    | regenerates every row the ring should hold outside the live district (whose cells the tick edits) and counts mismatching cells; 0 is correct |
| `debug_map_height(x, y)`, `debug_map_colour(x, y)` | one ring cell (two arguments, so not for `--dump-exports`); 0xFFFF if row y is not in the ring |
| `debug_segment_kind`, `debug_segment_index` | segment under the camera: kind 0 Bus, 1 HEAP, 2 SORT; index = 2 * pair (+1 for the district) |
| `debug_live_kind`      | kind of the live (ticked) district: the one under the camera, or the next one on a Bus |
| `debug_autopilot`      | 1 while the autopilot flies, 0 in manual flight                  |
| `debug_cam_ground`     | terrain height of the cell under the camera                      |
| `debug_cam_clear`      | `debug_cam_alt` - `debug_cam_ground`; above 0 means the camera is above the terrain |
| `debug_sort_state`     | live SORT: running band (255 none) + 256 * sorted bands + 65536 while it re-sorts after B |
| `debug_sort_max_bars`  | most SORT bars (7 rows x 4 cells each) rewritten in one frame since boot: tick alone in the low 16 bits, a frame with a shuffle in the high 16 |

Checks that hold at M1:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-flyover.wasm --frames 1800 --quiet \
    --script tools/scripts/attract.json --out out/ --at "1799 debug_world_check == 0" \
    --at "1799 debug_autopilot == 1" --at "1799 debug_cam_clear > 0"
node ../../tools/preview.mjs ../../zig-out/bin/snouty-flyover.wasm --frames 1200 --quiet \
    --script tools/scripts/m1_manual.json --out out/ \
    --at "59 debug_autopilot == 1" --at "61 debug_autopilot == 0" \
    --at "600 debug_segment_kind == 2" --at "899 debug_autopilot == 0" \
    --at "900 debug_autopilot == 1" --at "700 debug_cam_clear > 0" \
    --at "1199 debug_world_check == 0"
```

In the attract run the camera ends at row 1322 (`debug_cam_y`), x stays in
112..144 and the roll within +-6 rows.

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
(budget 22 ms, 1800 frames, `attract.json`). From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-flyover.elf --script carts/snouty-flyover/tools/scripts/attract.json --frames 1800 --every 60 --symbols
```

The first run creates `badge-bench/.venv` (needs network, under a minute);
an 1800-frame run takes about two minutes at M1 (worst 11.03 ms, mean 6.66). The milestone numbers are in
`PLAN.md` under each milestone's status.
