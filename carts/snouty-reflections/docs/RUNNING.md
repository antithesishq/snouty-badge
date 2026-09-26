# Running the Snouty on the Water cart

Snouty on the Water (`snouty-reflections`) is a SYCL Badge V2 cart: a
real-time ray tracer demo. A chrome sphere sits on a rippling lake at sunset
while the camera orbits it (one revolution every 30 s); every pixel is a
traced ray, quantised to RGB565 through a temporal Bayer dither. The cart is
locked to 20 fps (`cart.set_vsync_enabled(1000.0 / 20.0)`), so one `update()`
is one frame and the scene animates by frame count, not wall time.

Controls (M1): B cycles the dither mode (`bayer_temporal`, `none`). Start+Select
returns to the badge menu and the joystick click toggles the OS FPS overlay;
both belong to the OS.

## 1. Prerequisites

- git
- Zig **0.17.0-dev.1936+5a625d5f3** exactly (upstream sycl-badge pins it). Nightly
  tarballs are named `zig-<arch>-<os>-<version>.tar.xz`; the Linux x86_64 one is
  <https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1936+5a625d5f3.tar.xz>.
  Nightlies rotate off ziglang.org; if the URL 404s, try the machengine.org
  mirror or `zigup`. Unpack it and put the `zig` binary on `PATH`.
- Node.js 20 or newer (for the simulator and the tools in `tools/`)
- Python 3 with numpy (for `tools/reference.py`) and Pillow (for GIF previews)

## 2. Checkout layout

The two repos must be siblings. `build.zig.zon` points at `../sycl-badge`,
and `src/os/system/tracy_protocol.zig` is a symlink into it.

```
work/
  sycl-badge/     git clone https://github.com/ZigEmbeddedGroup/sycl-badge.git
  snouty-reflections/   git clone git@github.com:antithesishq/snouty-reflections.git
```

Milestones are annotated tags (`git tag -n1`). From the exe.dev VM the remote is reached through the GitHub
integration host `github.int.exe.xyz`.

## 3. Build

```sh
cd snouty-reflections
zig build
```

`-Ddebug_overlay=true` draws the render time (`render_us`) and frame counter
over the picture; use it on the badge to read the M1 timing:

```sh
zig build -Ddebug_overlay=true
```

A clean build takes about 2 minutes. This writes:

- `zig-out/firmware/snouty-reflections.uf2` (for the badge)
- `zig-out/firmware/snouty-reflections.elf`
- `zig-out/bin/snouty-reflections.wasm` (for the simulator)

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd snouty-reflections
node tools/serve-cart.mjs zig-out/bin/snouty-reflections.wasm   # serves it on :2468
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

Then open <http://localhost:1234>. Pass the wasm path explicitly: the
script's built-in default still names the snouty-bugs file.

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
  X or J (the B button) switches the dither mode in the simulator as on
  hardware.
- The WebGL compositor reads red from the bits where the current cart API
  stores blue, so it shows current-API carts with red and blue swapped. Our
  `present_wasm()` pre-swaps when it copies the frame to 0x20, so the browser
  shows the intended colors. If the sunset sky ever looks blue, that swap and the
  simulator have gotten out of step (`sim_swap_rb` in `cart/src/main.zig`).

## 5. Headless preview (no browser)

```sh
node tools/preview.mjs zig-out/bin/snouty-reflections.wasm --frames 600 --every 6 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 50
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
- `--dump-exports debug_frame,debug_dither_mode`: after the last update, call these
  zero-argument exports and record the results (as i32) in `frames.json`
  under `exports` and on stderr
- `--expect "debug_dither_mode == 1"` (repeatable; `== != < <= > >=`, integer value):
  checked against those exports at the end (the name is dumped
  automatically); prints PASS/FAIL, and any failure exits 3
- `--quiet`: write no PNGs, only `frames.json` (fast soak runs)
- `--raw-colors`: decode colors as the cart API defines them instead of as the
  simulator displays them (only matters for carts that do not pre-swap)

Debug exports (zero-argument wasm functions, usable with `--dump-exports`
and `--expect`):

| Export                 | Meaning                                                          |
|------------------------|------------------------------------------------------------------|
| `debug_frame`          | frame counter (number of `update()` calls so far)                |
| `debug_render_us`      | render time of the last frame in microseconds; always 0 in wasm (no timer), real on the badge |
| `debug_pixel_checksum` | sum of all framebuffer words, for render regression tests        |
| `debug_dither_mode`    | 0 `bayer_temporal` (default), 1 `none`                           |

Input scripts live in `tools/scripts/`: `m1_nodither.json` presses B on tick 0,
so every frame renders in dither mode `none` (used by the reference check).

An unknown or non-zero-argument export name is an error that lists the
exports the cart has. Exit codes: 1 the cart cannot be loaded or does not
export `start`/`update`, 2 usage or script error, 3 the cart trapped or an
expectation failed. `make_gif.py` scales frames with nearest-neighbor. One
update is one 20 fps frame, so `--every 1 --ms 50` is real speed; the
`--every 6 --ms 50` GIF above is one full orbit at 6x speed. The frame
index in `frame_XXXX.png` is the 0-based update index, which is also the
value of the cart's frame counter while that frame was rendered.

## 6. Reference check

`tools/reference.py` renders the scene defined in `PLAN.md` ("The M1 scene,
exactly") with numpy in float64 and quantises it like dither mode `none`;
`tools/check_render.mjs` compares a cart frame against it in RGB565 units.
It passes when at most 1% of pixels differ by more than 1 unit in any
channel and no pixel differs by more than 6 units. Frame F of the reference
is the same camera angle and water time as `frame_F.png` from `preview.mjs`.

```sh
node tools/preview.mjs zig-out/bin/snouty-reflections.wasm --frames 301 --every 300 --script tools/scripts/m1_nodither.json --out out/
python3 tools/reference.py --frame 0 --frame 300 --out out/
node tools/check_render.mjs out/frame_0000.png out/ref_0000.png
node tools/check_render.mjs out/frame_0300.png out/ref_0300.png
```

`check_render.mjs` prints the number of differing pixels, the largest
difference and where it is, and exits 0 on PASS, 3 on FAIL, 2 on a usage
error. `--diff out/diff_0000.png` writes an amplified difference image
(40 levels per unit). `reference.py --dump-npy` also saves the float image
before quantisation (`out/ref_FFFF.npy`, 128x160x3) for debugging.

The tolerance is loose enough that a dithered frame also passes (the Bayer
dither adds at most one unit), so the check does not prove the B press
landed. To make sure, add
`--dump-exports debug_dither_mode --expect "debug_dither_mode == 1"` to the
`preview.mjs` command.

## 7. Flashing

1. Put the badge in bootloader mode and connect it over USB-C. It shows up
   as a USB mass-storage drive.
2. Copy `zig-out/firmware/snouty-reflections.uf2` onto the drive.
3. The cart lives alongside the other carts in the badge menu; pick it
   there. Start+Select returns to the menu.

To read the M1 timing, flash a `zig build -Ddebug_overlay=true` build (render
time drawn on screen) or press the joystick to show the OS FPS overlay.
