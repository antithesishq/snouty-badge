# Running the Snouty Sense cart

The cart lives in `carts/snouty-sense/` of the snouty-badge repository:
the time-of-flight probe for a SparkFun Qwiic Mini dToF Imager (TMF8820)
on the badge's Qwiic port (`SPEC.md`, docs/TOF.md). Commands below run
from that directory unless noted; `zig build` runs from the repository
root (`../..`), and its outputs are in the root `zig-out/`.

## 1. Prerequisites

Zig `0.17.0-dev.1936+5a625d5f3`, Node.js 20+, Python 3 (with Pillow for
GIFs): see [`docs/RUNNING.md`](../../../docs/RUNNING.md) at the
repository root. For the real sensor: an r2 (production) SYCL badge, the
breakout and a Qwiic cable.

## 2. Get the code

```sh
git clone --recursive git@github.com:antithesishq/snouty-badge.git   # first time
cd snouty-badge
git fetch && git checkout tof/m2 && git submodule update --init       # this milestone's branch
```

## 3. Build and test

From the repository root:

```sh
zig build -Dcart=snouty-sense                     # firmware + wasm
zig build test                                    # lib/'s host tests include the driver's (lib/tests/tof_unit.zig)
zig build -Dcart=snouty-sense -Dtof-fake=true     # badge build on the virtual sensor (for badge-bench)
```

`zig build -Dcart=snouty-sense` writes `zig-out/firmware/snouty-sense.uf2`
(flash this), `zig-out/firmware/snouty-sense.elf` (badge-bench) and
`zig-out/bin/snouty-sense.wasm` (simulator). A `-Dtof-fake=true` build
writes the same names: rebuild without it before flashing.

badge-bench, from the root (both runs use
`badge-bench/carts/snouty-sense.toml`: LIVE, then HIST at 300, EYES at
600 with the sound on from 660, DEPTH at 900 (fine pass, CLOUD, MASK),
DIAG at 1500):

```sh
zig build -Dcart=snouty-sense && badge-bench/bench.sh zig-out/firmware/snouty-sense.elf                    # no sensor
zig build -Dcart=snouty-sense -Dtof-fake=true && badge-bench/bench.sh zig-out/firmware/snouty-sense.elf    # virtual sensor
```

## 4. Controls

| Input | LIVE | HIST | EYES | DEPTH | DIAG |
|---|---|---|---|---|---|
| Left / Right | previous / next page | same | same | same | same |
| A | flip X | linear / log | sound on / off | view: PHOTO / CLOUD / MASK | I2C speed 400 -> 1000 -> 100 kHz |
| B | flip Y | | hold the waterfall | new photo | reload (CPU reset + firmware download) |
| Up | transpose | previous channel | previous sound zone (AUTO, Z1..Z9) | exposure + 1 | |
| Down | SPAD map normal / wide | next channel | next sound zone | exposure - 1 | |
| Select | | | | fine pass (17x10) on / off | |

Pages: LIVE, HIST, EYES, DEPTH, DIAG (Left from LIVE is DIAG). The
cart boots silent; `zig build -Dcart=snouty-sense -Dsound=true` boots
with the EYES sound on.

Start and Select do nothing (the OS owns Start+Select; the cart ignores
everything while both are held); the joystick click is the OS's.

What to look for on the badge, and what to photograph: docs/TOF.md
section 5.

## 5. Web simulator

The simulator has no I2C; the cart runs the virtual sensor (a wall at
~900 mm, a hand wandering in front of it 6.5 s out of every 8; on DEPTH
a SPAD-level scene: a tilted wall, a floor, a box on the right, a
slowly drifting ball and five dead SPADs, one pair of them a hole in the
photo). It boots it the same way as the real one (firmware download and
all). The simulator plays EYES's sound as a plain pulse tone at the
wavetable's pitch (it has no streaming audio); the badge plays the
wavetable.

Terminal 1, from `carts/snouty-sense/`:

```sh
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/snouty-sense.wasm on :2468
```

Terminal 2:

```sh
cd ../../sycl-badge/simulator
npm install                                # first time
npm run dev
```

Then open <http://localhost:1234> (arrow keys = joystick, Z = A, X = B).

## 6. Headless preview and the review GIF

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-sense.wasm --frames 1080 --every 6 \
    --script tools/scripts/preview.json --out out/preview
python3 ../../tools/make_gif.py out/preview docs/preview_m0.gif --scale 2 --ms 100
```

`tools/scripts/preview.json`: boot on LIVE, a flip, HIST from 420 (the
zone 5 histogram, then the reference channel), DIAG from 840.

M2's GIF (EYES from 66 with the sound on at 240, DEPTH from 480: PHOTO,
CLOUD at 840, MASK at 1080, PHOTO with the fine pass from 1200):

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-sense.wasm --frames 1560 --every 6 --start-skip 66 \
    --script tools/scripts/preview_m2.json --out out/m2
python3 ../../tools/make_gif.py out/m2 docs/preview_m2.gif --scale 2 --ms 100
```
