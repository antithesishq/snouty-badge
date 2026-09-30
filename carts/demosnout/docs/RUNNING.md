# Running the Demosnout cart

The cart lives in `carts/demosnout/` of the snouty-badge repository.
Commands below run from the repository root; the outputs are in the root
`zig-out/`.

## 1. Prerequisites

Zig, Node.js, Python with Pillow and git: see `docs/RUNNING.md` at the
repository root. Pillow and the DejaVu Sans Bold font are only needed to
regenerate `cart/src/gen/` (section 7); the generated files are committed.

## 2. Getting the code

Cloning the repository with its `sycl-badge/` submodule is described in
`docs/RUNNING.md` at the repository root. Milestones are annotated tags
(`git tag -n1 'demosnout/*'`).

## 3. Build and test

```sh
zig build -Dcart=demosnout   # firmware + wasm (plain `zig build` builds every cart)
zig build test                  # host tests: timeline and veils, palette, fx, integer sine, scroller font, every part's pure helpers (and the other carts')
zig build check-float           # fails if f64 soft-float code reached the firmware
```

`zig build` writes `zig-out/firmware/demosnout.uf2` (for the badge),
`zig-out/firmware/demosnout.elf` and `zig-out/bin/demosnout.wasm` (for
the simulator and the headless tools). A clean build of this cart takes
about 4 minutes on the 2-core VM; incremental builds take seconds.
`-Ddebug_overlay=true` compiles in the timing overlay (on at start, B
toggles it).

## 4. What it shows and the controls (M3)

A demo of 114 seconds on a 120 BPM frame clock (30 frames per beat, 120
per bar), looping forever. Between most parts the picture fades to black
over 20 frames, holds 10 black frames and the next part fades up; Copper
and Voxel hand over with a block dissolve instead, and the Ending melts
into the Intro's starfield with no cut at all.

| # | Part | Bars | Seconds | What it shows |
|---|---|---|---|---|
| 0 | Intro | 3 | 6 | starfield warp, "ANTITHESIS PRESENTS" at 1.5 s, DEMOSNOUT slams in at 3 s |
| 1 | Plasma | 5 | 10 | half-resolution sum-of-sines plasma, palette cycling through fire, ocean, candy |
| 2 | Copper | 7 | 14 | six copper bars behind the sine scroller of greetings (the whole text crosses once before the dissolve) |
| 3 | Rotozoomer | 5 | 10 | the Snouty sprite tiled to infinity, turning and zooming on the beat |
| 4 | Twister | 4 | 8 | a shaded four-faced column twisting over a reflecting floor |
| 5 | Tunnel | 4 | 8 | flying down a tunnel lined with Iris marks |
| 6 | Metaballs | 5 | 10 | glowing blobs merging and splitting, warm then cool |
| 7 | Voxel | 7 | 14 | fly-over of a Green Hill Zone island |
| 8 | Snouty head | 5 | 10 | a flat-shaded low-poly Snouty head tumbling in space |
| 9 | Fire | 4 | 8 | cooling-map fire with the Iris mark floating in it |
| 10 | Ending | 8 | 16 | the Iris mark rises over a night sea, reflected in the water; seven credit cards |

| Input | Action |
|---|---|
| A or Start | Skip to the next part (immediate cut, its fade-in kept) |
| Select | Open the part picker (index, name and length of every part; the one playing has a gold arrow) |
| Picker: Up / Down | Move the highlight (wraps) |
| Picker: A | Jump to that part (from its frame 0) and close |
| Picker: Select or B | Close |
| B | Hold: auto-advance off, the current part keeps going ("HOLD ON" shows bottom-right for a second; B again shows "HOLD OFF" and the show moves on). Every part but the Ending runs on without end and without fading out; the Ending fades out and restarts. A, Start and the picker still work while held, and the hold stays on across them |
| B (`-Ddebug_overlay=true` builds) | Toggle the timing overlay instead: render microseconds, part index, frame in part |

The OS owns Start+Select (back to the menu) and the joystick click (its FPS
overlay); the cart never reads the click and ignores every button while
Start and Select are held together. No sound, no neopixels.

## 5. Web simulator

```sh
node tools/serve-cart.mjs zig-out/bin/demosnout.wasm   # serves it on :2468, reloads after every build
cd sycl-badge/simulator && npm install && npm run dev     # second terminal; open http://localhost:1234
```

Keyboard: arrows or WASD for the stick, the simulator's keys for A, B,
Start and Select (see the root `docs/RUNNING.md`).

## 6. Headless preview and checks

```sh
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 1800 --every 6 --raw-colors --out carts/demosnout/out/m0
python3 tools/make_gif.py carts/demosnout/out/m0 carts/demosnout/docs/preview_m0.gif --scale 3 --ms 100
```

`--raw-colors` decodes the frame as the badge shows it. Without it
`preview.mjs` renders what the web simulator displays from the cart's own
framebuffer, which has red and blue swapped (the cart's `present_wasm()`
pre-swaps only the copy at 0x20 that the simulator reads), so the
starfield's navy turns brown and the plasma's fire turns blue.

Wasm exports for checks: `debug_frame` (updates since start), `debug_part`
and `debug_part_frame` (what the next update renders), `debug_pixel_checksum`,
`debug_render_us`, `debug_picker` (0/1), `debug_hold` (0/1) and `debug_goto(part)`:

```sh
# A at update 100 skips from the Intro to the Plasma.
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 200 --quiet --press A:100-101 --at "150 debug_part == 1"
# Start on part 2 (the badge build takes badge-bench's --poke scene_part=2 instead).
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 5 --quiet --call debug_goto:2 --at "0 debug_part == 2"
# Picker: open on the Intro, Down twice, A jumps to part 2.
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 100 --quiet --press SELECT:50-51 \
  --press DOWN:60-61 --press DOWN:64-65 --press A:80-81 --at "55 debug_picker == 1" --at "81 debug_part == 2"
# One part on its own, e.g. the copper bars.
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 720 --every 6 --raw-colors --call debug_goto:2 --out carts/demosnout/out/copper
# B at update 100 holds the Intro: still part 0 long after its 360 frames.
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 900 --quiet --press B:100-101 --at "150 debug_hold == 1" --at "899 debug_part == 0"
# The whole loop, every 10th frame, as the review GIF.
node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 6840 --every 10 --raw-colors --out carts/demosnout/out/m2
python3 tools/make_gif.py carts/demosnout/out/m2 carts/demosnout/docs/preview_m2.gif --scale 2 --ms 166
```

### Timeline regression check

```sh
node carts/demosnout/tools/check_timeline.mjs            # PASS / FAIL, exit 3 on a failure
node carts/demosnout/tools/check_timeline.mjs --update   # rewrite tests/golden.json from this build
```

It reads the bar lengths from `cart/src/timeline.zig`, runs one full loop
plus a second headless (`preview.mjs --quiet --call-at ...`, under a
second) and checks that every 30th update shows the part and frame the
lengths predict, that at every boundary the part index goes up by one
(wrapping to 0 after the Ending) while `debug_part_frame` drops to 0, and
that `debug_pixel_checksum` of each part's frame 30 (after its fade-in)
matches `tests/golden.json`. Any change to a part's pixels changes its
checksum: look at the frames, then run `--update` and commit the new
golden with the change. `--stride N` samples every N-th update instead.

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
badge-bench/bench.sh zig-out/firmware/demosnout.elf --frames 900 --every 60 --symbols
carts/demosnout/tools/bench_parts.sh          # every part: one run each, worst-frame table
carts/demosnout/tools/bench_parts.sh 0 1 2    # just these parts
```

`badge-bench/carts/demosnout.toml` sets 900 frames and the 16.7 ms
budget. `bench_parts.sh` pokes `scene_part=N` so each run starts on part N,
runs its length plus 60 frames, and prints mean and worst calibrated busy
ms over the part's own frames; the rule is every part's worst frame under
12 ms (it exits 1 otherwise). Numbers per milestone are in `docs/PERF.md`.

## 9. Flash the badge

Copy `zig-out/firmware/demosnout.uf2` onto the badge's USB drive,
replacing `CURRENT.UF2`.
