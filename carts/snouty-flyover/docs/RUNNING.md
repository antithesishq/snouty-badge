# Running the Snouty Flyover cart

Snouty Flyover (`snouty-flyover`, working title Memory Lane) is a SYCL
Badge V2 cart: a Comanche-style voxel heightfield flight over a strip of
terrain generated on the badge as the camera flies. The cart is locked to
30 fps (`cart.set_vsync_enabled(1000.0 / 30.0)`, the `-Dflyover_fps` knob),
so one `update()` is one frame and everything moves by frame count, not
wall time.

M1 is the world engine: the strip is a sequence of 64-row Bus segments and
192-row districts, generated on the badge as the camera flies; each
district has its own dataflow (a tick that edits cells every frame) and a
B verb. Palette pulses run along the Bus lanes and the district paths, a
title card names each segment as you enter it and the caption at the
bottom names the B verb (on a Bus: the district ahead). The autopilot
flies by default (a slow serpentine, a district's own altitude track, B
pressed once per district); any stick, A or B input takes over and 15 s
without input hands back.

M2 completes the district cycle: Bus 0..63, HEAP 64..255, Bus, SORT
320..511, Bus, TREE 576..767, Bus, HASH 832..1023, Bus, STACK 1088..1279,
Bus, PIPELINE 1344..1535, then HEAP again at 1600 (one cycle is 1536
rows, 2048 frames at cruise). The STACK is a terraced red canyon on the
centre line whose floor steps down one frame (8 cells) every 13 rows to
10 frames deep and back up at the far end; the autopilot dives with the
floor (14 cells over it) along the call/return signal. B pushes a frame:
the canyon from 8 rows ahead to the district end gets one frame deeper
(a wave over 10 frames); pushing where the canyon is already 10 deep
overflows the stack: the floor falls into a black pit and the sky
flashes white. The PIPELINE starts with a mirror lake (the renderer's
reflection pass: mirrored skyline, sky and Iris sun), then three streams
with filter dams, braiding up to six springs at the far end; packets are
dashes flowing along the channels toward the camera. B bursts the pipe:
the stream sections between the dams and the merge point flood (sink to
the water line over 20 frames), hold 40 frames and drain back row by row.
The frame rate stays locked at 30 fps (SPEC 10, decided in M2).

M3 puts every verb in the attendee's hands (SPEC 13). B on a Bus sends a
packet (a white block racing down the lane nearest the camera to the Bus
end; the autopilot sends one per Bus), and the Bus card's third line
names the district after it (`next: SORT`). Select skips to the next
Bus (the start of the next Bus + district pair, 256 rows): three black
frames with that Bus's card while the ring refills 96 rows per frame,
then flight resumes with the card still up, x and altitude kept, heading
and bank level, autopilot or manual as before (Select does not take
manual control). The PIPELINE burst floods ahead of the camera: pressed
over the channels, the stream and spring channels from 10 rows ahead to
the springs sink to the water line (white water while they sink); pressed
over the lake or on the Bus before it, the stream sections between the
dams and the merge point flood as in M2. A boosts (fog pulls in, the
horizon drops; camera.zig).

Controls (SPEC.md section 3; the last column is what M3 does):

| Input        | Design                                                   | M3                                   |
|--------------|----------------------------------------------------------|--------------------------------------|
| Left / Right | Bank and steer across the strip (roll shears the horizon) | roll, bank-to-turn, x wraps; takes manual control |
| Up / Down    | Pitch: dive / climb (altitude clamped above the terrain)  | horizon 40..88 and cruise altitude; takes manual control |
| A            | Boost while held                                          | 0.75 -> 1.875 cells per frame (2.5x), fog pulls in, horizon drops 8 rows; takes manual control |
| B            | The district verb                                         | Every effect lands in view ahead of the camera (M4.2). HEAP: collect garbage (a press restarts the sweep), SORT: shuffle the band in view, TREE: insert a key (a white leaf beside the flyer), HASH: rehash the table rows in view (one more press queues), STACK: push a frame (again as soon as the previous push has run, 10 frames), PIPELINE: burst the pipe ahead (a press starts a new burst); on a Bus: send a packet (up to 4 in flight); refused only in a segment's last rows; takes manual control |
| Select       | Skip to the next district                                 | on the press: jump to the next Bus (next pair start) with a 3-frame black transition and its card; keeps the autopilot flag |
| Start        | Toggle autopilot / manual flight                          | toggles (on the press); 450 frames (15 s) without input also returns to autopilot |

The autopilot (on at boot) steers toward x = 128 on a Bus and
128 + 16 sin(frame / 512 turn) in a district (straight down the centre
line in the STACK), with the stick clamped to 1/3 so the roll stays
within about 6 rows. It holds `floor` + the live district's altitude
track `alt_at(row)`: a constant for most districts (HEAP 40, SORT 110,
TREE 185, HASH 120), the canyon floor + 14 in the STACK (the dive, with
the terrain clearance scan narrowed to 8 cells around the flight line so
the canyon walls do not hold it up), and 10 over the water across the
PIPELINE lake (18 over the floor after it; the clearance spring lifts it
over dams and springs). It looks down a little in the districts read from
altitude (`alt` 80 or more: SORT, TREE, HASH; horizon row 52) and
presses B when the camera crosses the district's `verb_at` row (HEAP 30,
SORT 60, TREE 60, HASH 40, STACK 20, PIPELINE 70; on each Bus it sends
one packet at local row 24).

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
| `-Dflyover_fps` | `30`, `60` | vsync lock; the cart ships at 30 (decided at M2, SPEC section 10); 60 is for experiments only |
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
  `--frames 2400` (rows 0..1767: one whole cycle Bus, HEAP, Bus, SORT,
  Bus, TREE, Bus, HASH, Bus, STACK, Bus, PIPELINE, then Bus and HEAP), by
  badge-bench and by `tools/check_render.sh`. The STACK is reached about
  frame 1450, the PIPELINE lake about frame 1790.
- `m3_verbs.json` (2600 frames, M3): stick right 60-100 (takes manual
  control), then B at local row ~70 of each district (frames from row =
  0.74 x frame at cruise, checked with `debug_segment_kind`): 184 (HEAP,
  row 134), 367 (the second Bus, row 271: a packet; `debug_bus_packets`
  goes 1 -> 2, the autopilot sent the first on the first Bus), 529 (SORT,
  393), 875 (TREE, 652), 1220 (HASH, 911), 1566 (STACK, 1171), 1912
  (PIPELINE, 1430, over the lake: the M2 flood range, white water from
  about frame 1915); Select at 2141 (the second HEAP, row 1601, local 1:
  jumps to 1792, the Bus before the SORT; black frames 2141-2143, flight
  from 2144); A held 2260-2459 (boost over the SORT and on into the next
  Bus and TREE); Start at 2560 (autopilot back on). The heap reached at
  2141 is the cycle's second: the third (row 3136) is past 2600 frames.
- `m2_verbs.json` (2200 frames): stick right 60-100 (takes manual
  control), then B once in each district: 150 (HEAP, row ~109), 500
  (SORT, ~371), 820 (TREE, ~611), 1160 (HASH, ~866), 1480, 1520 and 1560
  (three STACK pushes, rows ~1106..1166), 1600 (a fourth push, where the
  canyon ahead is already 10 frames deep: the overflow pit and the sky
  flash), 1830 (PIPELINE burst, row ~1369), Start at 2150 (autopilot back
  on). The B presses keep the idle counter from handing back to the
  autopilot in between.
- `m1_manual.json` (1200 frames, kept from M1): stick right 60-120, B at
  200 (HEAP garbage collection), stick left 400-460, B at 600 (SORT
  shuffle; the camera is at row ~439), Start at 900.
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
| `debug_world_check`    | regenerates every row the ring should hold outside the live district and the Bus under the camera (whose ticks edit cells: dataflow, packets) and counts mismatching cells, plus 1000000 per missing row; 0 is correct (mid-skip it counts the rows still to generate) |
| `debug_map_height(x, y)`, `debug_map_colour(x, y)` | one ring cell (two arguments, so not for `--dump-exports`); 0xFFFF if row y is not in the ring |
| `debug_segment_kind`, `debug_segment_index` | segment under the camera: kind 0 Bus, 1 HEAP, 2 SORT, 3 TREE, 4 HASH, 5 STACK, 6 PIPELINE; index = 2 * pair (+1 for the district) |
| `debug_live_kind`      | kind of the live (ticked) district: the one under the camera, or the next one on a Bus |
| `debug_autopilot`      | 1 while the autopilot flies, 0 in manual flight                  |
| `debug_cam_ground`     | terrain height of the cell under the camera                      |
| `debug_cam_clear`      | `debug_cam_alt` - `debug_cam_ground`; above 0 means the camera is above the terrain |
| `debug_sort_state`     | live SORT: running band (255 none) + 256 * sorted bands + 65536 while it re-sorts after B |
| `debug_sort_max_bars`  | most SORT bars (7 rows x 4 cells each) rewritten in one frame since boot: tick alone in the low 16 bits, a frame with a shuffle in the high 16 |
| `debug_water_cols`     | screen columns that ran the reflection pass (render.zig pass 2) last frame; 0 away from water |
| `debug_stack_depth`    | frames pushed in the live STACK this visit (B presses that started a push), 0 when the live district is not the STACK |
| `debug_pipe_state`     | live PIPELINE burst: phase (0 idle, 1 sink, 2 hold, 3 restore) + 256 * frames into the phase; 0 when the live district is not the PIPELINE |
| `debug_verb_max_cells` | most cells (height + colour) one frame of a verb wrote since boot: STACK push waves in the low 16 bits, PIPELINE bursts in the high 16 |
| `debug_sky_flash`      | frames of white sky left (a STACK overflow sets 6)               |
| `debug_skips`          | Select skips since boot                                          |
| `debug_bus_packets`    | Bus packets launched since boot (B on a Bus and the autopilot's one per Bus) |

Checks that hold at M3 (the Select skip, the packet, the burst and the
ring after the skip):

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-flyover.wasm --frames 2600 --quiet \
    --script tools/scripts/m3_verbs.json --out out/ \
    --at "59 debug_autopilot == 1" --at "61 debug_autopilot == 0" \
    --at "366 debug_bus_packets == 1" --at "367 debug_segment_kind == 0" \
    --at "367 debug_bus_packets == 2" --at "1912 debug_segment_kind == 6" \
    --at "1913 debug_pipe_state == 257" --at "2140 debug_segment_kind == 1" \
    --at "2140 debug_skips == 0" --at "2141 debug_cam_y == 1792" \
    --at "2141 debug_skips == 1" --at "2143 debug_cam_y == 1792" \
    --at "2144 debug_world_check == 0" --at "2144 debug_segment_kind == 0" \
    --at "2144 debug_autopilot == 0" --at "2260 debug_segment_kind == 2" \
    --at "2560 debug_autopilot == 1" --at "2599 debug_world_check == 0" \
    --at "2599 debug_cam_clear > 0"
```

Frame 2141 is the press and the first black frame (`debug_cam_y` jumps
from 1601 to 1792, the next pair start); 2144 is the first flown frame
and finds the ring complete. Checks that hold at M2:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-flyover.wasm --frames 2400 --quiet \
    --script tools/scripts/attract.json --out out/ --at "2399 debug_world_check == 0" \
    --at "2399 debug_autopilot == 1" --at "2399 debug_cam_clear > 0" \
    --at "1500 debug_segment_kind == 5" --at "1520 debug_stack_depth == 2" \
    --at "1680 debug_cam_alt < 50" --at "1900 debug_segment_kind == 6" \
    --at "1900 debug_water_cols > 0" --at "2399 debug_cam_y == 1767"
node ../../tools/preview.mjs ../../zig-out/bin/snouty-flyover.wasm --frames 2200 --quiet \
    --script tools/scripts/m2_verbs.json --out out/ \
    --at "59 debug_autopilot == 1" --at "61 debug_autopilot == 0" \
    --at "1480 debug_segment_kind == 5" --at "1561 debug_stack_depth == 3" \
    --at "1600 debug_stack_depth == 4" --at "1600 debug_sky_flash == 5" \
    --at "1830 debug_segment_kind == 6" --at "1831 debug_pipe_state == 257" \
    --at "2150 debug_autopilot == 1" --at "2199 debug_world_check == 0"
```

In the attract run the camera ends at row 1767 (`debug_cam_y`) and
`debug_cam_clear` is above 0 at every frame (lowest 11 cells, frame 1727,
at the STACK exit). The dive (`debug_cam_alt` through the STACK): 116 on
the Bus before it (the plateau is at 110), 109 at local row 29 as the
floor starts stepping down, 65 at row 89, 44 at the 10-frame floor (rows
~140..160, floor at 30), then 50 climbing out at row 194 (the Bus after).
Across the PIPELINE lake it holds 20 (12 over the water) and lifts to
about 45 over the dams and springs.

### Render regression check

`tools/check_render.sh` runs the attract script for 2400 frames and
compares `debug_pixel_checksum` after frames 0, 200, ..., 2200 with the
twelve "T V" lines in `tools/render_hashes.txt` (SPEC 10; the frames are
bit-exact, so any change to the picture shows):

```sh
zig build -Dcart=snouty-flyover            # from the repository root
tools/check_render.sh                      # PASS (12 frames match ...), exit 0; exit 3 on a mismatch
tools/check_render.sh --update             # after an intended change: rewrite render_hashes.txt
tools/check_render.sh path/to/other.wasm   # check a different build
```

## 6. Flashing

Install it as in [docs/INSTALL.md](../../../docs/INSTALL.md): copy
`zig-out/firmware/snouty-flyover.uf2` (repository root) onto the badge's
`SYCLBADGE` drive (not the RP2350 bootloader drive), eject, and pick the
cart in the badge menu. Start+Select returns to the menu.

For on-badge timing flash a `-Ddebug_overlay=true` build, or press the
joystick for the OS FPS overlay.

## 7. Emulated cycle benchmark

badge-bench (`../../badge-bench/README.md`) runs the ELF on an emulated
Cortex-M33 with the badge-calibrated cycle model; read the `busy ms`
column. `../../badge-bench/carts/snouty-flyover.toml` sets the defaults
(budget 22 ms, 2400 frames, `attract.json`). From the repository root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-flyover.elf --script carts/snouty-flyover/tools/scripts/attract.json --frames 2400 --every 60 --symbols
```

The first run creates `badge-bench/.venv` (needs network, under a minute);
the 2400-frame attract run takes about three minutes (M4.1 with the 3D flyer: worst 15.07 ms on a lake frame, mean 8.34). The milestone numbers are in
`PLAN.md` under each milestone's status.
