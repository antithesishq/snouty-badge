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

The cart lives in `carts/snouty-reflections/` of the snouty-badge repository.
Commands below run from that directory unless noted; only `zig build` runs
from the repository root (`../..`), and its outputs are in the root
`zig-out/` (`../../zig-out/...` from here).

## 1. Prerequisites

Zig, Node.js, Python with Pillow and git: see `../../docs/RUNNING.md` at the
repository root. This cart also needs:

- numpy (for `tools/reference.py`)
- For the emulated cycle benchmark (`tools/emu/`, section 8): Python 3.9 or newer
  with the `venv` module (Debian/Ubuntu: `apt install python3-venv`); it
  installs its own packages, numpy included, into `tools/emu/.venv`

## 2. Checkout layout

Cloning the repository with its `sycl-badge/` submodule is described in
`../../docs/RUNNING.md` at the repository root.

Milestones are annotated tags (`git tag -n1 'snouty-reflections/*'`:
`snouty-reflections/m0`, `/m1`, `/m1.1`). From the exe.dev VM the remote is reached through the GitHub
integration host `github.int.exe.xyz`.

## 3. Build

From the repository root:

```sh
zig build -Dcart=snouty-reflections   # only this cart; plain `zig build` builds every cart
```

`-Ddebug_overlay=true` draws the render time (`render_us`) and frame counter
over the picture; use it on the badge to read the M1 timing:

```sh
zig build -Dcart=snouty-reflections -Ddebug_overlay=true
```

A clean build of this cart takes about 2 minutes (all carts: several). This
writes, in the root `zig-out/`:

- `zig-out/firmware/snouty-reflections.uf2` (for the badge)
- `zig-out/firmware/snouty-reflections.elf`
- `zig-out/bin/snouty-reflections.wasm` (for the simulator)

`zig build check-float` (also from the root) runs the shared
`tools/check_float.mjs` (at the repository root) on the ELF.

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd carts/snouty-reflections
node ../../tools/serve-cart.mjs   # serves ../../zig-out/bin/snouty-reflections.wasm on :2468
# or: node ../../tools/serve-cart.mjs path/to/other.wasm --port 2468
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
  X or J (the B button) switches the dither mode in the simulator as on
  hardware.
- The WebGL compositor reads red from the bits where the current cart API
  stores blue, so it shows current-API carts with red and blue swapped. Our
  `present_wasm()` pre-swaps when it copies the frame to 0x20, so the browser
  shows the intended colors. If the sunset sky ever looks blue, that swap and the
  simulator have gotten out of step (`sim_swap_rb` in `cart/src/main.zig`).

## 5. Headless preview (no browser)

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-reflections.wasm --frames 600 --every 6 --out out/
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 50
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
exactly" plus "The M2 scene, exactly": chrome and glass spheres, the
textured shore at z = 14, water with sphere shadows and scatter) with numpy
in float64 and quantises it like dither mode `none`; `tools/check_render.mjs`
compares a cart frame against it in RGB565 units. Frame F of the reference
is the same camera angle and water time as `frame_F.png` from `preview.mjs`.
The shore texture and palette are read at run time from
`cart/src/shore_texels.bin` and `tools/shore_palette.json`, so regenerating
the art (`tools/gen_shore.py`) needs no change to the reference.

The M2 check frames are 0, 150, 300 and 450, plus the badge-bench worst
frame, all in dither mode `none`:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-reflections.wasm --frames 451 --every 150 \
    --script tools/scripts/m1_nodither.json \
    --dump-exports debug_dither_mode --expect "debug_dither_mode == 1" --out out/
python3 tools/reference.py --frame 0 --frame 150 --frame 300 --frame 450 --out out/
for f in 0000 0150 0300 0450; do
    node tools/check_render.mjs out/frame_$f.png out/ref_$f.png --diff out/diff_$f.png
done
```

For the bench's worst frame W, render just that frame with
`--frames W+1 --every W` (for example `--frames 558 --every 557` writes
`frame_0000.png` and `frame_0557.png`) and `reference.py --frame W`.
`tools/scripts/m1_nodither.json` presses B on tick 0, so every frame after
it renders in mode `none`; the `--expect` confirms the press landed (the
tolerance alone would not show it).

**Knobs.** The reference takes the cart's `// M2 knobs` (in
`cart/src/scene.zig`) as flags; run it with the settings the cart ships, or
the check compares different scenes:

| Flag | Values (default first) | Meaning |
|------|------------------------|---------|
| `--glass` | `real`, `fake` | knob 1: exit-point refraction, or one refraction traced from the entry point |
| `--water-shadows` | `all`, `primary_only`, `off` | knob 2: which water hits get sphere shadows |
| `--glass-secondary` | `full`, `env` | knob 3: glass at depth 1 traces its two rays, or looks them up in `env()` (shore or sky) |
| `--fade-k` | `0.05` | ripple fade, `g = 1 / (1 + fade_k * dist)`, `fade = g * g` |

For example `python3 tools/reference.py --frame 300 --out out/ --glass fake
--water-shadows primary_only`. `--texels FILE` and `--palette FILE` override
the shore data; `--dump-npy` also saves the float image before quantisation
(`out/ref_FFFF.npy`, 128x160x3) for debugging. One 160x128 frame takes
under a second.

**The rule.** A pixel's difference is its largest per-channel difference in
5/6/5 units. PASS if at most 1% of pixels (204 of 20480) differ by more
than 1 unit **and** at most 0.25% (51) differ by more than 6 units. The
second count is an outlier allowance for nearest-texel shore edges, the
shadow edge and grazing glass silhouettes, where the cart's f32 and the
reference's f64 legitimately land on different sides. `check_render.mjs`
prints both counts (marked `OVER` when above the limit) and the largest
difference with its position and both pixel values, and exits 0 on PASS, 3
on FAIL, 2 on a usage error.

`--diff out/diff_FFFF.png` writes the outlier map: the cart frame dimmed to
30%, pixels off by 2 to 6 units in yellow and pixels off by more than 6
units in magenta. Outliers that trace an edge (shore texels, the shadow
rim, the glass silhouette) are precision; a filled region means the two
implementations disagree about the scene. `--amp out/amp_FFFF.png` writes
the older amplified difference image (40 levels per unit per channel).

## 7. Flashing

1. Put the badge in bootloader mode and connect it over USB-C. It shows up
   as a USB mass-storage drive.
2. Copy `zig-out/firmware/snouty-reflections.uf2` (repository root) onto the drive.
3. The cart lives alongside the other carts in the badge menu; pick it
   there. Start+Select returns to the menu.

To read the M1 timing, flash a `zig build -Dcart=snouty-reflections -Ddebug_overlay=true` build (render
time drawn on screen) or press the joystick to show the OS FPS overlay.

## 8. Emulated cycle benchmark

`tools/emu/` runs the tracer on an emulated Cortex-M33 (unicorn), counts
every executed instruction and prices it with a simple M33 cycle model, so
a change can be costed in seconds without a badge. It is a model: treat the
milliseconds as a lower bound and confirm on hardware with the debug
overlay. `tools/emu/README.md` has the model, its blind spots and how to
read the tables.

Needs `zig`, `node` and `python3` (3.9+, with `venv`) on `PATH`, for
example `export PATH="$HOME/.local/bin:$PATH"`. The first run creates
`tools/emu/.venv` and pip-installs `tools/emu/requirements.txt` (unicorn,
capstone, pyelftools, numpy; needs network, under a minute), later runs
skip that step.

```sh
tools/emu/run.sh                              # bench ELF, frames 0 and 300 (~10 s)
tools/emu/run.sh --sweep                      # plus the orbit, frames 0..575 step 25 (~35 s)
(cd ../.. && zig build -Dcart=snouty-reflections) && tools/emu/run.sh --real --sweep --listing   # plus the flashed ELF and listings (~1 min)
```

The default run rebuilds `tools/emu/build/bench.elf` from `cart/src`,
emulates frames 0 and 300 in dither mode `none`, checks them against
`tools/reference.py` with `tools/check_render.mjs`, and prints a summary
table (instructions and modelled cycles per frame, cycles per pixel, ms at
150 MHz, uncapped fps) and the cost per ray-path class. `--real` also runs
`../../zig-out/firmware/snouty-reflections.elf` from `_start` with a faked OS
(run `zig build` at the repository root first). `--sweep` adds the whole orbit and prints the
min, max and worst frame. `--listing` writes annotated disassembly to
`tools/emu/out/`. All outputs, including `summary.txt`, land in
`tools/emu/out/`.

A good run ends with every check `PASS` and exit status 0:

```
emu: reference check
  emu 0000: PASS  (max difference: 2 units in g at (91, 89); ...)
  emu 0300: PASS  (max difference: 3 units in g at (66, 96); ...)
...
summary (modelled Cortex-M33 cycles; fps is uncapped, the cart locks to 20):
  run   frame  insns/frame  cycles/frame  cyc/px ms@150MHz    fps vdiv/px vsqrt/px  check
  emu       0    5,365,617     7,295,583   356.2     48.64   20.6    2.53     1.29  PASS
  emu     300    5,169,143     7,079,328   345.7     47.20   21.2    2.54     1.29  PASS
```

(those are the m1 numbers). A frame 0 or 300 FAIL exits 3. In the sweep a
FAIL is informational: a grazing sphere-edge pixel can exceed the 6-unit
cap on precision alone, so look at `tools/emu/out/sweep/diff_*.png` before
deciding.
