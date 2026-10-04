# Running the Snouty on the Water cart

Snouty on the Water (`snouty-reflections`) is a SYCL Badge V2 cart: a
real-time ray tracer demo. Chrome spheres float on a rippling lake while the
camera orbits them (one revolution every 30 s); every pixel is a traced ray,
quantised to RGB565 through a dither. Four scene presets (sunset, midnight,
noon, storm) cycle in attract mode with a fade; the spheres bob and ring the
water and the sun drifts (M3). The
cart is locked to its variant's frame rate (20 fps for the shipped `cut20`,
`cart.set_vsync_enabled(1000.0 / 20.0)`), so one `update()` is one frame
and the scene animates by frame count, not wall time. Background music
(Satie's Gymnopedie No. 1 as a chiptune, SPEC.md section 8) boots off;
Start in the attract orbit toggles it ("MUSIC ON" / "MUSIC OFF" bottom
left), `-Dsound=true` builds it on. The simulator plays the melody and
bass only.

Controls (SPEC.md section 3, M3):

| Input          | Attract (default)                 | Free camera                          | Frozen                                       |
|----------------|-----------------------------------|--------------------------------------|----------------------------------------------|
| Left / Right   | Enter free camera; orbit          | Orbit around the spheres             | Orbit the frozen view                        |
| Up / Down      | Enter free camera; raise / lower  | Camera height 1.0 to 1.8 m           | Height                                       |
| A              | Freeze                            | Freeze                               | Unfreeze: time resumes where it stopped      |
| B              | Cycle dither mode                 | Cycle dither mode                    | Cycle dither mode                            |
| Select         | Next scene preset                 | Next scene preset                    | Next preset                                  |
| Start          | Music on/off                      | Return to attract orbit              | Unfreeze and return to attract orbit         |

Free camera orbits at 36 deg/s (3 orbit steps per frame at 20 fps) and
moves the height by 0.05 m per frame; it returns to attract by itself after
20 s without input, keeping the angle, and the height eases back to 1.6 m.
Freezing (A) stops time and, since M4, hands the screen to a progressive
path tracer (SPEC.md section 5b, section 11 below): the picture starts as
the real-time frame and converges over seconds, adding anti-aliasing,
soft shadows, the glass sphere, glossy water and depth of field; A again
resumes time where it stopped. A converged frozen image returns to
attract by itself after 60 s without input. Attract
switches to the next preset every orbit (30 s) with a 0.5 s fade out and in;
the cycle pauses while frozen or in free camera. Dither modes, in B order:
`bayer_temporal` (default), `blue_noise`, `palette16` (16 colours, the Amiga
look), `none`. Start+Select returns to the badge menu and the joystick click
toggles the OS FPS overlay; both belong to the OS.

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
| `debug_dither_mode`    | 0 `bayer_temporal` (default), 1 `none`, 2 `blue_noise`, 3 `palette16` (M3) |
| `debug_preset`         | M3: 0 sunset, 1 midnight, 2 noon, 3 storm                        |
| `debug_state`          | M3: 0 attract, 1 free camera, 2 frozen                           |

Two M3 exports take arguments, so `preview.mjs` cannot call them (its
`--call` passes at most one integer); `tools/check_render.mjs` loads the
cart itself to use them:

| Export                                         | Meaning |
|------------------------------------------------|---------|
| `debug_set_view(preset, t, orbit, height_mm)`  | freeze and set the view: preset 0..3, scene time `t` in frames, orbit index `[0, orbit_frames)`, eye height in mm (1000..1800; 1600 is the default) |
| `debug_set_dither_mode(mode)`                  | set the dither mode directly (numbers as `debug_dither_mode`) |

Input scripts live in `tools/scripts/` (`--script`):

| Script              | What it does |
|---------------------|--------------|
| `m1_nodither.json`  | B on tick 0: dither `none` on the pre-M3 cart (two modes). On an M3 cart one B press gives `blue_noise` |
| `m3_nodither.json`  | B on ticks 0, 2, 4: dither `none` on an M3 cart (bayer -> blue_noise -> palette16 -> none) |
| `blue_noise.json`   | B on tick 0: `blue_noise` on an M3 cart |
| `palette16.json`    | B on ticks 0 and 2: `palette16` on an M3 cart |
| `presets.json`      | Select on ticks 150, 300, 450: all four presets in one orbit (the scene time keeps running) |
| `free_camera.json`  | Right for 200 ticks, Up 40, Left 200, Down 40 (free camera, height 1.6 -> 3.0 -> 1.0), A at 500 and 560 (freeze, unfreeze), Start at 600 (back to attract) |

For example, a free-camera GIF:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-reflections.wasm --frames 660 --every 3 \
    --script tools/scripts/free_camera.json --out out/free/
python3 ../../tools/make_gif.py out/free/ free.gif --scale 3 --ms 150
```

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
exactly", "The M2 scene, exactly", M2.2 "The scene changes, exactly" and M3
"The M3 scene, exactly": chrome, glass, matte and small chrome spheres, the
textured shore at z = 14, the Iris logo, water with ripples, rings, sphere
shadows and scatter, four presets) with numpy in float64 and quantises it
like dither mode `none`; `tools/check_render.mjs` compares a cart frame
against it in RGB565 units. The shore texture and palette are read at run
time from `cart/src/shore_texels.bin` and `tools/shore_palette.json`, so
regenerating the art (`tools/gen_shore.py`) needs no change to the
reference.

**Views.** A view is what the cart's `trace.View` holds: the preset, the
scene time `t` in frames (water, logo spin, bob, sun drift), the
camera's orbit index and the eye height. The reference renders views three
ways:

| Flag | Output | View |
|------|--------|------|
| `--frame F` (repeatable) | `ref_FFFF.png` | `--preset`, `t = F`, `orbit = F mod orbit_frames`, `--height` |
| `--t T [--orbit O] [--name N]` | `ref_<name>.png` | `--preset`, `t = T`, `orbit = O` (default `T`), `--height` |
| `--view P:T[:O[:H]]` (repeatable) | `ref_<name>.png` | preset `P`, `t = T`, `orbit = O` (default `T`), height `H` m (default 1.6) |

with `<name>` = `<preset>_t<TTTT>_o<OOOO>_h<mm>`, for example
`ref_storm_t0300_o0300_h1800.png`. `--preset` is `sunset` (default),
`midnight`, `noon`, `storm` or 0..3; `--height` is 1.0 to 1.8 m (default
1.6). A height other than 1.6 is rounded to f32 and the camera basis is
computed in f32, as the cart does at run time; everything else is f64.

**Motion.** `--motion 1` (the default) is the M3 cart: spheres bob, the sun
drifts and rings spread on the water under each sphere (`--stripes 1`
still draws M3's chrome stripes, which the cart dropped on 2026-09-30).
`--motion 0` turns all of it off; with `--motion 0`, `--preset
sunset` and the default height the output is byte-identical to the M2.2
reference, frame for frame (the legacy identity). The M3 knobs:

| Flag | Values (default first) | Meaning |
|------|------------------------|---------|
| `--motion` | `1`, `0` | master switch for bob, drift, rings, stripes |
| `--rings` | `1`, `0` | rings on the water (with `--motion 1`) |
| `--stripes` | `0`, `1` | M3's stripes on the chrome sphere (with `--motion 1`); dropped from the cart 2026-09-30, so off by default |
| `--sun-drift` | `1`, `0` | the sun rotates about +y by 8 deg * sin(s / 60 turns) (with `--motion 1`) |
| `--noon-shadows` | `1`, `0` | noon shadows the primary water hits |
| `--noon-third-sphere` | `1`, `0` | noon has the small chrome sphere |

```sh
python3 tools/reference.py --variant cut20 --preset noon --t 150 --out out/            # out/ref_noon_t0150_o0150_h1600.png
python3 tools/reference.py --variant cut20 --view storm:300:300:3.0 --view sunset:0 --out out/
python3 tools/reference.py --variant cut20 --frame 300 --motion 0 --out out/           # M2.2 frame 300
```

**The check, M3 cart.** When the wasm exports `debug_set_view` and
`debug_set_dither_mode`, `check_render.mjs --variant` loads the cart
in-process: per view it sets dither `none` and the view, runs two updates
(the frames must be identical: the view is frozen), checks `debug_preset`
and `debug_state == 2`, and compares the frame against `reference.py
--view`. With no other flags it runs the M3 check set: each preset at `t` =
0, 150, 300, 450 (orbit = t) and sunset and storm at heights 1.0 and 3.0 at
`t` = 0 and 300, 24 views:

```sh
node tools/check_render.mjs --variant cut20                         # the M3 check set, dist/variants/cut20.wasm
node tools/check_render.mjs --variant half30 --wasm ../../zig-out/bin/snouty-reflections.wasm
node tools/check_render.mjs --variant cut20 --only --frame 393 --preset noon --preset storm --height 2.2
node tools/check_render.mjs --variant cut20 --only --t 100 --orbit 450 --view midnight:37:12:1.35
```

`--frame F` and `--t T [--orbit O]` add a view per `--preset` (default
sunset) and per `--height` (default 1.6); `--view` adds one view; `--only`
drops the check set. Files land in `--out` (default `out/check_<variant>`):
`cart_<name>.png`, `ref_<name>.png` and `diff_<name>.png`. `--motion 0`
checks a motion-off build (it is passed to the reference), and `--ref-arg
ARG` passes any other reference flag, for a cart built with a knob turned.

**The check, pre-M3 cart.** A wasm without those exports (the m2.2 builds)
takes the legacy path: `preview.mjs` steps frames 0, 1/4, 1/2 and 3/4 of the
orbit plus every `--frame` with B on tick 0 (`m1_nodither.json`) and the
reference renders them with `--motion 0`. `--preset`, `--height`,
`--orbit` and `--view` are refused there. By hand, the same comparison is:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-reflections.wasm --frames 451 --every 150 \
    --script tools/scripts/m1_nodither.json \
    --dump-exports debug_dither_mode --expect "debug_dither_mode == 1" --out out/
python3 tools/reference.py --frame 0 --frame 150 --frame 300 --frame 450 --motion 0 --out out/
for f in 0000 0150 0300 0450; do
    node tools/check_render.mjs out/frame_$f.png out/ref_$f.png --diff out/diff_$f.png
done
```

For the bench's worst frame W, render just that frame with
`--frames W+1 --every W` (for example `--frames 558 --every 557` writes
`frame_0000.png` and `frame_0557.png`) and `reference.py --frame W`.

**Legacy identity** (PLAN.md M3 "Fixed interfaces"). A build with the
motion knob off must render the sunset view of frame F bit for bit as the
m2.2 cart renders frame F. `--identity` compares `debug_pixel_checksum`
(and the frame) of the two wasms at frames 0 to 600 step 50, dither `none`:

```sh
node tools/check_render.mjs --identity --variant cut20 --wasm motion_off.wasm --baseline m2.2/cut20.wasm
node tools/check_render.mjs --identity --variant half30 --wasm motion_off.wasm --baseline m2.2/half30.wasm \
    --from 0 --to 900 --step 25
```

The baseline is stepped update by update (B on tick 0). The new wasm gets
`debug_set_view(0, F, F mod orbit_frames, 1600)` per frame when it has the
export, otherwise it is stepped the same way. `--dither bayer` leaves both
in the default dither instead (that also needs the new cart to feed the
dither the same frame parity). A mismatch writes `identity_new_FFFF.png`
and `identity_base_FFFF.png` to `--out` (default `out/identity`) and exits 3.

**Knobs.** The reference takes the cart's `// M2 knobs` (in
`cart/src/scene.zig`) as flags; run it with the settings the cart ships, or
the check compares different scenes:

| Flag | Values (default first) | Meaning |
|------|------------------------|---------|
| `--glass` | `real`, `fake` | knob 1: exit-point refraction, or one refraction traced from the entry point |
| `--water-shadows` | `all`, `primary_only`, `off` | knob 2: which water hits get sphere shadows |
| `--glass-secondary` | `full`, `env` | knob 3: glass at depth 1 traces its two rays, or looks them up in `env()` (shore or sky) |
| `--glass-primary` | `full`, `env` | knob 4: glass seen by primary rays looks its rays up in `env_flat` |
| `--iris-in-chrome` | `1`, `0` | knob 5: chrome reflections (both chrome spheres) show the Iris logo |
| `--iris-in-water` | `1`, `0` | knob 6: water reflections show the logo |
| `--iris-samples` | `4` | knob 7: mask samples along the slab chord (minimum 2) |
| `--no-iris` | | no logo |
| `--fade-k` | `0.05` | ripple fade, `g = 1 / (1 + fade_k * dist)`, `fade = g * g` |

`--variant full20|cut20|full15|half30` sets the variant's flags (M2.1:
`--fps`, `--scale`, `--no-glass` and the knobs above; section 9); explicit
flags still win. `--water-shadows` is the sunset preset's setting (the other
presets fix their own: noon primary rays, midnight and storm none).

For example `python3 tools/reference.py --frame 300 --out out/ --glass fake
--water-shadows primary_only`. `--texels FILE` and `--palette FILE` override
the shore data; `--dump-npy` also saves the float image before quantisation
(`out/ref_*.npy`, 128x160x3) for debugging. One 160x128 frame takes
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

Install it as in [docs/INSTALL.md](../../../docs/INSTALL.md): copy
`zig-out/firmware/snouty-reflections.uf2` (repository root) onto the
badge's `SYCLBADGE` drive (not the RP2350 bootloader drive), eject, and
pick it in the badge menu. Start+Select returns to the menu.

To read the timing on the badge, flash a `zig build -Dcart=snouty-reflections -Ddebug_overlay=true` build (render
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

## 9. Perf variants (M2.1)

`-Dreflections_variant=full20|cut20|full15|half30` (default `cut20`, the shipped one) picks the
resolution, frame rate and scene cuts; `docs/variants.md` has the table and
numbers. The scene animates in seconds (one orbit is 30 s at every fps), so
every variant shows the same scene at the same moment on hardware.

```sh
tools/build_variants.sh            # all four -> dist/variants/<name>.{uf2,elf,wasm}, sizes, check-float
tools/build_variants.sh half30     # just one
tools/check_render.mjs --variant cut20 [--frame F]...   # reference check (dist/variants/<name>.wasm; section 6)
tools/bench_variants.sh [name...]  # badge-bench one orbit each; ~4 min per variant (--m3: section 10)
```

To compare in the web simulator, serve one file and copy variants over it;
the watcher reloads the page on every copy:

```sh
cp dist/variants/cut20.wasm dist/variants/current.wasm
node ../../tools/serve-cart.mjs dist/variants/current.wasm      # terminal 1, as in section 4
cp dist/variants/half30.wasm dist/variants/current.wasm         # switch; the page reloads
```

The simulator only fetches from port 2468 and calls `update()` 60 times a
second whatever the cart's vsync says, so it plays full20 and cut20 3x fast,
full15 4x and half30 2x. Judge the picture there, not the motion or frame
rate; the timing is in `docs/variants.md` (or on the badge with
`-Ddebug_overlay=true`).

## 10. M3 bench rows

`tools/bench_variants.sh --m3 [row...]` runs the M3 badge-bench rows
(PLAN.md M3 "Budget and bench") for cut20 (`M3_VARIANT=half30` etc. for
another variant), calibrated busy ms, worst frame at most 47.0 ms:

| Row | Build | Run | Gate |
|-----|-------|-----|------|
| 1 `step1` | `-Dreflections_bench=motion_off` (motion knob off) | 600 frames: sunset, one orbit | 47.0, and at most 1.0 ms over the M2.2 worst (45.94, or `BASELINE_ELF=path/to/m2.2/cut20.elf` benched the same way) |
| 2 `attract` | default | 2,400 frames: four orbits of attract, every preset, motion, fades | 47.0; worst and mean per preset (600-frame block) |
| 3 `height` | `-Dreflections_bench=height` (attract sweeps the height 1.0 to 1.8 and back) | 2,400 frames, one orbit per preset | 47.0; per preset |
| 4 `palette16` | default | 600 frames, `--poke dither.mode=3` (palette16 from frame 0) | reported only |

The ELFs are `dist/bench/<variant>-{default,motion_off,height}.elf`; a
missing one is built at the repository root and copied there (the root
`zig-out/` then holds that build), and the default one may also come from
`dist/variants/<variant>.elf` (`tools/build_variants.sh`). `REBUILD=1`
rebuilds all three. Reports land in `out/bench_m3_<row>/`. Rows 2 and 3 take
about 5 minutes each; `BENCH_FRAMES=N` cuts every run short for a smoke test.

```sh
tools/bench_variants.sh --m3                   # rows 1-4
tools/bench_variants.sh --m3 2 4               # attract and palette16 only
BASELINE_ELF=/path/to/m2.2/cut20.elf tools/bench_variants.sh --m3 1
```

## 11. M4 freeze frame: path tracer checks and bench

A freezes time and the path tracer (`cart/src/pt.zig`, PLAN.md M4) takes
over. Three tools check and measure it.

**References.** `tools/reference.py --pt` computes the M4 estimator with
the same random numbers as the cart (bit-exact integer RNG, f64 shading) and
caches the float means in `out/pt_ref/`
(`pt_<view>_n0000-NNNN_<scene>.npy` plus a PNG; `<scene>` is a hash of the
scene constants, so a scene change such as M3.1's never reuses a stale
file). check_pt renders missing references itself; to (re)generate the
whole check set at once (after a scene change, or ahead of time):

```sh
python3 tools/reference.py --pt --check-set --passes 16,64,256,1024   # 6 views; 16/1024 for check_pt, 64/256 for --ref-only
python3 tools/reference.py --pt --passes 1024 --preset noon --t 0      # one view (--view P:T[:O[:H]] too)
python3 tools/reference.py --rng-selftest                              # lowbias32 / hash / R2 / to_unit values for pt.zig's test
```

Each pass is 20,480 rays, traced as one numpy wavefront per 4 passes and
split over all cores (`--jobs`). On the two-core VM a pass costs about
40 ms of CPU, 30 ms of wall time when idle (a 1024-pass view about 30 s,
the `--check-set` line above about 4 minutes); with other builds running
(load 10 to 14) the same line took 19 minutes.

**Check.** `tools/check_pt.mjs` loads the wasm (default
`dist/variants/cut20.wasm`, else the root `zig-out/bin/`), sets each view
with `debug_set_view`, `debug_set_pt(1)`, `debug_set_dither_mode(1)` and
reads the accumulator from `debug_pt_accum()`:

| Check | What | Pass |
|-------|------|------|
| 3 seed | the update after `debug_set_view` draws the real-time frame and runs `pt.begin`; the decoded accumulator, quantised as `display()` does in dither none, equals that frame; after one more update every untouched column still shows it | exact |
| 1 same samples | `debug_pt_restart`, `debug_pt_run(16)` against the reference's first 16 passes | >= 98% of channel values within 3 units, mean abs <= 0.5 (8-bit units of [0, 1], means saturated) |
| 2 convergence | continue to 64 and 256 passes, RMSE against the 1024-pass reference | decreasing, RMSE(64) / RMSE(256) >= 1.6, RMSE(256) <= 4.0 |

Check set: each preset at t = 0, orbit 0; sunset at t = 300 (orbit 300);
noon at height 1.0.

```sh
node tools/check_pt.mjs                                    # the check set, all three checks
node tools/check_pt.mjs --wasm ../../zig-out/bin/snouty-reflections.wasm --only --view noon:0:0:1.0 --checks 1
node tools/check_pt.mjs --ref-only                         # check 2 on the reference itself (no cart)
node tools/check_pt.mjs --checks 1,3 --no-accum-info       # quick: seed and same samples only
```

It prints per-check numbers per view and exits 0 (PASS), 3 (FAIL) or 2
(missing exports). Two ungated `(info)` lines compare the cart with
`reference.py --pt --accum`, a simulation of the u32 accumulator with its
stochastic rounding (cached like the means): at 16 passes the share of
identical values (99.95% on Track A's work in progress: the same samples),
and at 256 passes the RMSE the accumulator format itself costs. The
11:11:10 running mean is re-rounded every pass, so its rounding error is a
random walk that grows with the pass count (about 1.3 units RMSE at 256 on
sunset): most of check 1's mean |d| (0.43 on sunset) and the floor under
check 2's RMSE(256) come from it, not from the tracer. On Track A's work
in progress (2026-09-30) checks 1 and 3 pass on the whole set while check
2 fails its ratio (0.98 to 1.40) for exactly this reason: the simulated
accumulator scores the same RMSE as the cart. `--no-accum-info`
skips the 256-pass simulation (about 20 s per view on an idle VM). On the
reference alone (`--ref-only`) the ratio RMSE(64) / RMSE(256) is 2.3 to 2.4
and RMSE(256) 0.25 to 0.86 units over the check set. Images go to `out/check_pt/`: `cart_<view>_nNNNN.png`
(the cart's mean in dither none) and `absdiff_<view>_n0016.png` (|cart -
reference| x 40). The accumulator is read as word `x * 128 + y`
(column-major, `ACCUM_INDEX` at the top of the file). `check_render.mjs`
calls `debug_set_pt(0)` when the cart has it, so its checks stay the
real-time M3 ones.

**Bench.** `tools/bench_variants.sh --m4 [row...]` (cut20, calibrated busy
ms):

| Row | Run | Gate |
|-----|-----|------|
| 5 `sunset`, `midnight`, `noon` | `tools/scripts/m4_freeze_<preset>.json` (Select to the preset, A at update 100), 1,300 updates | every update after the A update <= 47.0 ms; reports passes at the end, the update at which passes reach 256, seconds from A to 256 passes at 20 fps, busy ms per pass |
| 6 `stick` | `tools/scripts/m4_frozen_stick.json` (stick held while frozen) | reported only |
| 1, 2 | the M3 rows again | each within 0.1 ms of M3 (row 1 45.49; row 2 per preset 46.36 / 50.30 / 50.62 / 45.45) |

The A update itself (the real-time frame plus `pt.begin`) is shown in its
own column. Passes are read from the emulated RAM after each update through
the ELF symbol `pt.n_col` (min over the 160 columns; `PT_PASSES_SYM=name`
picks another), with badge-bench driven through its Python API; without
the symbol the done update is guessed from the update times (marked `~`).
The M3 baselines are the variables `M3_ROW1`, `M3_ROW2_<PRESET>` near the
top of the M4 section (or the environment). The ELF cache is the M3 one:
run `REBUILD=1` after changing the cart. Reports land in
`out/bench_m4_<row>/`; `BENCH_FRAMES=N` shortens the runs.

`M3_VARIANT=half30 tools/bench_variants.sh --m4 5` benches another
variant: the row 5 gate and the seconds-to-256 figure follow its frame
rate (the period minus 3 ms: 47.0 ms at 20 fps, 63.67 at 15, 30.33 at 30).

```sh
tools/bench_variants.sh --m4              # rows 5, 6, 1, 2 (about 20 to 25 minutes on an idle VM)
REBUILD=1 tools/bench_variants.sh --m4 5  # rebuild the ELFs first, row 5 only
M3_ROW1=45.60 tools/bench_variants.sh --m4 1
```

## 12. Frozen path tracer pacing

On the badge `pt.step` traces whole columns until `pt.slice_us` after the
start of the update, then `display()` dithers the accumulator. The slice is
the variant's frame period minus `variant.pt_reserve_us` (14,000 us), so
every variant keeps its frame rate while frozen (review G3: a fixed 36 ms
slice overran half30's 33.3 ms period on every converging update):

| Variant | fps | Period (us) | Slice (us) |
|---------|-----|-------------|------------|
| `full20` | 20 | 50,000 | 36,000 |
| `cut20` (shipped) | 20 | 50,000 | 36,000 (unchanged from M4; the ELF's code is identical) |
| `full15` | 15 | 66,666 | 52,666 |
| `half30` | 30 | 33,333 | 19,333 |

The reserve is the measured time a frozen update spends outside the
deadline loop (input, `display()`, `dither.end_frame`, the overshoot of the
column that crosses the deadline) plus margin. Measured with
`tools/bench_variants.sh --m4 5` (calibrated busy ms, worst frozen update
minus the slice): cut20 6.89 ms (M4: 42.89 ms worst for a 36 ms slice),
half30 6.97 ms (26.30 ms worst for 19.33 ms, 2026-10-02). With 14 ms
reserved, half30's worst frozen update is 26.30 ms against a 30.33 ms gate;
at 30 fps it reaches about 140 passes in the 40 s the row runs (212 to 228
busy ms per pass) where cut20 reaches 256 in about 58 s.
`tools/check_variants.sh` (host test, `tests/variant_unit.zig`) checks
slice < period for every variant in `build.zig`'s enum; `variant.zig` also
refuses at compile time a variant whose period is not longer than the
reserve. The simulator traces a fixed `pt.wasm_columns_per_update` instead
of timing, so frozen pacing is a badge-bench and show-day check only.

