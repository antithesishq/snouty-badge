# Running the Universal Paperclips cart

The cart lives in `carts/paperclips/` of the snouty-badge repository: a
port of *Universal Paperclips* by Frank Lantz and Bennett Foddy (with
their permission), the whole game number for number, as pages of rows on
the 160x128 screen (`SPEC.md`). Commands below run from that directory
unless noted; only `zig build` runs from the repository root (`../..`),
and its outputs are in the root `zig-out/`.

## 1. Prerequisites

Zig `0.17.0`, Node.js 20+, Python 3 (with Pillow for
the generators and GIFs) and git: see the root
[`docs/RUNNING.md`](../../../docs/RUNNING.md), sections 1 and 2.
badge-bench makes its own Python environment on first run.

## 2. Get the code

```sh
git clone --recursive git@github.com:antithesishq/snouty-badge.git   # first time
cd snouty-badge
git checkout main && git pull && git submodule update --init         # every time after
```

Milestones are annotated tags (`git tag -n1 'paperclips/*'`).

## 3. Build and test

From the repository root:

```sh
zig build -Dcart=paperclips              # firmware + wasm (plain `zig build` builds every cart)
zig build test -Dcart=paperclips         # host tests: the game port and the UI
zig build paperclips-oracle              # the oracle runner (zig-out/bin/paperclips-oracle)
```

Outputs, in the root `zig-out/`:

- `zig-out/firmware/paperclips.uf2`: for the badge (a RAM cart)
- `zig-out/firmware/paperclips.elf`: the same program, for badge-bench
- `zig-out/bin/paperclips.wasm`: for the simulator and the headless tools

The whole gate, from `carts/paperclips/`:

```sh
tools/check.sh                 # build test gen oracle preview bench size
tools/check.sh preview bench   # just those steps
```

| Step | What it checks |
|---|---|
| `build`, `test` | the `zig build` commands above |
| `gen` | the committed generated files match their generators (`gen_font.py`, `gen_title.py`, `gen_scripts.py`, each `--check`) |
| `oracle` | builds the oracle runner and runs track O's comparison against the original JS (`tools/compare.mjs`) |
| `preview` | headless wasm runs: a 10-minute bot (`tools/scripts/soak.json`) without a trap, the cheat code (`cheats.json`), and the tour (`tour.json`) as PNGs in `out/check/tour/` to look at |
| `bench` | badge-bench, calibrated: a prepared late stage-1 game on each stage-1 page (`--poke paperclips_bench=1..6`), a stage-2 game (7), a live stage-3 battle on COMBAT (8) and SPACE (9), a new game (10): worst `busy ms` <= 10 (`BENCH_MAX_MS`), mean <= 5 (`BENCH_MEAN_MS`); 8 and 9 worst <= 20 / mean <= 8, 10 worst <= 30 / mean <= 8 (live battles move every ship in exact soft f64; see `tools/check.sh`) |
| `size` | `size -A`: `.text` + `.data` + `.bss` (+ unwind tables) <= 200 KB (`SIZE_MAX_KB`) |

badge-bench serves cart saves by default, so the Start press in
`bench.json` saves the game once (section 9): that frame, ~116 ms with
the modelled flash, is printed apart and not held to the limits.

## 4. Flash it

Copy `zig-out/firmware/paperclips.uf2` to the badge as the root
[`docs/INSTALL.md`](../../../docs/INSTALL.md) describes. A game lasts while
the cart runs on the organizers' OS. On the patched OS with cart saves
(branch `saves/m1` only) the game is saved and continues after a power
cycle: section 9.

## 5. Controls

The screen, top to bottom: the clip count, a status line (funds, wire,
operations, creativity, yomi: what fits), the page tab (`< BUSINESS >`, the
page's place among the pages that exist now, a blinking `!` when another
page has news), the page's rows, and the newest message (two lines; a
longer one pages through).

| Input | Action |
|---|---|
| Up / Down | Move the cursor over the rows (held: repeats). The cursor skips readouts but steps onto them to show rows below the last button |
| Left / Right | Previous / next page |
| A | Press the selected button (grey: not available now). On a value row (`< $0.25 >`: price, investment risk, strategy) A raises / steps forward. Held on a buy row, A repeats after 0.4 s, 8 per second; Make Paperclip never repeats |
| B | Lower / step back on value rows |
| Start | The message log (Up/Down scroll, Start or B back) |
| Select | Jump to the next page with news (`!`) |

Start and Select act when released, and not at all while both are held
(the OS's chord: exit, or its settings box on newer firmware). The
joystick click belongs to the OS.

Pages (each holds the original's panels; a page appears when its panel
does): BUSINESS (Make Paperclip, funds, revenue, inventory, price, demand,
marketing), MANUFACTURING (clips per second, WireBuyer, wire, AutoClippers,
MegaClippers), COMPUTING (trust, processors, memory, operations,
creativity, quantum chips and Compute), PROJECTS (the list; the footer
shows the selected one's cost and description, scrolling when long),
INVESTMENTS (risk, deposit, withdraw, cash, stocks, the stock table,
the engine upgrade), STRATEGY (strategy pick, Run, New Tournament,
AutoTourney, yomi, the payoff grid or the results; A on a result line
shows the grid, A on the grid the results: the original's mouse-over),
CHEATS (below).

Title: A starts. Up Up Down Down Left Right Left Right B A on the title
unlocks the CHEATS page ("CHEATS ON"), the original mirror's cheat
buttons, for the session.

After "Release the HypnoDrones" (the flash plays) the game goes on into
stage 2: FACTORIES (the stage-2 Manufacturing panel), WIRE (matter,
harvester and wire drones with their +10/+100/+1k rows), POWER (solar
farms, batteries), SWARM (status, gifts, the Work/Think slider: A and B
move it), then stage 3: SPACE (probes launched, lost, drifters), PROBE
DESIGN (the trust allocation as value rows, the original's tooltips in
the footer, increase trust / max trust, honor) and COMBAT (the battle
drawn from the game's ships: probes white, drifters black). Panels vanish
in the ending as in the original, down to the PAPERCLIPS page with Make
Paperclip and the final count. A choice of a new universe (the projects
"The Universe Next Door" / "Within", "Quantum Temporal Reversion") goes
back to the title, which then shows the universe and sim level.

A build whose `game/game.zig` declares `pub const stage2_ready = false;`
stops after the HypnoDrones instead, on a "Stage 2 arrives in M2" screen.

## 6. Web simulator

Terminal 1, from `carts/paperclips/`:

```sh
node ../../tools/serve-cart.mjs            # serves ../../zig-out/bin/paperclips.wasm on :2468
```

Terminal 2:

```sh
cd ../../sycl-badge/simulator
npm install                                # first time
npm run dev
```

Open <http://localhost:1234>. Keys: arrows or WASD (joystick), Z or K
(A), X or J (B), Enter or Y (Start), Backspace or T (Select).

## 7. Headless preview and the GIF

```sh
node ../../tools/preview.mjs ../../zig-out/bin/paperclips.wasm --frames 980 --every 6 \
    --script tools/scripts/tour.json --out out/tour
python3 ../../tools/make_gif.py out/tour out/tour.gif --scale 2 --ms 100
```

The committed `docs/preview_m1.gif` walks every stage: the tour, then
the autoplayer jumps to stage 2, stage 3 and the end:

```sh
node ../../tools/preview.mjs ../../zig-out/bin/paperclips.wasm --frames 1800 --every 6 \
    --script tools/scripts/gif.json --call-at "990 debug_autoplay:9000" \
    --call-at "1290 debug_autoplay:11000" --call-at "1650 debug_autoplay:8000" --out out/gif
python3 ../../tools/make_gif.py out/gif docs/preview_m1.gif --scale 2 --ms 100
```

Useful: `--call debug_prepare` (a late stage-1 game: two virtual minutes
in which every second takes the cheats and buys wire, a project and
machines), `--call debug_advance:60000`
(run the game clock a minute), `--call debug_unlock_cheats`,
`--call debug_go_page:6`, `--call debug_cheat:1` (0 clips, 1 money,
2 trust, 3 ops, 4 creativity, 5 yomi), `--call debug_autoplay:9000` (the
game's autoplayer, `game/bot.zig`, plays that many virtual seconds:
about 9,000 reach stage 2, 20,000 stage 3, 28,000 the end; a few
seconds of wall time per 1,000).

Debug exports (wasm only): `debug_frame`, `debug_screen` (0 title, 1 game,
2 log, 3 the M1 wall), `debug_page` (the `Page` enum of `cart/src/ui/pages.zig`: 0 BUSINESS,
1 MANUFACTURING, 2 FACTORIES, 3 WIRE, 4 SPACE, 5 COMPUTING, 6 PROJECTS,
7 INVESTMENTS, 8 STRATEGY, 9 COMBAT, 10 POWER, 11 SWARM, 12 PROBE DESIGN,
13 PAPERCLIPS (the end), 14 CHEATS),
`debug_cursor`, `debug_rows`, `debug_clips`, `debug_funds_cents`,
`debug_presses` (presses that reached the game), `debug_msgs`,
`debug_news` (bit per page), `debug_cheats`, `debug_human`
(the original's humanFlag), `debug_stage` (1, 2, 3),
`cart_framebuffer_address`.

## 8. badge-bench

```sh
../../badge-bench/bench.sh ../../zig-out/firmware/paperclips.elf --poke paperclips_bench=1 \
    --poke paperclips_seed=7 --script tools/scripts/bench.json --frames 400 --symbols
```

`paperclips_bench=N` starts in the prepared game on stage-1 page N (1..6)
instead of the title; 7 is a prepared stage-2 game on the SWARM page, 8 and
9 a 200-vs-200 stage-3 battle on the COMBAT and SPACE pages
(`cart/src/game/prepare.zig`), 10 a new game from its first frame, 99 the
soft-float self-test (`cart/src/game/softfloat_arm.zig` against the Zig
routines); `paperclips_seed` fixes the game's seed (the badge otherwise
mixes the microsecond clock in).

## 9. Saves

Saves need the patched badge OS (sycl-badge branch `cart-saves`; the root
[`docs/SAVES.md`](../../../docs/SAVES.md) says how to flash it). On the
organizers' firmware, in the web simulator and in the wasm previews the
cart is exactly the one without saves: no menu, no marks, nothing
written. It finds out once per boot, on the title's second frame (250 ms
while the title is on screen, on stock firmware).

- **One key, `paperclips/game`:** the whole game (`cart/src/game/snapshot.zig`):
  the `Game` struct's bytes with the dead state zeroed (timers and log
  slots not in use, battle ships nothing can read), LZ-compressed, behind
  a 20-byte header (magic `UPCS`, format version, a hash of `Game`'s
  layout, the image size, a checksum). A load continues bit for bit where
  the save left off: the RNG, the timers' phases, the log, a battle in
  progress. This is more than the original's `save()` keeps (it restarts
  the canvas battle and its timers on load).
- **Size:** one 4 KB block for the whole of stages 1 to 3 (1.3 KB after a
  minute, 2.3 KB with projects, 3.0-3.5 KB in space, seed 2026). The
  first seconds of a game (the opening skirmish, 400 live ships) take
  ~12 KB; a stage-3 battle at its first frame with a full log, the
  largest, 17.6 KB (the cart's buffer is 22 KB). A save costs (blocks + 1)
  x 55 ms: 110 ms almost always.
- **The title:** with a saved game, `CONTINUE` / `NEW GAME` (Up/Down, A).
  NEW GAME asks `OVERWRITE? A:YES B:NO`; the old save stays until the new
  game's first save. A finished game's universe and sim levels carry into
  the new game (the original keeps its savePrestige apart too). A save
  from another build of the port shows `SAVE FROM OLDER VERSION` and A
  starts a new game; damaged data shows `SAVE DAMAGED`.
- **When it saves:** every 60 s of play, every 5 minutes once nobody has
  pressed a button for 5 minutes (an idle game left running); on opening
  the message log (Start); on the OS's settings "Exit cart". The original
  autosaves every 25 s into the browser's free localStorage; here each
  save freezes the cart ~110 ms and erases a directory block every cart
  shares, hence the minute (knobs in `cart/src/ui/saves.zig`).
  A timer or log save waits while a battle is live (both sides have
  ships, the slow frames), for at most 30 s. The frame before the write
  shows `SAVING` top right, and that frame stays on screen while the cart
  is parked; the game clock skips the stall. Exit saves at once (the OS
  shows its own "Saving...").
- **Errors:** `RateLimited` (the OS's 8 + 1 per 10 s) is retried at the
  next save; anything else shows `SAVE FAILED: ...` across the top once
  for 3 s, and later saves keep trying.

Tests: `cart/src/game/snapshot_tests.zig` (the autoplayer from the first
second to stage 3; at nine checkpoints it saves, loads into a fresh
`Game`, runs the original, the loaded copy and a never-saved copy on with
the same bot and compares every field; the LZ codec; refused versions and
damage) and the `saves:` tests in `cart/src/ui/tests.zig` (lib/save.zig's
fake: autosave timing, the mark, the log and battle rules, CONTINUE and
NEW GAME, prestige, the exit hook, errors, stock firmware).

badge-bench (`--saves FILE.json` keeps the store between runs):

```sh
B=../../badge-bench/bench.sh; E=../../zig-out/firmware/paperclips.elf
$B $E --poke paperclips_bench=1 --script tools/scripts/bench.json --frames 400 --saves /tmp/pc.json  # Start saves: [save 110 ms]
$B $E --saves /tmp/pc.json --press A:20-21 --frames 60 --png 5    # the title: CONTINUE
$B $E --poke paperclips_bench=8 --frames 300 --exit-at 200        # Exit cart mid-battle: [save 165 ms]
$B $E --poke paperclips_bench=1 --frames 400 --no-saves           # stock firmware: the 250 ms probe, nothing else
```

