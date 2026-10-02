# Running the Snouty vs. the Bugs cart

Commands below run from this cart's directory (`carts/snouty-bugs/`) unless
noted; `zig build` runs from the repository root, two levels up, and writes its
outputs to `../../zig-out/`.

## Controls

Play first, tooling after. Badge buttons, then the simulator keys
(section 4 has the full key table; the joystick is the arrow keys or
WASD, so the `A` key is joystick left, not the A button).

| Where | Badge | Simulator | Does |
|---|---|---|---|
| Title | A or Start | Z or K / Enter or Y | Normal game: a hit rewinds automatically while rewind heads last (HUD, right: 3 to start, more from 10,000 points, at most 5); with none left a hit ends the game |
| Title | B | X or J | Hardcore game: no heads, a hit is paid from the fuel bar, a hit below 45 fuel ends the game |
| Playing | Joystick | Arrows or WASD | Fly |
| Playing | Hold A | Hold Z or K | Fire |
| Playing | Hold B | Hold X or J | Rewind the world 2 ticks per frame, paid from the fuel bar (refills slowly, and per graze); release to play on |
| Playing | Start | Enter or Y | Pause; the pause screen lists these controls; Start again resumes |
| Anywhere | Hold Start + Select 0.5 s | (none) | Badge OS stops the cart and returns to its cart list |
| Anywhere | Joystick click | Shift | Badge OS FPS overlay; the cart ignores it |
| Simulator only | | Escape | Simulator menu (Continue, Save/Load state, Reset cart, ...); it freezes the cart and is not the badge OS |

No sound toggle: the cart makes no sound yet, so Select does nothing (it
will toggle sound once audio lands; [docs/SOUND.md](../../../docs/SOUND.md)).
There is no bomb and, as yet, no attract mode: the title waits for a press.
After a game ends the cart returns to the title.

## Powerups (M6)

Bugs drop crates: a Memory Leak beetle shot down, every fifth gnat shot
down, and the Heisenbug each time its fire pattern changes (a bug rammed
by the ship drops nothing). A crate is a 16x16 chamfered box with one bold
glyph that drifts left at half a pixel per tick on a gentle bob and leaves
at the left edge; up to four are on screen. Fly into it to collect it: any
overlap with the whole ship sprite counts, not just the small hitbox.
Every crate scores 100.

| Crate | Looks like | Grants |
|---|---|---|
| F (FUZZER) | Coral, white `F` | The default zapper, upgraded: single, twin, 3-way, 5-way, 5-way with random spread |
| A (ASSERT) | Teal, white `A` | Fast beams that go through every bug in their row: 1 beam, more damage, 2 beams, more damage, 3 beams |
| B (BISECT) | Green, white `B` | Homing seekers, 1 to 5, steering tighter per level |
| FORK | Purple, white Y-shaped branch | A ghost ship (dithered, no thruster) that replays your own path from 24 ticks ago and fires wherever you fired then; up to three, 24 ticks apart. Ghosts cannot be hit and collect nothing |
| RETRY | Cream, Coral shield | A one-hit shield, shown as a small shield icon above the ship. The next hit is absorbed: `FLAKY, RETRYING`, the bullet or bug that hit you vanishes, a moment of invulnerability (the ship blinks), and no rewind head or fuel is spent |
| CORE HOURS | Yellow, CPU chip | A third of the fuel bar (60) at once, up to full |

A weapon crate of the kind you already fire adds a level (1 to 5); a
crate of another kind switches weapon and keeps the level. At level 5, a
fourth fork or a second shield the crate scores 500 instead. The crates
come in a fixed order, no randomness: your current weapon, core hours,
your weapon, fork, the next weapon kind (F, then A, then B, then F), retry,
your weapon, fork, and round again, so stacking is the default and a swap
is on offer every eight crates. A new game starts at F1, the plain zapper.

The HUD's status slot, between the score and the fuel bar, shows the
weapon as its letter and level (`F1`, `A3`, `B5`); during a rewind it
shows `<<` instead.

Everything a crate gives belongs to the world, so a rewind (the automatic
one after a hit, or hold-B) that goes back past a collection takes it away
again: the weapon drops back a level, a fork or the shield is gone, and the
crate is back on screen to be grabbed a second time. Core hours pay once:
fuel is not part of the world, so the rewind does not take it back, and a
core hours crate rewound away and collected again pays nothing more.

## 1. Prerequisites

See `../../docs/RUNNING.md` at the repository root (Zig version and download,
Node.js, Python with Pillow for GIF previews).

## 2. Checkout layout

This cart lives in `carts/snouty-bugs/` of the snouty-badge repository; the
upstream SDK is the `sycl-badge/` submodule at the repository root. See
[`docs/RUNNING.md`](../../../docs/RUNNING.md) section 2 for cloning
with the submodule.

Milestones are annotated tags `snouty-bugs/m1`..`snouty-bugs/m5`
(`git tag -n1 'snouty-bugs/*'`). From the exe.dev VM the GitHub remote
(`git@github.com:antithesishq/snouty-badge.git`) is reached through the GitHub
integration host `github.int.exe.xyz`.

## 3. Build

From the repository root:

```sh
zig build -Dcart=snouty-bugs    # or plain `zig build` for every cart
```

This writes, at the repository root:

- `zig-out/firmware/snouty-bugs.uf2` (for the badge)
- `zig-out/firmware/snouty-bugs.elf`
- `zig-out/bin/snouty-bugs.wasm` (for the simulator)

## 4. Web simulator

Terminal 1 serves the cart and live-reloads it:

```sh
cd carts/snouty-bugs                 # from the repository root
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/snouty-bugs.wasm on :2468
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

In the game, A fires, the joystick flies and Start pauses. B held during play
rewinds the world 2 ticks per frame, paid from the fuel bar in the HUD (it
refills slowly, and a little per graze). On the title, A or Start starts a
normal game and B starts a hardcore one (no rewind stock: a hit is paid from
the fuel bar, and a hit with less than 45 fuel ends the game).

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
node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --frames 240 --every 4 --out out/
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
  40 ticks / holds 20 / down 40 / holds 20 until 3960. Since M5 (no bomb) two
  short hold-B rewinds get it through the waves the bombs used to clear: B
  2084..2093 (20 ticks back, fuel 180 to 160) before the moth + beetle wave,
  and B 3320..3334 (30 ticks, fuel 180 to 150) in the 54 s wave. The inputs
  keep their update indices, so after a hold the sweep runs ahead of the
  world and threads the pattern differently. It must still be playing at
  4000 with all three rewinds, and the score must beat M1's 570 (1640 since
  M6). Since M6 it also collects crates: F2 at 803, F3 at 1628, a fork at
  2222, the A crate (A3) at 2236, a second fork, the shield and A4 at
  3604..3628 (pinned in its sidecar).
- `m2_hit.json`: starts at 30 and does nothing else for 1000 ticks. The
  beetle's spread hits the idle ship at update 748: the game enters REWIND
  (state 4) for 80 updates, then resumes at 828 with the game tick back to
  598 and the score of that tick; the idle ship then meets the same fate
  again at 948.
- `m2_death.json`: the same input for 6000 ticks; every rewind is spent, the
  ship dies and the game is back on the title at the end.

The M3 scripts use two wasm-only test hooks through `--call-at`: `debug_god`
toggles god mode (hits are ignored) and `debug_warp` jumps the wave clock to
the 66 s WARNING so the boss arrives about 6 s later.

- `m3_boss.json`: the M2 sweep without the B holds, god at 31, warp at 32;
  the boss spawns at about 393; its first fire phase change (697) drops an
  F crate, collected at 841, and with twin zaps it runs out of HP at 922
  (about 1008 before M6); "+500" and "STAGE 2" at 983, and the table
  restarts at 1103.
- `m3_loop.json`: the same input for 2000 ticks; the stage-2 table spawns
  again (the 8 s beetle at 1583, now with 5 HP; F3 kills it by 1602).

The M4 scripts check the rewind itself. `debug_history_check` restores the
world from the newest keyframe and the input log and compares it field by
field with the live world: 0 means identical (2 means the check is refused on
that frame: title, dying, or the 20 bug-report frames).

- `m4_identity.json`: `m2_play`'s input with identity checks at twelve ticks,
  two of them during a hold-B rewind, two on the first live tick after a
  release, and three with a fork ghost and beams in flight.
- `m4_identity_boss.json`: `m3_boss`'s input (god + warp) with checks through
  the boss fight, a teleport, the death sequence and the stage clear.
- `m4_early.json`: flies into the first gnat string at update 84, before 120
  ticks of history exist; the rewind goes back to tick 0 and, since the
  playback length follows the depth (54 ticks, 27 frames), resumes at 131.

The M5 scripts check the hold-B rewind, the fuel bar and hardcore mode. The
exports they read: `debug_fuel` (0..180), `debug_hardcore` (0 or 1),
`debug_manual_frame` (frames since the hold began) and `debug_state` (0
title, 1 playing, 2 paused, 3 dying, 4 auto rewind, 5 hold-B rewind). The
bomb exports `debug_bombs` and `debug_bomb_timer` are gone.

- `m5_manual.json`: `m2_hit`'s input plus B held for updates 700..719. The
  press frame is already a rewind step; after 20 frames the game tick is 40
  lower and the fuel 140; the release frame is PLAYING without a tick. The
  idle ship then meets the beetle's spread 60 updates later than in `m2_hit`
  (809) and the free normal-mode auto rewind runs as usual.
- `m5_empty.json`: B held for 200 updates from 400. The bar is empty after 90
  frames (game tick 180 lower), play resumes while B is still down and stays
  live until a fresh press, and the refill brings the fuel to 10 by 590.
- `m5_hardcore.json`: B on the title at 30 starts a hardcore game (rewinds 0),
  then the ship idles. The first hit rewinds 120 ticks for 120 fuel (60
  left), the second 72 for the 72 it has by then (fuel 0, 36 playback
  frames), and the third, with fuel 8 under the floor of 45, is fatal: DYING
  at 1076, title at 1136.
- `m5_graze.json`: the `m2_play` sweep with a 20-frame hold at 1960 (fuel 140)
  instead of its two holds; the shifted sweep grazes a bullet at 2121
  without being hit and the fuel reads 157, above the 155 refill alone could
  give. (The hold was at 1964 until M6; the F2 crate changed the timing.)

The M6 scripts check the crates (section "Powerups"). The exports they read:
`debug_weapon` (kind * 10 + level, kind 0 F, 1 A, 2 B: `3` is F3, `13` A3,
`25` B5), `debug_forks` (0..3), `debug_shield` (0 or 1), `debug_pickups`
(crates on screen), `debug_drops` (crates dropped this game), `debug_cores`
(core hours collected) and `debug_bolts` (the ship's and ghosts' shots in
flight, pool of 64). `m1_play` also pins the plainest case of a rewind
undoing a collection: F2 at 166, a hit at 167, F1 again at 187 during the
playback.

- `m6_pickup.json`: the `m2_play` sweep with one long hold-B (806..885, 160
  ticks) right after the first F crate is collected at 803: the hold takes
  F2 back at 807 and puts the crate back on screen, the ship grabs it again
  at 1043; the core hours crate at 1383 lifts the fuel from 70 to 130; F3
  at 1868, a fork at 2432, and the A crate at 2498 turns F3 into A3.
- `m6_cores.json`: `m6_pickup`'s input plus a short hold (1390..1399) just
  after the core hours crate is collected at 1383 (fuel 70 to 130): the hold
  un-collects it but keeps the fuel, and grabbing it again at 1411 pays
  nothing more.
- `m6_fork.json`: `m2_play`'s input plus a third hold at 3632..3646 that
  goes back past the second fork, A4 and the shield (forks 2 to 1 at 3645,
  then re-collected at 3650). Identity checks with one and two ghosts and
  their beams in flight, during holds and on the first frames after them.
- `m6_retry.json`: `m2_play`'s input run on to 4990 (idle ship, no god
  mode). The shield from 3625 absorbs a hit at 4726: no rewind, no fuel,
  still PLAYING, nothing lands for 60 ticks; the next hit (4786) is a normal
  rewind, whose playback brings the shield back, and it absorbs the same hit
  again at 4926.
- `m6_retry_hc.json`: the same in hardcore (B on the title): the absorbed
  hits leave the fuel at 180 and 66, while the unshielded ones cost 120 and
  72.
- `m6_identity.json`: a 12000-update god-mode sweep with three holds: A5,
  B5, F5 (with its random spread), three forks and two stage clears, with
  identity checks throughout (it is 0 on every frame after the title).

`docs/preview_m5.gif` is one hold-B rewind, updates 690..760 of `m5_manual`:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --script tools/scripts/m5_manual.json \
  --frames 761 --start-skip 690 --every 2 --out out/gif_m5/
python3 ../../tools/make_gif.py out/gif_m5/ docs/preview_m5.gif --scale 3 --ms 66
```

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --frames 1800 --every 6 --out out/ \
  --script tools/scripts/m1_play.json \
  --dump-exports debug_state,debug_score,debug_lives,debug_enemies \
  --expect "debug_state == 1" --expect "debug_score > 0"
node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --frames 18000 --quiet --out out/soak/ \
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
tools/check.sh                 # zig build -Dcart=snouty-bugs (at the root), then every tools/scripts/*.json
tools/check.sh --no-build --only m5_manual
CART_WASM=path/to/other.wasm tools/check.sh --no-build
```

Each `tools/scripts/NAME.json` runs as
`node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --script NAME.json --quiet --out out/check/NAME ...`,
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

Install it as in [docs/INSTALL.md](../../../docs/INSTALL.md): copy
`zig-out/firmware/snouty-bugs.uf2` (at the repository root) onto the badge's
`SYCLBADGE` drive, eject, and pick it in the badge menu. Start+Select
returns to the menu.
