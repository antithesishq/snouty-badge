# Running the Snouty badge cart

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
  snouty-badge/   this repo
```

## 3. Build

```sh
cd snouty-badge
zig build
```

This writes:

- `zig-out/firmware/snouty.uf2` (for the badge)
- `zig-out/firmware/snouty.elf`
- `zig-out/bin/snouty.wasm` (for the simulator)

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd snouty-badge
node tools/serve-cart.mjs            # serves zig-out/bin/snouty.wasm on :2468
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
- Buttons are written to an address the current cart API no longer reads, so
  input probably does nothing in the simulator. v1 takes no input.
- The WebGL compositor reads red from the bits where the current cart API
  stores blue, so it shows current-API carts with red and blue swapped. Our
  `present_wasm()` pre-swaps when it copies the frame to 0x20, so the browser
  shows the intended colors. If the sky ever looks orange, that swap and the
  simulator have gotten out of step (`sim_swap_rb` in `cart/src/main.zig`).

## 5. Headless preview (no browser)

```sh
node tools/preview.mjs zig-out/bin/snouty.wasm --frames 240 --every 4 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 66
```

`preview.mjs` runs `start()` and then `update()` N times, writing every K-th
frame to `out/frame_XXXX.png` along with `out/frames.json` (metadata:
framebuffer address and source, warnings). Other options:

- `--start-skip S`: skip the first S updates
- `--fb-addr auto|dwarf|sim|0xADDR`: choose which framebuffer to dump
- `--seed N`: seed for `rand()`
- `--raw-colors`: decode colors as the cart API defines them instead of as the
  simulator displays them (only matters for carts that do not pre-swap)

The tool exits non-zero if the cart traps or does not export
`start`/`update`. `make_gif.py` scales frames with nearest-neighbor. One
update is one 60 Hz tick, so `--every 4 --ms 66` plays at about real speed.

## 6. Flash the badge

1. Connect the badge over USB-C. It shows up as a USB mass-storage drive.
2. Copy `zig-out/firmware/snouty.uf2` onto the drive, replacing `CURRENT.UF2`.
