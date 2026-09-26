# Running the Snouty vs. the Bugs cart

## 1. Prerequisites

- git
- Zig **0.17.0-dev.1936+5a625d5f3** exactly (upstream sycl-badge pins it). Nightly
  tarballs are named `zig-<arch>-<os>-<version>.tar.xz`; the Linux x86_64 one is
  <https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1936+5a625d5f3.tar.xz>.
  Nightlies rotate off ziglang.org; if the URL 404s, try the machengine.org
  mirror or `zigup`. Unpack it and put the `zig` binary on `PATH`.
- Node.js 20 or newer (for the simulator and the tools in `tools/`)
- Optional, for GIF previews: Python 3 with Pillow

## 2. Checkout layout

The two repos must be siblings. `build.zig.zon` points at `../sycl-badge`, and
`src/os/system/tracy_protocol.zig` is a symlink into it.

```
work/
  sycl-badge/     git clone https://github.com/ZigEmbeddedGroup/sycl-badge.git
  snouty-bugs/   git clone git@github.com:antithesishq/snouty-bugs.git
```

Milestones are annotated tags (`git tag -n1`). From the exe.dev VM the remote is reached through the GitHub
integration host `github.int.exe.xyz`.

## 3. Build

```sh
cd snouty-bugs
zig build
```

This writes:

- `zig-out/firmware/snouty-bugs.uf2` (for the badge)
- `zig-out/firmware/snouty-bugs.elf`
- `zig-out/bin/snouty-bugs.wasm` (for the simulator)

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd snouty-bugs
node tools/serve-cart.mjs            # serves zig-out/bin/snouty-bugs.wasm on :2468
# or: node tools/serve-cart.mjs path/to/other.wasm --port 2468
```

This serves `http://localhost:2468/cart.wasm` (with CORS) and
`ws://localhost:2468/ws`. When the file changes, which happens after every
`zig build`, it sends `reload` to the page.

Terminal 2 runs the simulator UI:

```sh
cd ../sycl-badge/simulator
npm install
npm run dev
```

Then open <http://localhost:1234>.

Hosted alternative: <https://badgesim.microzig.tech/> also fetches from
`localhost:2468`, so it should work with the watcher from terminal 1 (Chrome
treats `localhost` as secure). This has not been verified; if it doesn't
load, use the local UI.

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

Known upstream simulator quirks (current sycl-badge `main`):

- The simulator only shows a fixed region of wasm memory (address 0x20). The
  cart API draws somewhere else, so our cart copies each frame to 0x20 itself
  (`present_wasm()` in `cart/src/main.zig`). Upstream demo carts such as
  `dvd.wasm` show a blank or garbage screen.
- Buttons are written to an address (0x04) the current cart API no longer
  reads, so upstream carts get no input in the simulator. Our cart reads that
  address itself in wasm builds (`read_controls()` in `cart/src/main.zig`), so
  Z or K (the A button) fires in the simulator as on hardware.
- The WebGL compositor reads red from the bits where the current cart API
  stores blue, so it shows current-API carts with red and blue swapped. Our
  `present_wasm()` pre-swaps when it copies the frame to 0x20, so the browser
  shows the intended colors. If the Coral title text ever looks blue, that swap and the
  simulator have gotten out of step (`sim_swap_rb` in `cart/src/main.zig`).

## 5. Headless preview (no browser)

```sh
node tools/preview.mjs zig-out/bin/snouty-bugs.wasm --frames 240 --every 4 --out out/
python3 tools/make_gif.py out/ preview.gif --scale 3 --ms 66
```

`preview.mjs` runs `start()` and then `update()` N times, writing every K-th
frame to `out/frame_XXXX.png` along with `out/frames.json` (metadata:
framebuffer address and source, inputs, export values, expectation results,
warnings). Other options:

- `--start-skip S`: skip the first S updates
- `--fb-addr auto|dwarf|sim|0xADDR`: choose which framebuffer to dump
- `--seed N`: seed for `rand()`
- `--controls BITS`: raw `cart.Controls` bits held for the whole run
- `--press A:30-31,UP:60-99,START:300-301`: hold buttons during those update
  ranges (inclusive). Buttons are `A B START SELECT UP DOWN LEFT RIGHT`, any
  case; a bare `60-63` means A. `CLICK` is refused (the OS owns it).
- `--script FILE.json`: a JSON array of
  `{ "from": 60, "to": 99, "hold": ["A", "UP"] }` entries, inclusive. Inputs
  from `--controls`, `--press` and `--script` are OR-ed per tick.
- `--dump-exports debug_state,debug_score`: after the last update, call these
  zero-argument exports and record the results (as i32) in `frames.json`
  under `exports` and on stderr
- `--expect "debug_score > 0"` (repeatable; `== != < <= > >=`, integer value):
  checked against those exports at the end (the name is dumped
  automatically); prints PASS/FAIL, and any failure exits 3
- `--at "1799 debug_score > 0"` (repeatable): the same check, made right after
  update T (0-based, so with `--frames 1800` tick 1799 is the moment the
  end-of-run exports are read) instead of at the end. Results go to
  `frames.json` under `at` (`tick, name, op, value, actual, pass`); any
  failure exits 3 after `frames.json` is written
- `--call-at "900 debug_score"` (repeatable): call the export right after
  update T and record `{tick, name, value}` under `calls` in `frames.json` and
  on stderr (for comparing two runs tick by tick). Items that share a tick run
  in command-line order. Both flags also take separate arguments
  (`--at 1799 debug_score '>' 0`, `--call-at 900 debug_score`); the quoted form
  saves quoting the operator. A T at or beyond N is a usage error
- `--quiet`: write no PNGs, only `frames.json` (fast soak runs)
- `--raw-colors`: decode colors as the cart API defines them instead of as the
  simulator displays them (only matters for carts that do not pre-swap)

Input scripts live in `tools/scripts/`: `m1_play.json` presses A on the title
at tick 30, then from tick 60 to 1800 holds A while sweeping up 40 ticks,
nothing 20, down 40, nothing 20. `m1_pause.json` starts the game, fires
60-300, presses START at 300 and 420 (pause, unpause), then fires 430-600.
The M2 scripts:

- `m2_play.json`: the preview GIF script. A on the title at 30, then holds A
  without moving through the opening gnat strings (60 to 239), then sweeps up
  40 ticks / holds 20 / down 40 / holds 20 until 3960, with B (bomb) at 2240
  and 3380. It must still be playing at 4000 with all three rewinds and both
  bombs spent, and the score must beat M1's 570.
- `m2_bomb.json`: starts at 30, then sits still without firing so the 8 s
  beetle survives and fires; presses B at 720. There must be bullets at 719,
  none at 720, and one bomb left.
- `m2_hit.json`: starts at 30 and does nothing else for 1000 ticks; the
  beetle's aimed spreads hit the still ship at about 750 and 900, spending
  rewinds (one left, still playing).
- `m2_death.json`: the same input for 6000 ticks; every rewind is spent, the
  ship dies and the game is back on the title at the end.

```sh
node tools/preview.mjs zig-out/bin/snouty-bugs.wasm --frames 1800 --every 6 --out out/ \
  --script tools/scripts/m1_play.json \
  --dump-exports debug_state,debug_score,debug_lives,debug_enemies \
  --expect "debug_state == 1" --expect "debug_score > 0"
node tools/preview.mjs zig-out/bin/snouty-bugs.wasm --frames 18000 --quiet --out out/soak/ \
  --script tools/scripts/m1_play.json --dump-exports debug_state,debug_score
```

An unknown or non-zero-argument export name is an error that lists the
exports the cart has. Exit codes: 1 the cart cannot be loaded or does not
export `start`/`update`, 2 usage or script error, 3 the cart trapped or an
expectation (`--expect` or `--at`) failed. `make_gif.py` scales frames with
nearest-neighbor. One update is one 60 Hz tick, so `--every 4 --ms 66` plays
at about real speed.

### Regression gate: `tools/check.sh`

```sh
tools/check.sh                 # zig build, then every tools/scripts/*.json
tools/check.sh --no-build --only m2_bomb
CART_WASM=path/to/other.wasm tools/check.sh --no-build
```

Each `tools/scripts/NAME.json` runs as
`node tools/preview.mjs zig-out/bin/snouty-bugs.wasm --script NAME.json --quiet --out out/check/NAME ...`,
where `...` comes from the sidecar `NAME.args`: preview arguments (`--frames`,
`--dump-exports`, `--expect`, `--at`, `--call-at`) quoted as on a command line.
Lines starting with `#` are comments (each M2 sidecar has a `# tune` line
saying which of its numbers are still guesses); the other lines are joined. A
script without a sidecar runs with `--frames 600`. It prints one line per
script, PASS or FAIL with the exported values and any failed checks, keeps the
full stderr in `out/check/NAME/preview.log`, and exits 1 if any script failed.
`CART_WASM` points it at another build. From M2 on this is the gate before a
commit: add a script and its sidecar for every new behaviour worth keeping.

## 6. Flash the badge

1. Connect the badge over USB-C. It shows up as a USB mass-storage drive.
2. Copy `zig-out/firmware/snouty-bugs.uf2` onto the drive, replacing `CURRENT.UF2`.
