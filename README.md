# Snouty carts

Antithesis's carts for the SYCL Badge V2 (the Software You Can Love conference
badge), plus the tools used to make and measure them. One Zig build produces
every cart; each cart has its own directory with its design, plan, assets and
tools.

| Directory | Binary | What it is |
|---|---|---|
| `carts/snouty-run/` | `snouty` | Snouty runs and jumps across a Green Hill Zone waterfall; name panel. The original badge cart (tags `v1.0.0`..`v3.0.0`). |
| `carts/snouty-bugs/` | `snouty-bugs` | Horizontal bullet-hell shooter with rewind-on-hit and an attract mode (tags `snouty-bugs/m1`..`m5`). |
| `carts/snoutenstein/` | `snoutenstein` | Raycaster FPS with time rewind (tags `snoutenstein/m0`..`m3`). |
| `carts/snouty-reflections/` | `snouty-reflections` | Real-time ray tracer demo over water (tags `snouty-reflections/m0`..`m1.1`). |
| `carts/snouty-boy/` | `snouty-boy` | Game Boy emulator with an embedded ROM and a time scrubber (tags `snouty-boy/m1`..`m4`). |
| `carts/snouty-maze/` | `snouty-maze` | Windows 3D Maze screensaver clone on a small software rasterizer (tags `snouty-maze/m0`..`m3`). |
| `tools/` | | Shared cart tools: `preview.mjs` (headless wasm runner with input scripts and checks), `serve-cart.mjs` (feeds the web simulator), `make_gif.py`, `check_float.mjs`, `uf2_info.py`. |
| `badge-bench/` | | Emulated Cortex-M33 cycle benchmark for any cart ELF, with per-cart defaults and hot-function lists. |
| `badge-bench/calibrate/` | `badge-calibrate` | Hardware calibration cart: times 20 micro-kernels with the cycle counter during and after the LCD DMA; `fit.py` turns a console capture into badge-bench's `--calibrate` table. |
| `snouty-art/` | | Code-driven pixel-art pipeline (parts rig, procedural limbs) that produces the carts' sprite sheets. |
| `sycl-badge/` | | Upstream badge SDK and simulator, a git submodule pinned to the commit the carts are built against. |

## Build

Prerequisites, simulator and flashing details are in `docs/RUNNING.md`.

```sh
git clone --recursive git@github.com:antithesishq/snouty-badge.git
cd snouty-badge
zig build                        # every cart
zig build -Dcart=snouty-bugs     # one cart (any directory or binary name above)
zig build test                   # every cart's host tests
zig build check-float            # no soft-float in the FPU carts' ELFs
zig build -Dcart-mode=xip        # execute-in-place carts: <binary>-xip.uf2 (see below)
```

Outputs: `zig-out/firmware/<binary>.uf2` (copy onto the badge over
`CURRENT.UF2`), `zig-out/firmware/<binary>.elf` (for badge-bench) and
`zig-out/bin/<binary>.wasm` (for the simulator). Zig
`0.17.0-dev.1936+5a625d5f3` exactly, as pinned by upstream.

## RAM carts and XIP carts

By default a cart is a RAM cart: the OS copies the whole image into the
307 KB cart RAM window and code, read-only data and state share it. With
`-Dcart-mode=xip` (or `both`) the same source is also linked as an
execute-in-place cart: code and read-only data live in the badge's 256 KB
cart flash window and run from there through the XIP cache, and all of cart
RAM is left for `.data` and `.bss`. That roughly doubles what a cart can hold,
which is what the emulator carts need. The XIP build is
`zig-out/firmware/<binary>-xip.uf2`, flashed the same way. `tools/uf2_info.py`
shows which window a UF2 targets (the loader refuses a mix). Root `PLAN.md`
section M3 has the design and the open hardware questions.

## Where to read next

- `PLAN.md` at the root: the repository plan (the move to one repository).
  Each cart's own `PLAN.md` and `SPEC.md` hold its design and milestone status.
- `CLAUDE.md` at the root: shared hardware, cart API and build notes; each
  cart's `CLAUDE.md` adds what is specific to it.
- `carts/<cart>/docs/RUNNING.md`: how to preview, test and flash that cart.
- `badge-bench/README.md`: how to cost a cart before flashing it.
