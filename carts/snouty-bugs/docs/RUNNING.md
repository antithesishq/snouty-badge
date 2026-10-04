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
| Anywhere | Hold Start + Select 0.5 s | (none) | Badge OS stops the cart and returns to its cart list (newer OS firmware: opens its settings box; A on "Exit cart" leaves) |
| Anywhere | Joystick click | Shift | Badge OS FPS overlay; the cart ignores it |
| Simulator only | | Escape | Simulator menu (Continue, Save/Load state, Reset cart, ...); it freezes the cart and is not the badge OS |

No sound toggle: the cart makes no sound yet, so Select does nothing (it
will toggle sound once audio lands; [docs/SOUND.md](../../../docs/SOUND.md)).
There is no bomb and, as yet, no attract mode: the title waits for a press.
After a game ends the cart returns to the title.

## Powerups (M6, M7)

Bugs drop crates (since M7, 1942's rule): a whole formation shot down (a
gnat string, a centipede, a ladybug four or a zombie group the stage marks
as one; +200 on top of the last kill), every Memory Leak beetle shot down,
the Thundering Herd midboss (two crates) and each boss HP phase break (a
phase that times out gives none). A formation that loses a member (it
flies off or rams the ship) drops nothing, nor does a bug rammed by the
ship (`tools/scripts/m7_drops` pins these). A crate is a 16x16 chamfered box with one bold
glyph that drifts left at half a pixel per tick on a gentle bob and leaves
at the left edge; up to four are on screen. Fly into it to collect it: any
overlap with the whole ship sprite counts, not just the small hitbox.
Every crate scores 100.

| Crate | Looks like | Grants |
|---|---|---|
| F (FUZZER) | Coral, white `F` | The default zapper, upgraded: single, twin, 3-way, 5-way, 5-way with random spread |
| A (ASSERT) | Teal, white `A` | Fast beams that go through every bug in their row: 1 beam, more damage, 2 beams, more damage, 3 beams |
| B (BISECT) | Green, white `B` | Homing seekers, 1 to 5, steering tighter per level |
| FORK | Purple, white Y-shaped branch | A ghost ship (dithered, no thruster) that replays your own path from 24 ticks ago and fires a level-1 shot of your weapon wherever you fired then (since M7; one zap, one beam or one seeker); up to three, 24 ticks apart. Ghosts cannot be hit and collect nothing |
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

## Stages, rank and bosses (M7)

M7 ("Bullet hell for real", SPEC.md 5.5, PLAN.md M7) made the game a real
bullet hell: four stages, then the loop again with a higher rank.

| Stage | Name | Brings | Midboss | Boss |
|---|---|---|---|---|
| 1 | `UNIT TESTS` | gnat strings, wasp vees, Memory Leak beetles, spiders, moths; every kind fires soon after it shows | none | Heisenbug (teleports) |
| 2 | `INTEGRATION` | centipedes, ladybugs looping in from the top and bottom, fleas jumping in from behind (a chevron warns at the left edge first) | Thundering Herd | Mandelbug (orbs that split, splits that split) |
| 3 | `STAGING` | ground mites on the near layer, zombies that die into a husk and revive once, bullet walls with gaps | Herd v2 | Schrodinbug (two bodies, one real) |
| 4 | `PRODUCTION` | everything, splitting-orb beetles, curtains from two sides | Herd v3 | Bohrbug (tracking walls, curving spirals, stop-and-go rain) |

A stage opens with `STAGE n` and its name (`LOOP n` above it from the
second loop), runs about 65-75 s of waves (the herd holds the stage's clock
while she lives; she leaves after 12 s; with fewer than 3 bugs on the field
the clock runs 4x, so the next wave comes in instead of a wait and a fast
player's stage is shorter), then `WARNING` for 3 s and the boss, then `+500` (a kill: the fuel bar refills) or `ESCAPED`, and a 2 s
breather. After `PRODUCTION` comes loop 2's stage 1, with rank +400,
revenge bullets and an extra table of later bugs.

Bosses have HP phases: a break cancels every bullet on screen (+10
each), drops a crate and rests 1 s, and no phase breaks before 6 s. Every
phase has a time limit (20 s, the final one 30 s): a non-final phase that
times out moves on without its crate, and a final phase that times out
flies the boss off the right edge: `ESCAPED`, no +500, no refill, but the
stage moves on, so nobody is ever stuck on a boss (`m7_escape`).

**Rank** (Raiden, Battle Garegga) is one number 0..1000, shown as `RANK
nnn` in the pause screen's help box:

```
rank = stage base (0 / 150 / 300 / 450) + 400 x loop + seconds into the stage (at most 120)
       + 50 per weapon level above 1 + 50 per fork - mercy        (clamped to 0..1000)
```

It speeds enemy bullets up (up to x1.5, capped per shape), shortens fire
intervals (to 0.6x), adds bullets to patterns, adds regular enemy HP (up
to x1.6) and from 600 (or in loop 2) makes killed bugs fire a revenge
pellet. It is computed from World state, so a rewind rewinds it too.

**Power loss** (Raiden): a hit that triggers the auto rewind in a normal
game costs one weapon level (never below 1) and one fork once the world
is restored; in a hardcore game it costs every powerup (FUZZER level 1,
no forks, no RETRY shield, even one the rewind brought back). Either way
it adds 80 **mercy** (rank -80; at most 240, decaying 2 a second). A hold-B rewind or the retry shield costs no
power (`m7_power`, `m7_rank`).

## 1. Prerequisites

See `../../docs/RUNNING.md` at the repository root (Zig version and download,
Node.js, Python with Pillow for GIF previews).

## 2. Checkout layout

This cart lives in `carts/snouty-bugs/` of the snouty-badge repository; the
upstream SDK is the `sycl-badge/` submodule at the repository root. See
[`docs/RUNNING.md`](../../../docs/RUNNING.md) section 2 for cloning
with the submodule.

Milestones are annotated tags `snouty-bugs/m1`, `snouty-bugs/m2`, ... (one per milestone)
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
- `--sample debug_hits,debug_weapon` (with `--sample-every K`, default 1):
  call these zero-argument exports after every K-th update and record them
  in `frames.json` under `samples` (`every`, `ticks`, `values: {NAME: [...]}`)
- `--until "debug_stage_index >= 5"`: stop right after the first update where
  it holds (`--frames` stays the cap); `frames.json` records `ran` (updates
  run) and `until` (where it held), and `--at` checks past the stop fail
- `--raw-colors`: decode colors as the cart API defines them instead of as the
  simulator displays them (only matters for carts that do not pre-swap)

Input scripts live in `tools/scripts/`, each with a sidecar `NAME.args`
whose comments say what it guards and every number it pins; this is the
overview. Most reuse one input: A on the title at 30, then a sweep holding
A (up 40 ticks, still 20, down 40, still 20; the "M2 sweep", `m2_play`'s
also fires still from 60 to 239). Since M7 a normal game no longer lives
through stage 1 on that sweep, so the scripts that need a long run play
it in god mode (`debug_god`: hits ignored) or in the endless probe mode
(`debug_probe`: a hit is counted and charged the power loss at once, no
rewind runs, the game goes on); the scripts about hits, rewinds and
hardcore play a normal game. Every script pins `debug_history_check == 0`
(below) at ticks where the game is playing.

`m1_play.json` is the sweep for 1800 ticks; `m1_pause.json` starts the
game, fires 60-300, presses START at 300 and 420 (pause, unpause), then
fires 430-600. `m1_play` also pins the plainest case of a rewind undoing a
collection: F3 at 623, a hit at 669, F2 again (crate back on screen) at 712
during the playback and F1 at the resume (749: the power loss). Since the
catch-up clock the plain sweep does not survive stage 1: it is hit again
at 821 and 1083 and the game is over at 1269 (title from 1329).

The M2 scripts:

- `m2_play.json`: the preview GIF script, the sweep to 3960 with two short
  hold-B rewinds (B 2084..2093: 20 ticks back, fuel 180 to 160; B
  3320..3334: 30 ticks, fuel 150). Since M7 in probe mode: at least 6 hits
  in stage 1 (the sweep's M7 target), crates, a fork, the A swap and the
  shield absorbing a hit on the way.
- `m2_hit.json`: starts at 30 and does nothing else. A wasp of the stage-1
  vee rams the idle ship at update 524 (game tick 494): REWIND (state 4) for
  80 updates, resume at 604 with the game tick back to 374; the idle ship
  meets the same fate at 724 and 924.
- `m2_death.json`: the same input for 6000 ticks; every rewind is spent, the
  ship dies and the game is back on the title at the end.

The M3 scripts use the wasm-only test hooks `debug_god` (toggles god mode)
and `debug_warp` (jumps the stage clock to the boss `WARNING`):

- `m3_boss.json`: the sweep in god mode, warp at 1700 (after F2 and F3):
  the Heisenbug spawns at 2061, its HP breaks at 2484 and 2939 each drop a
  crate (a fork, then the A), it dies at 3601, `+500` and the clear at 3662
  (stage index 1, `INTEGRATION`), whose table starts at 3782.
- `m3_loop.json`: the same run on to 4300: stage 2's first centipede (a
  formation) is shot down whole at 4042 and drops the RETRY crate.

The M4 scripts check the rewind itself. `debug_history_check` restores the
world from the newest keyframe and the input log and compares it field by
field with the live world: 0 means identical (2 means the check is refused on
that frame: title, dying, or the 20 bug-report frames).

- `m4_identity.json`: `m2_play`'s run with identity checks during and after
  both holds, with a ghost, beams, the shield and probe hits.
- `m4_identity_boss.json`: `m3_boss`'s run with checks through the boss
  fight, its HP breaks, the death sequence and the breather.
- `m4_early.json`: a hit before 120 ticks of history exist rewinds to tick
  0. Since M7 the first gnats come too late for that, so the test hook
  `debug_spray` (it spawns a fixed set of pattern-engine bullets from
  (140, 64)) at 60 supplies the bullet; the ship flying right is hit at 85
  (tick 55), the playback is 28 frames and play resumes at 133 at tick 0.

The M5 scripts check the hold-B rewind, the fuel bar and hardcore mode. The
exports they read: `debug_fuel` (0..180), `debug_hardcore` (0 or 1),
`debug_manual_frame` (frames since the hold began) and `debug_state` (0
title, 1 playing, 2 paused, 3 dying, 4 auto rewind, 5 hold-B rewind).

- `m5_manual.json`: `m2_hit`'s input plus B held for updates 480..499. The
  press frame is already a rewind step; after 20 frames the game tick is 40
  lower and the fuel 140; the release frame is PLAYING without a tick. The
  idle ship then meets the wasp 61 updates later than in `m2_hit` (585) and
  the free normal-mode auto rewind runs as usual.
- `m5_empty.json`: B held for 200 updates from 400. The bar is empty after 90
  frames (game tick 180 lower), play resumes while B is still down and stays
  live until a fresh press, and the refill brings the fuel to 10 by 590.
- `m5_hardcore.json`: B on the title at 30 starts a hardcore game (rewinds 0),
  then the ship idles. The first hit (524) rewinds 120 ticks for 120 fuel (60
  left), the second (724) 72 for the 72 it has by then (fuel 0, 36 playback
  frames), and the third, with fuel 7 under the floor of 45, is fatal: DYING
  at 852, title at 912.
- `m5_graze.json`: the sweep in probe mode with a 20-frame hold at 1600 (fuel
  140): a graze re-lived after the hold pays nothing (the graze high-water
  mark), a new one at 1714 lifts the fuel to 152, above the 150 the refill
  alone could give.

The M6 scripts check the crates (section "Powerups"). The exports they read:
`debug_weapon` (kind * 10 + level, kind 0 F, 1 A, 2 B: `3` is F3, `13` A3,
`25` B5), `debug_forks` (0..3), `debug_shield` (0 or 1), `debug_pickups`
(crates on screen), `debug_drops` (crates dropped this game), `debug_cores`
(core hours collected) and `debug_bolts` (the ship's and ghosts' shots in
flight, pool of 64).

- `m6_pickup.json`: the sweep in probe mode with one long hold-B (903..982,
  160 ticks) right after the first crate (a beetle's, 751) is collected at
  900: the hold takes F2 back and puts the crate back on screen (by 978 even
  the drop is undone), the ship grabs it again at 1140; a formation's core
  hours crate lifts the fuel from 101 to 161 at 1740; a fork, then the A
  crate turns F1 into A1.
- `m6_cores.json`: `m6_pickup`'s input plus a short hold (1747..1756) just
  after the core hours crate is collected at 1740: the hold un-collects it but
  keeps the fuel, and grabbing it again at 1766 pays nothing more.
- `m6_fork.json`: the sweep in god mode with three holds, two of which go
  back past a fork collection (forks 1 to 0 at 2093; 2 to 1 at 4053, then
  re-collected at 4165). Identity checks with one and two ghosts and their
  bolts in flight, during holds and on the first frames after them.
- `m6_retry.json`: the RETRY shield in a normal game: collected in god mode
  (2429), god off at 5000 in the Heisenbug fight; it absorbs a hit at 5126
  (no rewind, no fuel), the ship then flies into the boss (5207): a normal
  rewind whose playback brings the shield back, which absorbs again at 5347.
- `m6_retry_hc.json`: the same in hardcore (B on the title): the absorbed
  hit leaves the fuel at 180, the unshielded ram costs 120, and the resume
  strips every powerup (F5, two forks and the restored shield -> F1, none),
  so the next hit rewinds (fuel 66 -> 0) and the one after is fatal.
- `m6_identity.json`: a 12000-update god-mode sweep through two stages and
  their bosses with three holds: F5 (with its random spread), A5, B5, three
  forks and two stage clears, identity checks throughout (0 on every frame
  after the title).

The M7 scripts. More test hooks (wasm only, never World state unless
said): `debug_probe` (toggles the endless probe mode), `debug_bot(n)` (a
bot from `cart/src/autopilot.zig` drives the buttons: 1 turret, 2 sweep, 3
dodger; 0 off), `debug_next_stage` (jumps to the start of the next stage,
clearing the field), `debug_boss(id | phase << 4)` (the next boss to spawn
and its starting HP phase; ids 0 Heisenbug, 1 Mandelbug, 2 Schrodinbug, 3
Bohrbug, 4+ the stage's own), `debug_spray` (the engine bullet set above),
`debug_seed(n)` (the world rng seed of new games); and exports
`debug_hits` (probe hits), `debug_last_hit`, `debug_rank`, `debug_mercy`,
`debug_stage_index` (stage + 4 x loop), `debug_boss_id`,
`debug_boss_phase`, `debug_boss_clock`, `debug_bullets`, `debug_escaped`.

- `m7_identity.json`: the identity check with splitting, re-aiming and
  turning bullets in flight (`debug_spray` before each of four holds),
  pinned every 10 updates.
- `m7_stages.json`: probe mode through all four stage tables and into loop
  2 (`debug_next_stage`), a hold in each, identity every 10 updates.
- `m7_bosses.json`: each boss forced into its busiest phase
  (`debug_boss` + `debug_warp`) with a hold in each fight, identity every
  10 updates.
- `m7_rank.json`: the rank's terms one by one: the stage clock (0, 4, 6),
  F2 (+50), the jump to `PRODUCTION` (500), a rewound hit (502 -> 372: the
  level and 80 mercy), the mercy adding up over three rewinds and capped at
  240 once probe hits keep coming.
- `m7_power.json`: the power loss: F5 and two forks kept through a hold-B
  and a shield pop; each of three auto-rewind resumes takes a level and a
  fork (F5 -> F4 -> F3 -> F2, forks 2 -> 1 -> 0 -> 0).
- `m7_drops.json`: 1942's rule in stage 1: a beetle drops, a whole gnat
  formation drops with +200, formations that lost a member, a wasp vee, a
  spider and a moth drop nothing.
- `m7_escape.json`: an unhurt Heisenbug forced into P2: P2 times out after
  20 s without a crate, P3 after 30 s, and it escapes: `debug_escaped` 1,
  the stage moves on to `INTEGRATION`, no +500, no clear, no fuel refill.

`docs/preview_m5.gif` is one hold-B rewind, updates 690..760 of `m5_manual`:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --script tools/scripts/m5_manual.json \
  --frames 761 --start-skip 690 --every 2 --out out/gif_m5/
python3 ../../tools/make_gif.py out/gif_m5/ docs/preview_m5.gif --scale 3 --ms 66
```

`docs/preview_m7.gif` is six 160-update windows (every 4th update, 2x),
the dodger bot playing in probe mode, each the window with the most
bullets on screen: stage 1 at 42 s, the Heisenbug in P2, the Mandelbug in
P2, the Schrodinbug in P4, the Bohrbug in P5 (each boss forced with
`debug_boss` at its own stage's rank) and `PRODUCTION` at 61 s:

```sh
g() { n=$1; st=$2; shift 2
  node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --out out/gif_m7/$n --frames $((st + 160)) \
    --start-skip $st --every 4 --call debug_probe --call debug_bot:3 "$@"; }
g 1 2510
g 2 741  --call debug_boss:16 --call-at "5 debug_warp"
g 3 682  --call debug_boss:17 --call-at "5 debug_next_stage" --call-at "6 debug_warp"
g 4 1336 --call debug_boss:34 --call-at "5 debug_next_stage" --call-at "5 debug_next_stage" --call-at "6 debug_warp"
g 5 602  --call debug_boss:67 --call-at "5 debug_next_stage" --call-at "5 debug_next_stage" \
         --call-at "5 debug_next_stage" --call-at "6 debug_warp"
g 6 3676 --call-at "5 debug_next_stage" --call-at "5 debug_next_stage" --call-at "5 debug_next_stage"
mkdir -p out/gif_m7/all; i=0
for f in out/gif_m7/[1-6]/frame_*.png; do cp "$f" out/gif_m7/all/frame_$(printf %04d $i).png; i=$((i + 1)); done
python3 ../../tools/make_gif.py out/gif_m7/all/ out/gif_m7/raw.gif --scale 2 --ms 66
convert out/gif_m7/raw.gif -layers Optimize docs/preview_m7.gif   # ImageMagick: 2.0 -> 1.9 MB
```

```sh
node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --frames 1800 --every 6 --out out/ \
  --script tools/scripts/m1_play.json \
  --dump-exports debug_state,debug_score,debug_lives,debug_enemies \
  --expect "debug_state == 0" --expect "debug_score > 0"
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

### Difficulty probe: `tools/difficulty.sh`

The M7 difficulty curve as numbers (PLAN.md M7 "Probe" and "Difficulty
targets"). Three bots from `cart/src/autopilot.zig` each play a fresh game
in endless probe mode (a hit is counted and costs power, but the game never
ends and no rewind runs) through the four stages and loop 2's stage 1:

| Bot | Plays |
|---|---|
| 1 turret | holds A, never moves |
| 2 sweep | holds A; up 40 ticks, still 20, down 40, still 20 |
| 3 dodger | holds A and dodges: it scores 25 short moves (a 5x5 grid of targets up to 24 px away) against the straight-line paths of the enemy bullets and enemies it has noticed, nearer ticks weighted more, with small pulls toward crates, toward lining up a shot and toward the left-center, and commits to the best until its next plan; a decent player, not a great one, and the seed of the attract mode |

The dodger's human limits all follow one knob, `skill` at the top of
`autopilot.zig` (0 beginner .. 1 sharp, default 0.5): it never notices a
share of the bullets (0.25), sees the others only once they are 12 ticks
old (200 ms), foresees no drag, acceleration, turn, split or re-aim, looks
22 ticks ahead, re-plans every 7 ticks and adds a little noise (a hash of
the tick, never the world rng) to every choice. The missed share moves the
hit count most.

```sh
tools/difficulty.sh                          # zig build, then all three bots (a few seconds)
tools/difficulty.sh --no-build --bots 3 --stages 1
tools/difficulty.sh --no-build --json out/difficulty.json
tools/difficulty.sh --no-build --bosses 0,1,2,3   # boss rush: each boss on its own
```

It prints one table, a row per bot and stage (`L1S1` .. `L1S4`, then
`L2S1`: loop and stage), and a total per bot:

| Column | Meaning |
|---|---|
| hits | probe hits in the stage (each one a rewind a real player would have spent) |
| secs | seconds in the stage, from its first tick to the next stage's first |
| boss s | seconds the boss was on the field (`debug_boss_hp` > 0) |
| boss hits | the hits taken while it was |
| boss | `killed`, or `escaped` (the stage ended without a clear: the boss timed out) |
| phases | HP phases the boss reached (`debug_boss_phase`) |
| rank | `debug_rank` at the stage's last tick (`-` on carts without it) |
| wpn@boss, wpn | the weapon (`F`/`A`/`B` and level, from `debug_weapon`) when the boss arrived and at the stage's end |
| forks | forks at the stage's end |

A `*` after the stage means the run hit its cap (`--frames`, default 15,000
updates per stage) inside that stage. Options: `--bots 1,2,3`, `--stages N`
(stop once the stage index, stage + 4 x loop, reaches N; default 5),
`--frames CAP`, `--seed N` (1, the default, is the game the deterministic
wasm clock seeds; any other N also seeds the world rng through the
`debug_seed` test hook, so spawn positions, moth paths and boss teleports
differ: run a few to see the spread, the dodger's runs vary a lot from seed
to seed), `--json FILE` (the rows plus the
wasm's sha256), `--no-build`; `CART_WASM` points it at another build. Same
build, same table. Each bot is one run of `../../tools/preview.mjs` with
`--call debug_probe --call debug_bot:N` (the bot holds A, so it starts the
game from the title on update 0), `--sample` for a per-update trace of the
exports and `--until` to stop at the last stage; the trace stays in
`out/difficulty/botN/frames.json`.

`--bosses 0,1,2,3` runs a boss rush instead (0 Heisenbug, 1 Mandelbug,
2 Schrodinbug, 3 Bohrbug): per bot and boss a fresh game plays stage 1 up
to update `--warp-at` (default 3000, so the bot has collected some crates),
then `debug_boss:ID` (set before the first update) and `debug_warp` bring
that boss, and the run ends when the next stage starts. One row per bot
and boss; its hits and secs include the stage-1 play before the warp, boss
hits and boss s are the fight's. Traces in `out/difficulty/botN_bossID/`.

## 6. Flash the badge

Install it as in [docs/INSTALL.md](../../../docs/INSTALL.md): copy
`zig-out/firmware/snouty-bugs.uf2` (at the repository root) onto the badge's
`SYCLBADGE` drive, eject, and pick it in the badge menu. Start+Select
returns to the menu.
