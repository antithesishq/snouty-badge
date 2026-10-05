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
git fetch && git checkout tof/m0 && git submodule update --init       # this milestone's branch
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
`badge-bench/carts/snouty-sense.toml`: LIVE, then HIST at 300, DIAG at
600):

```sh
zig build -Dcart=snouty-sense && badge-bench/bench.sh zig-out/firmware/snouty-sense.elf                    # no sensor
zig build -Dcart=snouty-sense -Dtof-fake=true && badge-bench/bench.sh zig-out/firmware/snouty-sense.elf    # virtual sensor
```

## 4. Controls

| Input | LIVE | HIST | DIAG |
|---|---|---|---|
| Left / Right | previous / next page | same | same |
| A | flip X | linear / log | I2C speed 400 -> 1000 -> 100 kHz |
| B | flip Y | | reload (CPU reset + firmware download) |
| Up | transpose | previous channel | |
| Down | SPAD map normal / wide | next channel | |

Start and Select do nothing (the OS owns Start+Select; the cart ignores
everything while both are held); the joystick click is the OS's.

What to look for on the badge, and what to photograph: docs/TOF.md
section 5.

## 5. Web simulator

The simulator has no I2C; the cart runs the virtual sensor (a wall at
~900 mm, a hand wandering in front of it 6.5 s out of every 8). It boots
it the same way as the real one (firmware download and all).

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
