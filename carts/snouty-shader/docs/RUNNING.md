# Running Snouty Shader

The cart lives in `carts/snouty-shader/` of the snouty-badge repository.
Commands run from the repository root; outputs land in the root `zig-out/`.
Prerequisites (Zig, Node.js, Python with Pillow, git) and cloning with the
`sycl-badge/` submodule: `docs/RUNNING.md` at the repository root.

## 1. Pull and build

```sh
git fetch && git checkout main && git pull && git submodule update --init
zig build -Dcart=snouty-shader                 # firmware + wasm
zig build test                                 # this cart's host tests (and every other cart's)
zig build check-float -Dcart=snouty-shader     # no soft-float or libm in the ELF
```

(Until it is merged: `git checkout shader/m1`, tag `snouty-shader/m1`.)

Outputs: `zig-out/firmware/snouty-shader.uf2` (the badge, a RAM cart),
`zig-out/firmware/snouty-shader.elf` (badge-bench) and
`zig-out/bin/snouty-shader.wasm` (simulator, headless preview).
`-Dsound=true` boots with sound on; `-Ddebug_overlay=true` shows the
update time (us) bottom-right.

## 2. On the badge

Copy `snouty-shader.uf2` to the badge drive the usual way
([docs/INSTALL.md](../../../docs/INSTALL.md)), plug the SparkFun TMF8820
breakout into the Qwiic port (before or after starting; replugging is
fine) and start the cart. Hold a hand 10-40 cm in front of the sensor:
hold B to see the inputs panel, whose top-right label turns HAND and whose
3x3 grid lights under your hand. Without the breakout a ghost hand plays
it (GHOST); B + stick steers a virtual hand (STICK).

## 3. Controls

| Input | Does |
|---|---|
| hand over the sensor | nearer = stronger, moving = flow, a quick jab toward the sensor = punch (shockwave, flash, palette jump) |
| Left / Right | previous / next program: INK, RIPPLE, LAVA, ECHO, CELLS, KALEIDO |
| Up / Down | the program's parameter 0..8 (WARP, WAVE, SPEED, TRAIL, SPEED, MIRRORS) |
| A | next palette (eight cosine palettes, kept per program) |
| B (hold) | inputs panel: program, palette, source, the 3x3 field, x/y/z, energy, pitch/roll/yaw (degrees), parameter, PUNCH |
| B + stick | steer the virtual hand (STICK; hands back to the ghost 4 s after the last move) |
| B + A | punch with the virtual hand |
| Start | sound on / off (acts on release; boots off) |
| Start + Select | the OS's settings / exit; the cart ignores every button while both are held |

Attract: with no hand over the sensor and no button for 30 s the next
program comes up, and so on every 30 s; any button or a real hand stops it.

## 4. Simulator

```sh
cd carts/snouty-shader && node ../../tools/serve-cart.mjs     # serves this cart's wasm on :2468
cd sycl-badge/simulator && npm run dev                        # in another shell
```

The simulator has no sensor: the ghost plays, B + arrow keys steer.

## 5. Headless preview and the GIF

```sh
node tools/preview.mjs zig-out/bin/snouty-shader.wasm --frames 1440 --every 4 --out /tmp/shader \
    --script carts/snouty-shader/tools/scripts/gif_tour.json
python3 tools/make_gif.py /tmp/shader carts/snouty-shader/docs/preview_tour.gif --scale 1 --ms 66
```

`docs/preview_tour.gif` (real time, 1x to keep it near 5 MB): the ghost
hand through all six programs, 4 s each; INK with the inputs panel, B +
stick steering and a punch, punches in LAVA and ECHO, a palette change in
KALEIDO.

Debug exports (wasm): `debug_frame`, `debug_program`,
`debug_set_program(n)`, `debug_palette`, `debug_param`, `debug_source` (0
ghost, 1 stick, 2 sensor), `debug_present`, `debug_hand_z` (0..1000),
`debug_field_peak`, `debug_punch_age`, `debug_render_us`,
`debug_pixel_checksum`, `debug_sound`, `debug_hud`.

## 6. badge-bench

```sh
badge-bench/bench.sh zig-out/firmware/snouty-shader.elf --symbols            # the tour, 3600 frames
badge-bench/bench.sh zig-out/firmware/snouty-shader.elf --poke start_program=3 --frames 960 \
    --script carts/snouty-shader/tools/scripts/bench_program.json           # one program pinned
zig build -Dcart=snouty-shader -Dtof-fake=true                               # the driver against its model
```

`badge-bench/carts/snouty-shader.toml` is the default run (each program
for 600 ticks of the ghost, B + stick and a punch in each). The badge
build exports `start_program` for `--poke start_program=N`. Numbers are in
`PLAN.md`.
