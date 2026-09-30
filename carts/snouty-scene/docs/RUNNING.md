# Running the Snouty Scene cart

The cart lives in `carts/snouty-scene/` of the snouty-badge repository.
Commands below run from the repository root; the outputs are in the root
`zig-out/`.

## 1. Prerequisites

Zig, Node.js, Python with Pillow and git: see `docs/RUNNING.md` at the
repository root. Pillow and the DejaVu Sans Bold font are only needed to
regenerate `cart/src/gen/` (section 7); the generated files are committed.

## 2. Getting the code

Cloning the repository with its `sycl-badge/` submodule is described in
`docs/RUNNING.md` at the repository root. Milestones are annotated tags
(`git tag -n1 'snouty-scene/*'`).

## 3. Build and test

```sh
zig build -Dcart=snouty-scene   # firmware + wasm (plain `zig build` builds every cart)
zig build test                  # host tests: timeline, palette, fx, integer sine, scroller font, copper (and the other carts')
zig build check-float           # fails if f64 soft-float code reached the firmware
```

`zig build` writes `zig-out/firmware/snouty-scene.uf2` (for the badge),
`zig-out/firmware/snouty-scene.elf` and `zig-out/bin/snouty-scene.wasm` (for
the simulator and the headless tools). A clean build of this cart takes
about 4 minutes on the 2-core VM; incremental builds take seconds.
`-Ddebug_overlay=true` compiles in the timing overlay (on at start, B
toggles it).

## 4. What it shows and the controls (M0)

A demo of about two minutes on a 120 BPM frame clock (30 frames per beat,
120 per bar), looping forever. Each part fades in over 15 frames and out
over 15.

| # | Part | Bars | Seconds | M0 state |
|---|---|---|---|---|
| 0 | Intro | 3 | 6 | starfield warp, "ANTITHESIS PRESENTS" at 1.5 s, SNOUTY / SCENE slams in at 3 s |
| 1 | Plasma | 5 | 10 | half-resolution sum-of-sines plasma, palette cycling through fire, ocean, candy |
| 2 | Copper | 6 | 12 | six copper bars behind the sine scroller of greetings |
| 3..10 | Rotozoomer, Tunnel, Twister, Metaballs, Voxel, Snouty head, Fire, Ending | 5, 5, 4, 5, 7, 6, 4, 7 | | placeholders (the index as a big digit) until M1/M2 |

| Input | Action |
|---|---|
| A or Start | Skip to the next part (immediate cut, its fade-in kept) |
| Select | Open the part picker over the dimmed demo |
| Picker: Up / Down | Move the highlight (wraps) |
| Picker: A | Jump to that part (from its frame 0) and close |
| Picker: Select or B | Close |
| B | Toggle the timing overlay (`-Ddebug_overlay=true` builds only): render microseconds, part index, frame in part |

The OS owns Start+Select (back to the menu) and the joystick click (its FPS
overlay); the cart never binds either. No sound, no neopixels.

## 5. Web simulator

```sh
node tools/serve-cart.mjs zig-out/bin/snouty-scene.wasm   # serves it on :2468, reloads after every build
cd sycl-badge/simulator && npm install && npm run dev     # second terminal; open http://localhost:1234
```

Keyboard: arrows or WASD for the stick, the simulator's keys for A, B,
Start and Select (see the root `docs/RUNNING.md`).

## 6. Headless preview and checks

```sh
node tools/preview.mjs zig-out/bin/snouty-scene.wasm --frames 1800 --every 6 --raw-colors --out carts/snouty-scene/out/m0
python3 tools/make_gif.py carts/snouty-scene/out/m0 carts/snouty-scene/docs/preview_m0.gif --scale 3 --ms 100
```

`--raw-colors` decodes the frame as the badge shows it. Without it
`preview.mjs` renders what the web simulator displays from the cart's own
framebuffer, which has red and blue swapped (the cart's `present_wasm()`
pre-swaps only the copy at 0x20 that the simulator reads), so the
starfield's navy turns brown and the plasma's fire turns blue.

Wasm exports for checks: `debug_frame` (updates since start), `debug_part`
and `debug_part_frame` (what the next update renders), `debug_pixel_checksum`,
`debug_render_us`, `debug_picker` (0/1) and `debug_goto(part)`:

```sh
# A at update 100 skips from the Intro to the Plasma.
node tools/preview.mjs zig-out/bin/snouty-scene.wasm --frames 200 --quiet --press A:100-101 --at "150 debug_part == 1"
# Start on part 2 (the badge build takes badge-bench's --poke scene_part=2 instead).
node tools/preview.mjs zig-out/bin/snouty-scene.wasm --frames 5 --quiet --call debug_goto:2 --at "0 debug_part == 2"
# Picker: open, Down twice, A jumps to part 2.
node tools/preview.mjs zig-out/bin/snouty-scene.wasm --frames 100 --quiet --press SELECT:50-51 \
  --press DOWN:60-61 --press DOWN:64-65 --press A:80-81 --at "55 debug_picker == 1" --at "81 debug_part == 2"
# One part on its own, e.g. the copper bars.
node tools/preview.mjs zig-out/bin/snouty-scene.wasm --frames 720 --every 6 --raw-colors --call debug_goto:2 --out carts/snouty-scene/out/copper
```

## 7. Generated data

`cart/src/gen/scroller_font.zig` (DejaVu Sans Bold, 16 rows, ASCII 32..95)
comes from `tools/gen_font.py`; `cart/src/gen/textures.zig` (Snouty and the
Iris mark, 32x32 and 64x64) from `tools/gen_textures.py` reading
`assets/*.png`. Texture values are in `cart.DisplayColor` bit order (r5 in
the low bits), converted once at `init()` with
`cart.Pixel.from_color(@bitCast(v))`. Rerun the tool and commit the output
when a source changes; the build never runs them.

## 8. Benchmark before flashing

```sh
badge-bench/bench.sh zig-out/firmware/snouty-scene.elf --frames 900 --every 60 --symbols
carts/snouty-scene/tools/bench_parts.sh          # every part: one run each, worst-frame table
carts/snouty-scene/tools/bench_parts.sh 0 1 2    # just these parts
```

`badge-bench/carts/snouty-scene.toml` sets 900 frames and the 16.7 ms
budget. `bench_parts.sh` pokes `scene_part=N` so each run starts on part N,
runs its length plus 60 frames, and prints mean and worst calibrated busy
ms over the part's own frames; the rule is every part's worst frame under
12 ms (it exits 1 otherwise). Numbers per milestone are in `docs/PERF.md`.

## 9. Flash the badge

Copy `zig-out/firmware/snouty-scene.uf2` onto the badge's USB drive,
replacing `CURRENT.UF2`.
