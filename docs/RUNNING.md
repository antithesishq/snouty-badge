# Running the Snouty carts

Shared instructions for every cart in this repository. Each cart's own
`carts/<cart>/docs/RUNNING.md` has its previews, input scripts and gates.

## 1. Prerequisites

- git
- Zig **0.17.0-dev.1936+5a625d5f3** exactly (upstream sycl-badge pins it).
  Nightly tarballs are named `zig-<arch>-<os>-<version>.tar.xz`; the Linux
  x86_64 one is
  <https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1936+5a625d5f3.tar.xz>.
  Nightlies rotate off ziglang.org; if the URL 404s, try the machengine.org
  mirror or `zigup`. Unpack it and put the `zig` binary on `PATH`.
- Node.js 20 or newer (for the simulator and the carts' `tools/`)
- Python 3 with Pillow (GIF previews, the art pipeline); Python 3.9+ with the
  `venv` module for badge-bench

## 2. Checkout

The upstream SDK is the git submodule `sycl-badge/`, so clone recursively or
initialise it afterwards:

```sh
git clone --recursive git@github.com:antithesishq/snouty-badge.git
# or, straight from the exe.dev VM while a branch is under review:
git clone -b monorepo exedev@animated-badge.exe.xyz:/home/exedev/snouty-badge
cd snouty-badge && git submodule update --init
```

Milestones are annotated tags namespaced by cart (`git tag -n1`):
`snouty-bugs/m5`, `snouty-maze/m3`, and the running cart's `v3.0.0`. The
running cart's tags predate this layout and check out the old single-cart
tree, which needs `../sycl-badge` as a sibling.

## 3. Build

All from the repository root:

```sh
zig build                          # every cart, a few minutes clean
zig build -Dcart=snouty-maze       # one cart; comma-separate for several
zig build --help                   # the per-cart options (-Ddebug_overlay, -Drom, ...)
zig build -Dsound=true             # carts boot with sound on (default off; a menu row or button toggles it, docs/SOUND.md)
```

Outputs, one set per cart:

- `zig-out/firmware/<binary>.uf2` (for the badge)
- `zig-out/firmware/<binary>.elf` (for badge-bench and `size -A`)
- `zig-out/bin/<binary>.wasm` (for the simulator)

Binaries (the 12 carts of the root `build.zig`, plus the calibration
tool): `snouty` (cart `snouty-run`), `snouty-bugs`, `snoutenstein`,
`snouty-reflections`, `snouty-boy`, `snouty-maze`, `snouty-gear`,
`snouty-genesis` (XIP only: `snouty-genesis-xip`), `snouty-lynx` (plus
`snouty-lynx-xip` by default), `snouty-flyover`, `demosnout`,
`snouty-zero` (XIP only: `snouty-zero-xip`) and `badge-calibrate`.
`zig build -Dcart-mode=xip` (or `both`) adds the execute-in-place variant
`zig-out/firmware/<binary>-xip.uf2` and `.elf` for the other carts, which
runs code from the cart flash window and keeps all cart RAM for data;
section 8 below. `zig build test` runs every cart's host tests and the
shared `lib/` tests (the gate before a merge); `zig build check-float`
fails if a float-heavy cart links soft-float or libm routines. Zig fetches
packages into `zig-pkg/` at the root (gitignored).

If building on the Mac fails inside the compiler with `error: OutOfMemory`,
that is a known comptime issue with this Zig; the prebuilt files can be pulled
from the VM instead: `scp exedev@animated-badge.exe.xyz:/home/exedev/snouty-badge/zig-out/firmware/<binary>.uf2 .`

## 4. Web simulator

Terminal 1, from the cart's directory, serves its wasm and live-reloads it:

```sh
cd carts/snouty-bugs
node ../../tools/serve-cart.mjs      # serves ../../zig-out/bin/snouty-bugs.wasm on :2468
```

The shared tool picks the cart from the directory it is run in; `--cart NAME`
or a wasm path override that.

Terminal 2 runs upstream's simulator UI:

```sh
cd sycl-badge/simulator
npm install
npm run dev                          # then open http://localhost:1234
```

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

Every cart carries wasm-only shims (`present_wasm()`, `read_controls()`)
because upstream's simulator reads a legacy framebuffer at 0x20 with red and
blue swapped and writes buttons to 0x04; the carts' CLAUDE.md files explain.

## 5. Headless preview

The shared `tools/preview.mjs` runs `start()` then `update()` N times and
writes PNG frames plus `frames.json`; `tools/make_gif.py` stitches them. From
a cart's directory:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --frames 240 --every 4 --out out/
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 66
```

One tool serves every cart: `--press [BTN:]T1-T2`, `--script FILE.json`,
`--seed`, `--dump-exports`, `--expect`, `--at`, `--call-at` (bugs, boy),
`--call`, `--pose` (maze); `--help` lists them. Each cart's RUNNING.md has
its scripts and gates.

## 6. Benchmark before flashing

```sh
badge-bench/bench.sh zig-out/firmware/snouty-bugs.elf --every 60 --symbols
```

picks up `badge-bench/carts/snouty-bugs.toml` (frames, budget, input script)
and reports modelled milliseconds per `update()`. The model is a floor;
leave headroom. `badge-bench/README.md` has the details.

## 7. Flash the badge

[INSTALL.md](INSTALL.md) is the one recipe: copy
`zig-out/firmware/<binary>.uf2` (or `<binary>-xip.uf2` for the XIP-only
carts) onto the badge's `SYCLBADGE` drive, eject, start the cart from the
OS menu, Start+Select back. It also covers ROM files for the emulator
carts and the RP2350 bootloader drive that is easy to mistake for it.

## 8. XIP carts

```sh
zig build -Dcart=snouty-boy -Dcart-mode=xip     # or -Dcart-mode=both
python3 tools/uf2_info.py zig-out/firmware/snouty-boy-xip.uf2
```

The XIP build links the same cart source with the SDK's `cart_xip.ld`: code
and read-only data at `0x101C0000..0x10200000` (the badge's 256 KB cart flash
window), `.data` and `.bss` in the 307 KB cart RAM window, and a vector table
at the flash origin that the OS jumps through. The reset handler in
`build/xip/entry.zig` enables the FPU and cycle counter, copies `.data` from
flash, zeroes `.bss` and enters the SDK's usual start/update/present loop.
`uf2_info.py` must report every block inside the flash window: the OS loader
refuses a UF2 that mixes flash and RAM blocks. Flash it like any other cart.
Untested on hardware as of 2026-09-27: whether the current OS menu accepts an
XIP UF2, the erase-and-program time per launch, and the frame time versus the
RAM build (the fps overlay shows the XIP cache hit rate). Root `PLAN.md` M3.
