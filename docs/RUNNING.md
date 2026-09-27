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
```

Outputs, one set per cart:

- `zig-out/firmware/<binary>.uf2` (for the badge)
- `zig-out/firmware/<binary>.elf` (for badge-bench and `size -A`)
- `zig-out/bin/<binary>.wasm` (for the simulator)

Binaries: `snouty`, `snouty-bugs`, `snoutenstein`, `snouty-reflections`,
`snouty-boy`, `snouty-maze`. `zig build test` runs the host tests (snouty-boy
core, snouty-maze modules); `zig build check-float` fails if a float-heavy cart
links soft-float or libm routines. Zig fetches packages into `zig-pkg/` at the
root (gitignored).

If building on the Mac fails inside the compiler with `error: OutOfMemory`,
that is a known comptime issue with this Zig; the prebuilt files can be pulled
from the VM instead: `scp exedev@animated-badge.exe.xyz:/home/exedev/snouty-badge/zig-out/firmware/<binary>.uf2 .`

## 4. Web simulator

Terminal 1, from the cart's directory, serves its wasm and live-reloads it:

```sh
cd carts/snouty-bugs
node tools/serve-cart.mjs            # serves ../../zig-out/bin/snouty-bugs.wasm on :2468
```

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

Each cart has `tools/preview.mjs` (runs `start()` then `update()` N times and
writes PNG frames plus `frames.json`) and `tools/make_gif.py`. From a cart's
directory:

```sh
node tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --frames 240 --every 4 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 66
```

Options differ slightly per cart (`--press`, `--script`, `--seed`, expectation
checks); see that cart's RUNNING.md.

## 6. Benchmark before flashing

```sh
badge-bench/bench.sh zig-out/firmware/snouty-bugs.elf --every 60 --symbols
```

picks up `badge-bench/carts/snouty-bugs.toml` (frames, budget, input script)
and reports modelled milliseconds per `update()`. The model is a floor;
leave headroom. `badge-bench/README.md` has the details.

## 7. Flash the badge

1. Connect the badge over USB-C. It shows up as a USB mass-storage drive.
2. Copy `zig-out/firmware/<binary>.uf2` onto the drive, replacing `CURRENT.UF2`.
