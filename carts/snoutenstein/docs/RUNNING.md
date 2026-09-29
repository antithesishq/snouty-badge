# Running the Snoutenstein 3D cart

Commands below run from this cart's directory (`carts/snoutenstein/`) unless
noted; `zig build` runs from the repository root, two levels up, and writes its
outputs to `../../zig-out/`.

## 1. Prerequisites

See `../../docs/RUNNING.md` at the repository root (Zig version and download,
Node.js, Python with Pillow for GIF previews).

## 2. Checkout layout

This cart lives in `carts/snoutenstein/` of the snouty-badge repository; the
upstream SDK is the `sycl-badge/` submodule at the repository root. See
`../../docs/RUNNING.md` for cloning with the submodule. To review a milestone
from the exe.dev VM on another machine:

```sh
git clone -b monorepo exedev@animated-badge.exe.xyz:/home/exedev/snouty-badge
cd snouty-badge && git submodule update --init
```

Milestones are annotated tags `snoutenstein/m0`..`snoutenstein/m3`
(`git tag -n1 'snoutenstein/*'`; `git checkout snoutenstein/m3` builds that
milestone). From the exe.dev VM the GitHub remote
(`git@github.com:antithesishq/snouty-badge.git`) is reached through the GitHub
integration host `github.int.exe.xyz`.

## 3. Build

From the repository root:

```sh
zig build -Dcart=snoutenstein   # or plain `zig build` for every cart
```

This writes, at the repository root:

- `zig-out/firmware/snoutenstein.uf2` (for the badge)
- `zig-out/firmware/snoutenstein.elf`
- `zig-out/bin/snoutenstein.wasm` (for the simulator)

Levels live in `cart/src/levels/*.txt` and are compiled into
`cart/src/levels/gen.zig` by `tools/gen_levels.sh`, which is committed. After
editing or importing a level, run the script and commit both files.

Without a local toolchain, the VM's build artifacts can be pulled into the
same locations and everything below works unchanged:

```sh
mkdir -p ../../zig-out/firmware ../../zig-out/bin
scp exedev@animated-badge.exe.xyz:snouty-badge/zig-out/firmware/snoutenstein.uf2 ../../zig-out/firmware/
scp exedev@animated-badge.exe.xyz:snouty-badge/zig-out/bin/snoutenstein.wasm ../../zig-out/bin/
```

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd carts/snoutenstein                # from the repository root
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/snoutenstein.wasm on :2468
# or: node ../../tools/serve-cart.mjs path/to/other.wasm --port 2468
```

This serves `http://localhost:2468/cart.wasm` (with CORS) and
`ws://localhost:2468/ws`. When the file changes, which happens after every
`zig build`, it sends `reload` to the page.

Terminal 2 runs the simulator UI:

```sh
cd ../../sycl-badge/simulator
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
node ../../tools/preview.mjs ../../zig-out/bin/snoutenstein.wasm --frames 240 --every 4 --out out/
python3 ../../tools/make_gif.py out/ preview.gif --scale 3 --ms 66
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
- `--quiet`: write no PNGs, only `frames.json` (fast soak runs)
- `--raw-colors`: decode colors as the cart API defines them instead of as the
  simulator displays them (only matters for carts that do not pre-swap)

Input scripts live in `tools/scripts/` (A at tick 10 leaves the title
screen; turns are 36 ticks = 90 degrees, walking 0.045 cells per tick):

- `m1_walk.json` (2,151 ticks, run 2,160 frames): through the plain door
  (7,4), up the x 8 corridor, east along row 1, down x 16, west along
  row 8, down x 1, then stands 60 ticks at (1.5, 22.5) facing east down
  the long bottom corridor (the render-time gate view), walks 18 cells of
  it, turns around and walks back. `debug_px > 393216` already holds from
  tick 250 on; at 2,160 frames expect px about 14.3 cells, py about 22.6.
- `m1_doors.json` (600 frames): lines up with the door row, walks into the
  closed door at (7,4), stands 40 ticks while it opens, walks through to
  (8.5, 4.5), turns around, waits 200 ticks for it to close, bumps it once
  from the corridor side and watches it reopen. Ends at px 8.25 (540672).
- `m1_pause.json` (600 frames): walks 30 ticks, START at 41, holds UP for 60
  paused ticks (nothing may move), START at 102, walks and turns again.
  Ends playing at px about 6.2; without a working pause the wall would stop
  it at 6.75, so `--expect "debug_px < 425984"` checks the pause.
- `m2_combat.json` (240 frames): from the start, holds A at 30..45 so the
  zapper fires twice (cooldown 12): the first shot kills the gnat three
  cells ahead, the second hits nothing. SELECT at 90 skips the empty spray
  and lands on the swatter, A at 110..125 swings it at nothing, SELECT at
  150 goes back to the zapper, then a short walk. Expect `debug_kills == 1`,
  `debug_weapon == 1`, `debug_ammo == 38`.
- `m2_exit.json` (1,400 frames): lines up with the door row, through the
  plain door (7,4), up the x 8 corridor, east along row 1 to x 31, south
  into the exit door at (31,8). The level ends, the intermission card shows
  for 60 ticks, A at 1300 starts E1M1 (level index 4). Expect `debug_level == 4`
  and `debug_mode == 1`.

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snoutenstein.wasm --frames 2160 --every 6 --out out/walk \
  --script tools/scripts/m1_walk.json \
  --dump-exports debug_mode,debug_tick,debug_px,debug_py,debug_render_us \
  --expect "debug_mode == 1" --expect "debug_px > 393216"
node ../../tools/preview.mjs ../../zig-out/bin/snoutenstein.wasm --frames 600 --quiet --out out/pause \
  --script tools/scripts/m1_pause.json --expect "debug_mode == 1" --expect "debug_px < 425984"
```

An unknown or non-zero-argument export name is an error that lists the
exports the cart has. Exit codes: 1 the cart cannot be loaded or does not
export `start`/`update`, 2 usage or script error, 3 the cart trapped or an
expectation failed. `make_gif.py` scales frames with nearest-neighbor. One
update is one 60 Hz tick, so `--every 4 --ms 66` plays at about real speed.

### Determinism check

`tools/check_determinism.mjs` runs the same scripted game twice through
`preview.mjs --quiet` and asserts that the listed exports (default
`debug_state_hash,debug_tick`; `debug_state_hash` is the FNV-1a hash of the
whole `GameState`) are identical after the last update. It prints one line,
`NAME=VALUE` per export (`NAME=RUN1|RUN2` where they differ), and exits 0 on
a match, 3 on a mismatch or a failed run, 2 on a usage error.
`debug_desync` (the rewind self-check's mismatch count) is always compared
too when the wasm exports it.

`--rewind-at T --rewind-for N` (update indices, 0-based, `T + N < --frames`)
proves a rewound state is the state that was live back then. Run 1 plays
the script unchanged and samples `debug_tick` and `debug_gameplay_hash`
after every update in `[max(0, T-1-N), T-1]`. Run 2 appends a B hold over
updates `T..T+N-1` to a temp copy of the script (exit 2 if the script
already holds B there) and samples after the release update `T+N`. It
passes when run 2 is playing (`debug_mode == 1`) with `debug_rewinds >= 1`,
its tick is one run 1 showed, the two `debug_gameplay_hash` values agree,
and `debug_desync == 0` at the end of both runs. The line reports how far
the rewind went (shorter than N when the meter or the history runs out).

```sh
node tools/check_determinism.mjs ../../zig-out/bin/snoutenstein.wasm \
  --script tools/scripts/m2_combat.json --frames 240 --exports debug_state_hash,debug_tick,debug_kills
# check_determinism: PASS m2_combat.json x240: debug_state_hash=... debug_tick=229 debug_kills=1 debug_desync=0
node tools/check_determinism.mjs ../../zig-out/bin/snoutenstein.wasm \
  --script tools/scripts/m1_walk.json --frames 600 --rewind-at 200 --rewind-for 90
# check_determinism: PASS m1_walk.json x600 rewind@200+90: rewound from tick 189 to tick 99, 90 ticks; debug_gameplay_hash=... debug_rewinds=1 debug_desync=0|0
```

### Attract mode and the recorded demo

Left alone on the title for 10 s (600 ticks), the cart plays a recorded
demo of Build Farm: `sim.init` of level 0 with a fixed seed, driven by an
input log baked into the cart (`cart/src/demos/build_farm.zig`) instead of
the pad. A blinking "DEMO" sits at the top of the view while it runs. Any
edge on A, B, Start or the joystick (up, down, left, right) takes over on
the spot: the demo stops without stepping that tick, the rewind meter is
refilled, and the controls are live from the next tick. Select is ignored
during the demo. The demo returns to the title when the log runs out, after
3 minutes, after 2 s dead, or once an intermission or victory card has
shown.

When the log runs to the end, the cart compares `sim.hash_gameplay` of the
final state with the hash recorded in the simulator and shows the result
at the top left of the title: "DEMO OK" (grey) means the badge replayed the
log bit-identically to the simulator, "DEMO DESYNC" (Coral) means it did
not (a determinism bug; SPEC.md 9.3). Nothing is shown before a demo has
finished, or when the data file has no recorded hash (`final_hash` 0).

Exports: `debug_demo` (1 while the demo drives), `debug_demo_result` (0
none, 1 ok, 2 desync), `debug_title_ticks` (ticks idled on the title). Two
setup calls for `preview.mjs --call`: `--call debug_start_demo` starts the
demo at update 0 (scripts and the bench), `--call debug_new_game_seeded`
starts Build Farm with the demo seed in normal play, tick 0 = update 0
(authoring the log).

```sh
# replay the embedded demo headless; T = total_ticks in cart/src/demos/build_farm.zig
T=$(sed -n 's/.*total_ticks: u32 = \([0-9]*\);.*/\1/p' cart/src/demos/build_farm.zig)
node ../../tools/preview.mjs ../../zig-out/bin/snoutenstein.wasm --call debug_start_demo \
  --frames $((T + 5)) --every 60 --out out/ --expect "debug_demo_result == 1"
```

Recording a demo: the playthrough is authored as a normal input script,
`tools/scripts/demo_build_farm.json` (`{from, to, hold}` entries, tick 0 is
the first `sim.step` of the level; the demo ends after `max(to)`, or after
`"tail": K` idle ticks when the file is `{"tail": K, "runs": [...]}`).
Iterate on it with `preview.mjs --call debug_new_game_seeded --script
tools/scripts/demo_build_farm.json`, no rebuild needed. Then:

```sh
tools/record_demo.sh     # plays the script on the built wasm, reads debug_gameplay_hash, regenerates the data file with --hash
cd ../.. && zig build -Dcart=snoutenstein && cd carts/snoutenstein
tools/check.sh           # proves the embedded demo reproduces the hash in demo mode
```

`tools/record_demo.sh` builds nothing: it runs `preview.mjs` on the
existing wasm and calls the generator, which can also be run by hand:
`python3 tools/gen_demo.py IN.json --out cart/src/demos/build_farm.zig
[--hash 0x...]`. It encodes the script with the same button bits as
`preview.mjs`, merges identical ticks into `Run { buttons, ticks }` and
writes plain literal data (`level_index`, `seed`, `total_ticks`,
`final_hash`, `runs`); without `--hash` the hash is 0 (unrecorded). Commit
the JSON and the regenerated `.zig` together.

Demo content: 3,627 ticks (60.5 s), Build Farm with the zapper (tuned
for the post-M5 balance: gnats bite 4 HP every 40 ticks). Snouty walks
the rack corridor east, opens the plain door at (11,3) and zaps the three
cable-tray gnats from the doorway (one bite taken), walks past the zapper
charge at (16,4), clears the two hub gnats from the door at (17,7),
crosses the hub, opens the vent closet door at (7,10), grabs the Coral
key at (3,9) (the portrait grins), zaps the closet gnat after two bites,
takes the hotfix at (2,11) back to 100 HP, then walks back across the hub
(Select to the swatter and back on the way) and through the Coral door at
(15,13) into the pipe hall. There it stands in the open while the three
pipe-hall gnats bite it down to 32 HP, holds B for updates 1961-2200 (240
ticks, 4 s of Iris rewind; game tick 1961 back to 1721, HP 92), backs
into the Coral doorway and zaps two gnats as they line up, steps out and
turns east to zap the third, then tours the hall (west end, a look at the
Iris mural on the south wall) and ends standing at (19.0,16.5) facing the
exit strip, alive, 88 HP, 9 kills, never touching the exit. Recorded hash
`0x093CA09A` (final game tick 3146). After any change that moves the
simulation (balance, AI, map, rewind), the gnats wake and move
differently and the log goes stale: edit `tools/scripts/demo_build_farm.json`
(author with `--call debug_new_game_seeded` and `--call-at T debug_px`
etc. as above, check HP, kills and position at the milestones), run
`tools/record_demo.sh`, rebuild, then `tools/check.sh` (the attract,
demo and takeover runs must pass). Changing an early segment reshuffles
every fight after it, so re-check the whole run, not just the edit.

Neopixels are off in every build (docs/NEOPIXELS.md at the repository
root): the cart never writes a non-zero LED byte; the HP bar, key flash
and rewind pulse in `cart/src/audio.zig` are compiled out.
`zig build -Dcart=snoutenstein -Dneopixels=true` (repository root)
re-enables them for development; `tools/check.sh` builds that variant
once so the path keeps compiling. Never flash it to a badge you look at.

## 6. Flash the badge

1. Connect the badge over USB-C. It shows up as a USB mass-storage drive.
2. Copy `zig-out/firmware/snoutenstein.uf2` (at the repository root) onto the drive, replacing `CURRENT.UF2`.
