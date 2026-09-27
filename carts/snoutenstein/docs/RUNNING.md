# Running the Snoutenstein 3D cart

## 1. Prerequisites

- git
- Zig **0.17.0-dev.1936+5a625d5f3** exactly (upstream sycl-badge pins it). Nightly
  tarballs are named `zig-<arch>-<os>-<version>.tar.xz`; the Linux x86_64 one is
  <https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1936+5a625d5f3.tar.xz>.
  Nightlies rotate off ziglang.org; if the URL 404s, try the machengine.org
  mirror or `zigup`. Unpack it and put the `zig` binary on `PATH`.
- Node.js 20 or newer (for the simulator and the tools in `tools/`)
- Optional, for GIF previews: Python 3 with Pillow

## 2. Checkout layout

The two repos must be siblings. `build.zig.zon` points at `../sycl-badge`, and
`src/os/system/tracy_protocol.zig` is a symlink into it.

```
work/
  sycl-badge/     git clone https://github.com/ZigEmbeddedGroup/sycl-badge.git
  snoutenstein/   git clone git@github.com:antithesishq/snoutenstein.git
```

Milestones are annotated tags (`git tag -n1`).
integration host `github.int.exe.xyz`.

## 3. Build

```sh
cd snoutenstein
zig build
```

This writes:

- `zig-out/firmware/snoutenstein.uf2` (for the badge)
- `zig-out/firmware/snoutenstein.elf`
- `zig-out/bin/snoutenstein.wasm` (for the simulator)

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd snoutenstein
node tools/serve-cart.mjs            # serves zig-out/bin/snoutenstein.wasm on :2468
# or: node tools/serve-cart.mjs path/to/other.wasm --port 2468
```

This serves `http://localhost:2468/cart.wasm` (with CORS) and
`ws://localhost:2468/ws`. When the file changes, which happens after every
`zig build`, it sends `reload` to the page.

Terminal 2 runs the simulator UI:

```sh
cd ../sycl-badge/simulator
npm install
npm run dev
```

Then open <http://localhost:1234>.

Hosted alternative: <https://badgesim.microzig.tech/> also fetches from
`localhost:2468`, so it should work with the watcher from terminal 1 (Chrome
treats `localhost` as secure). This has not been verified; if it doesn't
load, use the local UI.

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

Known upstream simulator quirks (current sycl-badge `main`):

- The simulator only shows a fixed region of wasm memory (address 0x20). The
  cart API draws somewhere else, so our cart copies each frame to 0x20 itself
  (`present_wasm()` in `cart/src/main.zig`). Upstream demo carts such as
  `dvd.wasm` show a blank or garbage screen.
- Buttons are written to an address (0x04) the current cart API no longer
  reads, so upstream carts get no input in the simulator. Our cart reads that
  address itself in wasm builds (`read_controls()` in `cart/src/main.zig`), so
  Z or K (the A button) fires in the simulator as on hardware.
- The WebGL compositor reads red from the bits where the current cart API
  stores blue, so it shows current-API carts with red and blue swapped. Our
  `present_wasm()` pre-swaps when it copies the frame to 0x20, so the browser
  shows the intended colors. If the Coral title text ever looks blue, that swap and the
  simulator have gotten out of step (`sim_swap_rb` in `cart/src/main.zig`).

## 5. Headless preview (no browser)

```sh
node tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 240 --every 4 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 66
```

`preview.mjs` runs `start()` and then `update()` N times, writing every K-th
frame to `out/frame_XXXX.png` along with `out/frames.json` (metadata:
framebuffer address and source, inputs, export values, expectation results,
warnings). Other options:

- `--start-skip S`: skip the first S updates
- `--fb-addr auto|dwarf|sim|0xADDR`: choose which framebuffer to dump
- `--seed N`: seed for `rand()`
- `--controls BITS`: raw `cart.Controls` bits held for the whole run
- `--press A:30-31,UP:60-99,START:300-301`: hold buttons during those update
  ranges (inclusive). Buttons are `A B START SELECT UP DOWN LEFT RIGHT`, any
  case; a bare `60-63` means A. `CLICK` is refused (the OS owns it).
- `--script FILE.json`: a JSON array of
  `{ "from": 60, "to": 99, "hold": ["A", "UP"] }` entries, inclusive. Inputs
  from `--controls`, `--press` and `--script` are OR-ed per tick.
- `--dump-exports debug_state,debug_score`: after the last update, call these
  zero-argument exports and record the results (as i32) in `frames.json`
  under `exports` and on stderr
- `--expect "debug_score > 0"` (repeatable; `== != < <= > >=`, integer value):
  checked against those exports at the end (the name is dumped
  automatically); prints PASS/FAIL, and any failure exits 3
- `--quiet`: write no PNGs, only `frames.json` (fast soak runs)
- `--raw-colors`: decode colors as the cart API defines them instead of as the
  simulator displays them (only matters for carts that do not pre-swap)

Input scripts live in `tools/scripts/` (A at tick 10 leaves the title
screen; turns are 36 ticks = 90 degrees, walking 0.045 cells per tick):

- `m1_walk.json` (2,151 ticks, run 2,160 frames): through the plain door
  (7,4), up the x 8 corridor, east along row 1, down x 16, west along
  row 8, down x 1, then stands 60 ticks at (1.5, 22.5) facing east down
  the long bottom corridor (the render-time gate view), walks 18 cells of
  it, turns around and walks back. `debug_px > 393216` already holds from
  tick 250 on; at 2,160 frames expect px about 14.3 cells, py about 22.6.
- `m1_doors.json` (600 frames): lines up with the door row, walks into the
  closed door at (7,4), stands 40 ticks while it opens, walks through to
  (8.5, 4.5), turns around, waits 200 ticks for it to close, bumps it once
  from the corridor side and watches it reopen. Ends at px 8.25 (540672).
- `m1_pause.json` (600 frames): walks 30 ticks, START at 41, holds UP for 60
  paused ticks (nothing may move), START at 102, walks and turns again.
  Ends playing at px about 6.2; without a working pause the wall would stop
  it at 6.75, so `--expect "debug_px < 425984"` checks the pause.
- `m2_combat.json` (240 frames): from the start, holds A at 30..45 so the
  zapper fires twice (cooldown 12): the first shot kills the gnat three
  cells ahead, the second hits nothing. SELECT at 90 skips the empty spray
  and lands on the swatter, A at 110..125 swings it at nothing, SELECT at
  150 goes back to the zapper, then a short walk. Expect `debug_kills == 1`,
  `debug_weapon == 1`, `debug_ammo == 38`.
- `m2_exit.json` (1,400 frames): lines up with the door row, through the
  plain door (7,4), up the x 8 corridor, east along row 1 to x 31, south
  into the exit door at (31,8). The level ends, the intermission card shows
  for 60 ticks, A at 1300 starts level 1 (E1M1). Expect `debug_level == 1`
  and `debug_mode == 1`.

```sh
node tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 2160 --every 6 --out out/walk \
  --script tools/scripts/m1_walk.json \
  --dump-exports debug_mode,debug_tick,debug_px,debug_py,debug_render_us \
  --expect "debug_mode == 1" --expect "debug_px > 393216"
node tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 600 --quiet --out out/pause \
  --script tools/scripts/m1_pause.json --expect "debug_mode == 1" --expect "debug_px < 425984"
```

An unknown or non-zero-argument export name is an error that lists the
exports the cart has. Exit codes: 1 the cart cannot be loaded or does not
export `start`/`update`, 2 usage or script error, 3 the cart trapped or an
expectation failed. `make_gif.py` scales frames with nearest-neighbor. One
update is one 60 Hz tick, so `--every 4 --ms 66` plays at about real speed.

## 6. Flash the badge

1. Connect the badge over USB-C. It shows up as a USB mass-storage drive.
2. Copy `zig-out/firmware/snoutenstein.uf2` onto the drive, replacing `CURRENT.UF2`.
