# Snouty carts

Antithesis's carts for the SYCL Badge V2 (the Software You Can Love conference
badge), plus the tools used to make and measure them. One Zig build produces
every cart; each cart has its own directory with its design, plan, assets and
tools.

## Carts: what works today

Sourced by hand from the cart registration in the root `build.zig` and each
cart's `PLAN.md` (milestone history and benchmark numbers live there, not
here). Mode: **RAM** is the usual cart, copied into the 307 KB cart RAM
window; **XIP** runs code from the 256 KB cart flash window
(`<binary>-xip.uf2`, section below); **XIP only** carts have no RAM build.
"Booted on a badge" means the 2026-09-29 smoke pass: a coworker built
`main` at `b9abad4` and launched every cart it had, a boot check, not a
play test; later commits are unchecked, and no XIP build is confirmed to
have run on a badge.

| Cart (`-Dcart`) | Binary | What it is | Maturity | Mode | Known limits | On a badge |
|---|---|---|---|---|---|---|
| `snouty-run` | `snouty` | Snouty runs past a Green Hill Zone waterfall, A jumps; name panel | v5 built (tag `v3.0.0`) | RAM | passive demo, no sound | booted 2026-09-29, not play-tested |
| `snouty-bugs` | `snouty-bugs` | bullet-hell shooter with rewind-on-hit | M5 done | RAM | no attract demo yet (SPEC M6): waits on its title card | booted 2026-09-29, not play-tested |
| `snoutenstein` | `snoutenstein` | raycaster FPS with time rewind | M6 done | RAM | weapon feel and boss balance unchecked on hardware | booted 2026-09-29 (at M5.1), not play-tested |
| `snouty-reflections` | `snouty-reflections` | real-time ray tracer over water; A freezes into a path tracer | M4 done | RAM | locked to 20 fps (shipped `cut20` variant) | booted 2026-09-29 (at M2), not play-tested |
| `snouty-boy` | `snouty-boy` | Game Boy and Game Boy Color emulator with time scrubber | M8 done (tag `snouty-boy/m6`) | RAM (XIP optional) | saves not kept; an embedded ROM over ~64 KB needs XIP | booted 2026-09-29, not play-tested |
| `snouty-maze` | `snouty-maze` | Windows 3D Maze screensaver on a software rasterizer | M4 done | RAM | none recorded | booted 2026-09-29, not play-tested |
| `snouty-gear` | `snouty-gear` | Game Gear emulator with time scrubber | M3 done | RAM (XIP optional) | an embedded ROM over ~128 KB stops the badge ELF linking | booted 2026-09-29 (at M2), not play-tested |
| `snouty-genesis` | `snouty-genesis` | Genesis / Mega Drive emulator with time scrubber, 30 Hz | M4 done | XIP only | drive ROMs up to ~900 KB; no SVP, no mapper over 4 MB | not confirmed: was in the 2026-09-29 build (at M1), but as XIP |
| `snouty-lynx` | `snouty-lynx` | Atari Lynx emulator with time scrubber | M4 done | RAM, plus XIP built by default | scrubber holds 1-2 s in the RAM cart (3-6 s in the XIP one) | not yet |
| `snouty-flyover` | `snouty-flyover` | voxel flyover through a landscape of data structures | M4.1 done | RAM | locked to 30 fps | not yet |
| `demosnout` | `demosnout` | demoscene production, 114 s loop | M3 done | RAM | silent by design | not yet |
| `snouty-zero` | `snouty-zero` | F-Zero style Mode 7 hover racer | M5 done | XIP only | needs `-Dcart-mode=xip` when named with `-Dcart` | not yet |
| `badge-calibrate` | `badge-calibrate` | hardware calibration cart for badge-bench (`badge-bench/calibrate/`) | C3 done (badge fit applied) | RAM | a tool, not a game | ran on a badge 2026-09-28 (`badge-2026-09-28-pass5.txt`) |

ROMs for the emulator carts. Every one embeds a freely licensed fallback
ROM, which the simulator always runs (it has no badge drive); the badge
build prefers a ROM file on the badge drive and falls back to the embedded
one. How to copy ROMs onto the drive: [docs/INSTALL.md](docs/INSTALL.md)
and the section linked per cart.

| Cart | Embedded fallback | Build options | Drive files | Details |
|---|---|---|---|---|
| `snouty-boy` | `tests/roms/dmg-acid2.gb` once `tools/fetch_test_roms.sh` has run, else `roms/2048.gb` | `-Drom=PATH` (repository- or cart-relative), `-Drom-source=drive\|embed` | `.gb`, `.gbc` up to 1 MB; a picker for several | [RUNNING section 9](carts/snouty-boy/docs/RUNNING.md#9-roms-from-the-badge-drive) |
| `snouty-gear` | `roms/waternet.gg` (MIT) | `-Dgg-rom=PATH` (`~/`, absolute, repository- or cart-relative), `-Dgg-rom-source=drive\|embed` (`pack` not built yet) | `.gg`, `.sms`; the first one found plays | [RUNNING section 6](carts/snouty-gear/docs/RUNNING.md#6-a-rom-on-the-badge-drive) |
| `snouty-genesis` | `roms/snouty-test.bin` (16 KB test ROM) | `-Dmd-rom=PATH` (`~/`, absolute, repository- or cart-relative), `-Dmd-rom-source=drive\|embed` | `.gen`, `.md`, `.bin`; a picker for several; SMD-interleaved files refused | [RUNNING section 8](carts/snouty-genesis/docs/RUNNING.md#8-a-rom-on-the-badge-drive) |
| `snouty-lynx` | `roms/raycast.lnx` (Apache-2.0) | `-Dlynx-rom=PATH` (`~/`, absolute, repository-relative), `-Dlynx-rom-source=drive\|embed` (`pack` not built yet) | `.lnx`, headerless `.lyx`; a picker for several | [README](carts/snouty-lynx/README.md#a-rom-on-the-badge-drive) |

Other directories:

| Directory | What it is |
|---|---|
| `tools/` | Shared cart tools: `preview.mjs` (headless wasm runner with input scripts and checks), `serve-cart.mjs` (feeds the web simulator), `make_gif.py`, `check_float.mjs`, `uf2_info.py`. |
| `badge-bench/` | Emulated Cortex-M33 cycle benchmark for any cart ELF, with per-cart defaults and hot-function lists ([README](badge-bench/README.md)). |
| `badge-manager/` | Raspberry Pi badge station for the expo: deploy cart sets from a phone ([README](badge-manager/README.md)). |
| `snouty-art/` | Code-driven pixel-art pipeline (parts rig, procedural limbs) that produces the carts' sprite sheets. |
| `sycl-badge/` | Upstream badge SDK and simulator, a git submodule pinned to the commit the carts are built against. |
| `carts/snouty-nes/` | Notes for a possible NES cart; nothing to build. |

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

Outputs: `zig-out/firmware/<binary>.uf2` (for the badge, installed as in
[docs/INSTALL.md](docs/INSTALL.md)), `zig-out/firmware/<binary>.elf` (for badge-bench) and
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
307 KB cart RAM window and code, read-only data and state share it. Snouty
Boy, Snouty Gear and Snouty Lynx are RAM carts like the native ones;
Snouty Genesis and Snouty Zero are XIP only (below).

Each emulator cart embeds a small, freely licensed fallback ROM and, on the
badge, prefers a ROM file on the badge drive. The drive is the OS's
`romfs` region of the internal 2 MB flash, so the user copies a ROM file
onto it next to the cart's UF2, and at start the cart finds it in the
FAT12 volume and reads ROM bytes by pointer from the flash window. Nothing
is copied or compressed, so a drive ROM costs no cart RAM. About 800 KB of
the 1280 KB drive is left for ROMs once a RAM cart's UF2 is on it; 512 KB
ROMs fit, 1 MB ones do not in practice. Eject the drive before playing,
because the OS can write flash while a cart runs. The shared loader is
`lib/romfs.zig`; the design, the hardware checks it still needs and the
fallback (packing the ROM into the cart image) are in
[docs/ROM_DRIVE.md](docs/ROM_DRIVE.md).

With `-Dcart-mode=xip` (or `both`) the same source is also linked as an
execute-in-place cart: code and read-only data live in the badge's 256 KB
cart flash window and run from there through the XIP cache, and all of cart
RAM is left for `.data` and `.bss`. A cart needs it when its code plus
state exceeds cart RAM: Snouty Genesis and Snouty Zero build only that way
(a plain `zig build` builds their XIP carts anyway; naming them with
`-Dcart` needs `-Dcart-mode=xip`), Snouty Lynx builds both by default for
its longer scrub history, and Snouty Boy needs it only for a big embedded
ROM. XIP carts are not yet confirmed on hardware. The XIP build is
`zig-out/firmware/<binary>-xip.uf2`, installed the same way.
`tools/uf2_info.py` shows which window a UF2 targets (the loader refuses a
mix). Root `PLAN.md` section M3 has the design and the open hardware
questions.

## Where to read next

- `PLAN.md` at the root: the repository plan (the move to one repository).
  Each cart's own `PLAN.md` and `SPEC.md` hold its design and milestone status.
- `CLAUDE.md` at the root: shared hardware, cart API and build notes; each
  cart's `CLAUDE.md` adds what is specific to it.
- `carts/<cart>/docs/RUNNING.md`: how to preview, test and flash that cart.
- `badge-bench/README.md`: how to cost a cart before flashing it.
