# Running the Snouty carts

Shared instructions for every cart in this repository. Each cart's own
`carts/<cart>/docs/RUNNING.md` has its previews, input scripts and gates;
[INSTALL.md](INSTALL.md) puts a cart on a badge.

## 0. Quick start: from a fresh machine to a cart in the simulator

Sections 1 to 4 are one copy-paste path. It was walked through in a
fresh clone on Linux x86_64 on 2026-10-02 (without a browser: the UI
server was checked with curl and the cart with `tools/preview.mjs`); on
an Apple-silicon Mac it is the same with the other Zig tarball, not
walked through there. They end with Snouty vs. the Bugs, which needs no ROM, running in
the web simulator in your browser. Every step works for any reader with
access to the repository; the few that depend on the team's exe.dev VM
are marked **team VM only**.

## 1. Prerequisites

Supported: Linux x86_64 and macOS on Apple silicon (aarch64). You need
git, curl and `tar` with xz support (both systems have them), plus:

**Zig `0.17.0`**, the release. Until 2026-10-05 the repository pinned
the nightly `0.17.0-dev.1936+5a625d5f3`; it now uses microzig 0.17.12,
built and tested with the release only. This installs it from
ziglang.org under `~/.local/opt` and works from any directory:

```sh
# Linux x86_64. On an Apple-silicon Mac use instead:
#   ZIG=zig-aarch64-macos-0.17.0
ZIG=zig-x86_64-linux-0.17.0
mkdir -p ~/.local/opt
curl -fL -o ~/.local/opt/$ZIG.tar.xz "https://ziglang.org/download/0.17.0/$ZIG.tar.xz"
tar -xJf ~/.local/opt/$ZIG.tar.xz -C ~/.local/opt
export PATH="$HOME/.local/opt/$ZIG:$PATH"   # put this line (with ZIG=...) in ~/.bashrc or ~/.zshrc too
zig version                                  # must print 0.17.0
```

The Mach community mirror (`https://pkg.machengine.org/zig/$ZIG.tar.xz`)
serves the same files. A build that fails inside `regz` or `translate-c`
with an error about `GlobalLinkage` is a checkout from before the switch
(microzig 0.17.7) built with the release: pull `main`. No cache needs
deleting.

**Node.js 20 or newer** (the simulator and the carts' `tools/`):

```sh
node --version     # v20 or later; if missing: https://nodejs.org, or `brew install node` on a Mac
```

**Python 3 with Pillow**, only for GIF previews and the art pipeline (not
needed to build or to run the simulator). Set it up in section 2, once
the repository is cloned. badge-bench additionally needs Python 3.9+ with
the `venv` module; it makes its own environment on first run.

## 2. Get the code

The repository is private to the `antithesishq` GitHub organisation;
cloning needs a GitHub account with access to it. The upstream SDK is
the public git submodule `sycl-badge/`.

```sh
git clone --recursive git@github.com:antithesishq/snouty-badge.git   # or https://github.com/antithesishq/snouty-badge.git
cd snouty-badge
git submodule update --init      # does nothing after --recursive; fixes a clone made without it
ls sycl-badge/build.zig          # must exist; an empty sycl-badge/ means the submodule is missing
```

**From here on every command runs from the repository root**
(`snouty-badge/`) unless a step says otherwise.

```sh
python3 -m venv .venv && . .venv/bin/activate && pip install Pillow   # optional, see section 1
```

`.venv/` is gitignored; run `. .venv/bin/activate` again in each new
terminal that needs Pillow.

Milestones are annotated tags namespaced by cart (`git tag -n1`):
`snouty-bugs/m5`, `snouty-maze/m4`, and the running cart's `v3.0.0`. The
running cart's tags predate this layout and check out the old single-cart
tree, which needs `../sycl-badge` as a sibling.

## 3. Build

From the repository root:

```sh
zig build -Dcart=snouty-bugs     # one cart; the first build also fetches packages (network) and takes a few minutes
ls zig-out/bin/snouty-bugs.wasm zig-out/firmware/snouty-bugs.uf2
```

More forms:

```sh
zig build                          # every cart, several minutes clean
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
section 8 below.

`zig build test` is the gate before a merge. It runs every cart's host
tests: the shared `lib/` tests, the snouty-boy, snouty-gear, snouty-genesis
and snouty-lynx cores, the snouty-maze, demosnout and snouty-zero modules,
and the snoutenstein sim/levels/parser/rewind/demo suites. Tests that need
downloaded fixtures (the Z80 and 68000 SingleStepTests, ZEXDOC/ZEXALL, the
Lynx test ROMs) report as **skipped**, not passed, when the files are
absent; the strict conformance gates
`zig build test-z80-strict -Dcart=snouty-gear` and
`zig build test-m68k-strict -Dcart=snouty-genesis -Dcart-mode=xip` fail
instead and print the executed case counts (fetch the fixtures with each
cart's `tools/fetch_test_roms.sh` first). `zig build check-float` fails if
a float-heavy cart links soft-float or libm routines; it inspects the ELF
of the selected `-Dcart-mode` (`<binary>.elf`, `<binary>-xip.elf`, or both).
Zig fetches packages into `zig-pkg/` at the root (gitignored).

If building on the Mac fails inside the compiler with `error: OutOfMemory`,
that is a known comptime issue with this Zig. **Team VM only:** the
prebuilt files can be pulled from the team's exe.dev VM instead (needs an
ssh login there):
`scp exedev@animated-badge.exe.xyz:/home/exedev/snouty-badge/zig-out/firmware/<binary>.uf2 .`
(and `zig-out/bin/<binary>.wasm` the same way for the simulator).

## 4. Web simulator

The upstream web simulator (`sycl-badge/simulator/`) runs a cart's wasm
in your browser. It needs two terminals, both started in the repository
root.

Terminal 1 serves the wasm on `localhost:2468`, where the simulator looks
for it, and watches it for changes:

```sh
node tools/serve-cart.mjs --cart snouty-bugs    # serves zig-out/bin/snouty-bugs.wasm
```

`--cart` takes a cart directory or binary name (`snouty-run` and `snouty`
are the same cart); a wasm path instead serves any other file. The
alternative form, used in some cart docs, runs from the cart's directory
and needs no `--cart`: `cd carts/snouty-bugs && node ../../tools/serve-cart.mjs`.
Keep the default port: the simulator only tries 2468.

Terminal 2 starts the simulator UI (the first `npm install` downloads its
packages; a "Browserslist: caniuse-lite is outdated" line from `npm run
dev` is harmless):

```sh
cd sycl-badge/simulator && npm install && npm run dev
```

Open <http://localhost:1234>. Snouty vs. the Bugs waits on its title
card: press Z (the badge's A) to play. Simulator keys (from
`sycl-badge/simulator/README.md`):

| Badge            | Keyboard           |
|------------------|--------------------|
| Joystick         | Arrow keys or WASD |
| Joystick click   | Shift              |
| A                | Z or K             |
| B                | X or J             |
| Start            | Enter or Y         |
| Select           | Backspace or T     |
| System menu      | Escape             |

Each cart's `carts/<cart>/docs/RUNNING.md` lists its own controls.

**Rebuild to reload.** Leave both terminals running, change the cart, and
run `zig build -Dcart=snouty-bugs` in a third terminal at the repository
root. The watcher logs `cart changed, sending reload` and the open tab
restarts the cart.

**When it goes wrong:**

- The page shows **"Watcher not found. Start and reload."**: the page
  opened before terminal 1's watcher was running (or it runs on another
  port). Start it and refresh the tab.
- The page shows **"Watcher was disconnected."**: the watcher stopped.
  Start it again and refresh; the page does not reconnect by itself.
- Terminal 1 says `serving .../snouty-bugs.wasm (does not exist yet)` or
  logs `GET /cart.wasm -> 404`: there is no wasm, so build it
  (`zig build -Dcart=snouty-bugs`). The watcher sends a reload as soon as
  the file appears; refresh the tab if it was showing an error.
- `serve-cart: run from a carts/<cart>/ directory, or pass --cart NAME or
  a wasm path`: you ran it from the repository root without `--cart`.
- To switch carts, stop the watcher, start it with another `--cart`, and
  refresh the tab.

Every cart carries wasm-only shims (`present_wasm()`, `read_controls()`)
because upstream's simulator reads a legacy framebuffer at 0x20 with red and
blue swapped and writes buttons to 0x04; the carts' CLAUDE.md files explain.

No browser at hand: `node tools/preview.mjs zig-out/bin/snouty-bugs.wasm
--frames 60 --out out/bugs` runs the same wasm headless and writes PNG
frames (section 5).

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
