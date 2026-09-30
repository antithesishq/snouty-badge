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
| `carts/snouty-boy/` | `snouty-boy` | Game Boy and Game Boy Color emulator that runs `.gb`/`.gbc` files from the badge drive (a picker for several, the embedded ROM as fallback) with a time scrubber (tags `snouty-boy/m1`..`m5`; Color M6-M8 built). Sound off until the menu's Sound row turns it on (`-Dsound=true` flips the default). |
| `carts/snouty-maze/` | `snouty-maze` | Windows 3D Maze screensaver clone on a small software rasterizer (tags `snouty-maze/m0`..`m3`). |
| `carts/snouty-gear/` | `snouty-gear` | Game Gear emulator reading its ROM from the badge drive, Waternet embedded as fallback (M2: plays Waternet and Sonic GG, boot splash, one-voice PSG sound (off until the menu's Sound row turns it on, `-Dsound=true` flips the default), menu with button swap / scale / About; M3: time scrubber, Left/Right in the menu step half a second through up to 7 s of history, page-store keyframes in the run-time arena). |
| `carts/snouty-genesis/` | `snouty-genesis` | Sega Genesis emulator, XIP cart only (`snouty-genesis-xip.uf2`), streaming its ROM from the badge drive (M0 scaffold: console state and stubs, test pattern; `-Dcart-mode=xip`). |
| `carts/demosnout/` | `demosnout` | Demoscene production (was Snouty Scene), 114 s looping: starfield intro, plasma, copper bars and sine scroller, rotozoomer, twister, Iris tunnel, metaballs, voxel island fly-over, low-poly Snouty head, fire, and an ending on the Iris mark reflected in a night sea with credits that melts back into the intro; 120 BPM frame clock, fades and block dissolves between parts, A/Start skips a part, Select opens a part picker, B holds the current part (M3). |
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

## Run in the simulator

The upstream web simulator (`sycl-badge/simulator/`) runs any cart's wasm
build in a browser on your own machine. It needs Node.js 20 or newer and two
terminals, both started from the repository root.

Terminal 1 builds the cart and serves it on `localhost:2468`, where the
simulator looks for it:

```sh
zig build -Dcart=snouty-bugs
node tools/serve-cart.mjs --cart snouty-bugs
```

`--cart` takes a cart directory or binary name from the table above
(`snouty-run` and `snouty` are the same cart). Run from inside
`carts/<cart>/`, the script picks that cart without `--cart`; a wasm path
instead of `--cart` serves any other file. The watcher reloads the page
whenever the wasm changes, so leave it running and re-run `zig build` in
another terminal to see a change. Keep the default port: the simulator only
tries 2468.

Terminal 2 starts the simulator UI (the first run installs its packages):

```sh
cd sycl-badge/simulator
npm install
npm run dev
```

Then open <http://localhost:1234>. To switch carts, stop the watcher, start
it again with another `--cart`, and refresh the browser tab. The simulator
does not reconnect by itself: it shows "Watcher was disconnected" until you
refresh, or "Watcher not found" if the page opened before the watcher started.

| Badge            | Keyboard           |
|------------------|--------------------|
| Joystick         | Arrow keys or WASD |
| Joystick click   | Shift              |
| A                | Z or K             |
| B                | X or J             |
| Start            | Enter or Y         |
| Select           | Backspace or T     |
| System menu      | Escape             |

Each cart's `carts/<cart>/docs/RUNNING.md` lists its own controls, and
`tools/preview.mjs` runs a cart headless in the terminal with no browser,
writing PNG frames (`docs/RUNNING.md` section 5).

## RAM carts, ROMs from the badge drive, and XIP carts

By default a cart is a RAM cart: the OS copies the whole image into the
307 KB cart RAM window and code, read-only data and state share it. This is
the only mode proven on hardware, and it is what the emulator carts use.

The emulator carts do not embed their ROMs. The badge's USB drive is the OS's
`romfs` region of the internal 2 MB flash, so the user copies a ROM file
onto the drive next to the cart's UF2, and at start the cart finds it in the
FAT12 volume and reads ROM bytes by pointer from the flash window. Nothing
is copied or compressed, and the cart stays an ordinary RAM cart. About
800 KB of the 1280 KB drive is left for ROMs once a cart's UF2 is on it;
512 KB ROMs fit, 1 MB ones do not in practice. Eject the drive before
playing, because the OS can write flash while a cart runs. The shared
loader is `lib/romfs.zig`, built by the first cart that needs it; the
design, the hardware checks it still needs and the fallback (packing the
ROM into the cart image) are in `docs/ROM_DRIVE.md`.

With `-Dcart-mode=xip` (or `both`) the same source is also linked as an
execute-in-place cart: code and read-only data live in the badge's 256 KB
cart flash window and run from there through the XIP cache, and all of cart
RAM is left for `.data` and `.bss`. Only a cart whose code plus state
exceeds cart RAM needs it (Snouty Genesis; not Snouty Gear or Snouty Lynx),
and it is untested on hardware. The XIP build is
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
