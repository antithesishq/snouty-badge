# Running Snouty Morph

The cart lives in `carts/snouty-morph/` of the snouty-badge repository.
Commands run from the repository root; outputs land in the root `zig-out/`.
Prerequisites (Zig, Node.js, Python with Pillow, git) and cloning with the
`sycl-badge/` submodule: `docs/RUNNING.md` at the repository root.

## 1. Pull and build

This cart is on branch `tof/morph` (worktree
`/home/exedev/snouty-badge-morph`) until the lead merges it with the
sensor driver:

```sh
git fetch && git checkout tof/morph && git submodule update --init
zig build -Dcart=snouty-morph                 # firmware + wasm
zig build test                                # lib/tof_pose + this cart's host tests (and every other cart's)
zig build check-float -Dcart=snouty-morph     # no soft-float or libm in the ELF
```

Outputs: `zig-out/firmware/snouty-morph.uf2` (the badge, a RAM cart),
`zig-out/firmware/snouty-morph.elf` (badge-bench) and
`zig-out/bin/snouty-morph.wasm` (simulator, headless preview).
`-Dsound=true` boots with sound on; `-Ddebug_overlay=true` shows the
render time (us) and faces drawn bottom-right.

## 2. Controls

| Input | Does |
|---|---|
| hand over the sensor | the mesh follows it (x, y, distance, tilt, turn) and deforms |
| stick | moves the virtual hand (STICK source) |
| B + stick up/down | pushes / pulls the hand (closer = bigger, REACH grows) |
| B + stick left/right | turns the hand (mesh spins, TWIST wobbles) |
| A | punch: SHOCKWAVE ripple, flash, shake |
| Start | next mesh: KNOT, BOING, SNOUTY, IRIS |
| Select | sound on / off (boots off) |

Top-left shows the source: GHOST (attract: a scripted hand through
synthetic sensor frames and the real estimator), STICK (6 s after the last
input it hands back to the ghost) or HAND (the sensor). Top-right is the
3x3 zone map (hand coverage per zone) for GHOST and HAND. Without the
breakout (and always in the simulator) the cart runs GHOST and STICK only;
`cart/src/sensor.zig` runs lib/tof.zig on the badge.

## 3. Simulator

```sh
cd carts/snouty-morph && node ../../tools/serve-cart.mjs     # serves this cart's wasm on :2468
cd sycl-badge/simulator && npm run dev                       # in another shell
```

## 4. Headless preview and GIFs

```sh
node tools/preview.mjs zig-out/bin/snouty-morph.wasm --frames 960 --every 4 --out /tmp/ghost
python3 tools/make_gif.py /tmp/ghost carts/snouty-morph/docs/preview_ghost.gif --scale 2 --ms 66
node tools/preview.mjs zig-out/bin/snouty-morph.wasm --frames 1380 --every 4 --out /tmp/deform \
    --script carts/snouty-morph/tools/scripts/gif_deform.json
python3 tools/make_gif.py /tmp/deform carts/snouty-morph/docs/preview_deform.gif --scale 2 --ms 66
```

`docs/preview_ghost.gif`: the 16 s ghost routine on KNOT (drift, approach
with REACH, circle with TWIST, punch with SHOCKWAVE, close rocking tilt).
`docs/preview_deform.gif`: the stick through all four meshes (JELLY
jerks, REACH, TWIST, punches, SNOUTY's tongue when very close).

Debug exports (wasm): `debug_frame`, `debug_mesh`, `debug_set_mesh(n)`,
`debug_source` (0 ghost, 1 stick, 2 sensor), `debug_present`,
`debug_hand_z` (0..1000), `debug_ripples`, `debug_faces`,
`debug_render_us`, `debug_pixel_checksum`, `debug_sound`.

## 5. badge-bench

```sh
badge-bench/bench.sh zig-out/firmware/snouty-morph.elf --symbols
```

Uses `badge-bench/carts/snouty-morph.toml` (3840 frames: each mesh for
one ghost routine, stick moves and punches; ~12 minutes). The badge
build exports `start_mesh` for `--poke start_mesh=N`. Numbers are in
`PLAN.md`.
