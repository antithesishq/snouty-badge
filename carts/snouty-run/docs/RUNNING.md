# Running the Snouty badge cart

Commands below run from this cart's directory (`carts/snouty-run/`) unless
noted; `zig build` runs from the repository root, two levels up, and writes its
outputs to `../../zig-out/`.

## 1. Prerequisites

See `../../docs/RUNNING.md` at the repository root (Zig version and download,
Node.js, Python with Pillow for GIF previews).

## 2. Checkout layout

This cart lives in `carts/snouty-run/` of the snouty-badge repository; the
upstream SDK is the `sycl-badge/` submodule at the repository root. See
`../../docs/RUNNING.md` for cloning with the submodule.

Releases of this cart are annotated tags (`git tag -n1`); `git checkout v3.0.0`
builds that release (those tags predate the monorepo and check out the old
single-cart layout, with `../sycl-badge` as a sibling checkout). From the
exe.dev VM the remote is reached through the GitHub integration host
`github.int.exe.xyz`.

## 3. Build

From the repository root:

```sh
zig build -Dcart=snouty-run     # or plain `zig build` for every cart
```

This writes, at the repository root:

- `zig-out/firmware/snouty.uf2` (for the badge)
- `zig-out/firmware/snouty.elf`
- `zig-out/bin/snouty.wasm` (for the simulator)

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd carts/snouty-run                  # from the repository root
node tools/serve-cart.mjs            # serves ../../zig-out/bin/snouty.wasm on :2468
# or: node tools/serve-cart.mjs path/to/other.wasm --port 2468
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
  Z or K (the A button) makes Snouty jump in the simulator as on hardware.
- The WebGL compositor reads red from the bits where the current cart API
  stores blue, so it shows current-API carts with red and blue swapped. Our
  `present_wasm()` pre-swaps when it copies the frame to 0x20, so the browser
  shows the intended colors. If the sky ever looks orange, that swap and the
  simulator have gotten out of step (`sim_swap_rb` in `cart/src/main.zig`).

## 5. Headless preview (no browser)

```sh
node tools/preview.mjs ../../zig-out/bin/snouty.wasm --frames 240 --every 4 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 66
```

The waterfall flips its dither mask every tick, so single frames look like a
checkerboard. To see what the eye sees at 60 Hz, dump every tick and blend:

```sh
node tools/preview.mjs ../../zig-out/bin/snouty.wasm --frames 400 --every 1 --out out/
python3 tools/make_gif.py out/ preview.gif --blend 4 --ms 66
```

`preview.mjs` runs `start()` and then `update()` N times, writing every K-th
frame to `out/frame_XXXX.png` along with `out/frames.json` (metadata:
framebuffer address and source, warnings). Other options:

- `--start-skip S`: skip the first S updates
- `--fb-addr auto|dwarf|sim|0xADDR`: choose which framebuffer to dump
- `--seed N`: seed for `rand()`
- `--press 60-63,140-143`: hold the A button during those update ranges
  (inclusive), e.g. to trigger jumps
- `--raw-colors`: decode colors as the cart API defines them instead of as the
  simulator displays them (only matters for carts that do not pre-swap)

The tool exits non-zero if the cart traps or does not export
`start`/`update`. `make_gif.py` scales frames with nearest-neighbor. One
update is one 60 Hz tick, so `--every 4 --ms 66` plays at about real speed.

## 6. Flash the badge

1. Connect the badge over USB-C. It shows up as a USB mass-storage drive.
2. Copy `zig-out/firmware/snouty.uf2` (at the repository root) onto the drive, replacing `CURRENT.UF2`.
