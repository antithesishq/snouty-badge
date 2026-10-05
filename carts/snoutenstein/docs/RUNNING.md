# Running the Snoutenstein 3D cart

Commands below run from this cart's directory (`carts/snoutenstein/`) unless
noted; `zig build` runs from the repository root, two levels up, and writes its
outputs to `../../zig-out/`.

## Controls

Play first, tooling after. Badge buttons, then the simulator keys
(section 4 has the full key table; the joystick is the arrow keys or
WASD, so the `A` key is joystick left, not the A button). The
authoritative table is `SPEC.md` section 3.

| Where | Badge | Simulator | Does |
|---|---|---|---|
| Title | Joystick up / down | Up / Down or W / S | Pick PLAY, DEATHMATCH or PARTY (both greyed in the simulator: NO LINK IN SIMULATOR, NEEDS PARTY FIRMWARE; PARTY only in `-Dstein_party=true` builds) |
| Title | A | Z or K | PLAY: start the campaign; DEATHMATCH: the two-badge lobby (section 7); PARTY: the party lobby (section 8) |
| Title | B / Start | X or J / Enter or Y | Start the imported E1M1 / the test level |
| Title | Select | Backspace or T | Sound on/off; the cart boots silent ([docs/SOUND.md](../../../docs/SOUND.md)) |
| Title | (leave it 10 s) | | Attract demo; any button or the joystick returns to the title |
| Playing | Joystick up / down | Up / Down or W / S | Walk forward / back |
| Playing | Joystick left / right | Left / Right or A / D | Turn (no strafe) |
| Playing | A | Z or K | Fire / swat |
| Playing | Select | Backspace or T | Next weapon (skips empty ones) |
| Playing | (walk into it) | | Opens a door; there is no use button |
| Playing | Hold B | Hold X or J | Rewind time, paid from the clock meter in the HUD |
| Playing | Start | Enter or Y | Pause; the pause screen lists these controls; Start again resumes |
| Dead (red, frozen) | Hold B | Hold X or J | Rewind, the only way on (always at least 3 s) |
| Level clear / victory | A or Start | Z or K / Enter or Y | Next card |
| Deathmatch lobby | A / Start / B | (badge only) | Ready / the host goes once both are ready / back to the title; the host's Up/Down and Left/Right set the rules |
| Deathmatch | Hold B + Left / Right | (badge only) | Strafe (no rewind in a match); everything else as Playing; Start pauses both badges, B in the pause leaves (a forfeit) |
| Deathmatch results | A or Start | (badge only) | Back to the lobby |
| Party lobby | A / Start / B | (badge only) | Ready / the host goes / back to the title (leaves the room); the host's Up/Down and Left/Right set the rules; Left/Right picks your team in a team match (before ready) |
| Party match | as Deathmatch, plus hold Select | (badge only) | The scoreboard (Select still cycles weapons); Start pauses everyone, B in the pause leaves (a bot takes your slot) |
| Party results | A or Start | (badge only) | Back to the lobby |
| Anywhere | Hold Start + Select 0.5 s | (none) | Badge OS stops the cart and returns to its cart list (newer OS firmware: opens its settings box; A on "Exit cart" leaves) |
| Anywhere | Joystick click | Shift | Badge OS FPS overlay; the cart ignores it |
| Simulator only | | Escape | Simulator menu (Continue, Save/Load state, Reset cart, ...); it freezes the cart and is not the badge OS |

## 1. Prerequisites

See `../../docs/RUNNING.md` at the repository root (Zig version and download,
Node.js, Python with Pillow for GIF previews).

## 2. Checkout layout

This cart lives in `carts/snoutenstein/` of the snouty-badge repository; the
upstream SDK is the `sycl-badge/` submodule at the repository root. See
[`docs/RUNNING.md`](../../../docs/RUNNING.md) section 2 for cloning
with the submodule.

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

**Team VM only** (needs an ssh login on the team's exe.dev VM): without a
local toolchain, the VM's build artifacts can be pulled into the same
locations and everything below works unchanged:

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
demo of Production: `sim.init` of level 2 with a fixed seed, driven by an
input log baked into the cart (`cart/src/demos/build_farm.zig`) instead of
the pad. A blinking "DEMO" sits at the top of the view while it runs. Any
edge on A, B, Start, Select or the joystick (up, down, left, right) ends
the demo without stepping that tick and shows the title; that press does
not also pick a menu entry. The demo is a later level, so it is not handed
over. The demo also returns to the title when the log runs out, after
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
starts the demo level (Production) with the demo seed in normal play, tick 0 = update 0
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

Demo content: 4,108 ticks (68.5 s) of Production (level index 2), ending
alive. Snouty walks the pipe corridor east through the plain doors at
(7,3) and (12,3), zaps the three cable-tray gnats from the doorway, grabs
the zapper charge at (13,1) and zaps the beetle at (21,8) (one of its
spits lands), then pushes through the door at (23,5) and walks straight
into the vent hall: the spider webs it (freeze), both wasps charge into
it and it drops to 34 HP. It holds B for updates 1221-1430 (210 ticks,
3.5 s of Iris rewind; HP back to 90 just inside the door) and on the
second try zaps both wasps, the spider and the gnat from the doorway.
It picks up the Coral key at (37,8) (grin) and the hotfix at (25,9),
goes back across the cable trays and through the Coral door at (14,10)
into the brick room, grabs the charge at (12,12), zaps a gnat and the
beetle, switches to the swatter when the charges run out, swats the last
gnat, takes the Iris key at (2,12), is webbed twice walking up to the
spider at (8,18), swats it and ends facing the Iris door at (15,16)
without opening it: 74 HP, 12 kills, mode playing. The boss arena needs
all three keys and is out of reach. Recorded hash `0x10A0860C` (final
game tick 3687). After any change that moves the simulation (balance,
AI, map, rewind), the enemies move differently and the log goes stale:
edit `tools/scripts/demo_build_farm.json` (author with `--call
debug_new_game_seeded` and `--call-at T debug_px` etc. as above, check
HP, kills and position at the milestones), run `tools/record_demo.sh`,
rebuild, then `tools/check.sh` (the attract, demo and takeover runs must
pass). Changing an early segment reshuffles every fight after it, so
re-check the whole run, not just the edit.

Neopixels are off in every build (docs/NEOPIXELS.md at the repository
root): the cart never writes a non-zero LED byte; the HP bar, key flash
and rewind pulse in `cart/src/audio.zig` are compiled out.
`zig build -Dcart=snoutenstein -Dneopixels=true` (repository root)
re-enables them for development; `tools/check.sh` builds that variant
once so the path keeps compiling. Never flash it to a badge you look at.

## 6. Flash the badge

Install it as in [docs/INSTALL.md](../../../docs/INSTALL.md): copy
`zig-out/firmware/snoutenstein.uf2` (at the repository root) onto the badge's
`SYCLBADGE` drive, eject, and pick it in the badge menu. Start+Select
returns to the menu.

## 7. Deathmatch (two badges, M7)

Two badges, each running this cart, joined by a JST-SH 3-pin cable
between their UART headers (J4; crossed or straight both work, root
[docs/LINK.md](../../../docs/LINK.md)). SPEC.md section 19 has the rules.

**Hardware check (two badges):**

1. Flash `snoutenstein.uf2` on both badges and start Snoutenstein on both.
2. Plug the cable into both UART headers.
3. On both title screens: Down to DEATHMATCH, A. Both lobbies leave PLUG
   IN THE CABLE within a second or two; one says YOU: P1, PICK RULES,
   the other YOU: P2, P1 PICKS. A badge running another link cart shows
   WRONG CART: and its name.
4. On the host: Up/Down picks ARENA, FRAGS or BUGS, Left/Right changes
   it; the guest's screen follows.
5. A on both: YOU and THEM read READY on both screens; the host shows
   START: FIGHT.
6. Host Start: both badges start the match at once, each from its own
   player. Frag each other: the other badge is the Coral-shirted rival
   Snouty, it flashes white on a hit, six zapper hits frag, both HUDs
   count YOU / THEM, the banners agree (YOU DELETED PLAYER 2 here is
   DELETED BY PLAYER 1 there). The dead player's weapon stays where they
   fell: walk over it to take it (its ammo adds to yours if you have
   it). Hold B with Left/Right to strafe.
7. Start on either badge pauses both; Start again resumes both.
8. First to the frag limit: both show the results (YOU WIN on one, YOU
   LOSE on the other, the same frags and shots). A goes back to the lobby
   on each.
9. Optional: pull the cable mid-match: the other badge ends with YOU
   WIN: FORFEIT and PEER LEFT. A DESYNC band would be a bug (report the
   arena and roughly when).

**Without a second badge** (simulator, previews, bench) a local match
stands in: the debug exports `debug_dm_local:R` (the pad on player 0, a
bot on player 1), `debug_dm_bots:R` (two bots), `debug_dm_view:S` (show
player S) and `debug_dm_lobby:K` (the lobby as 1 host, 2 guest,
3 searching, 4 wrong cart; 0 is the real NO LINK screen). R is the rules
byte: arena bits 0-1 (0 Server Room, 1 Build Farm), frag index bits 2-3
(5, 10, 15, 20), bugs bit 4.

```
node ../../tools/preview.mjs ../../zig-out/bin/snoutenstein.wasm --frames 600 --every 6 \
  --out out/dm --call debug_dm_bots:16 --dump-exports debug_dm_frags,debug_dm_tick
```

The bench has no cable either: `tools/bench_m7.sh` pokes
`stein_dm_bench` (rules byte + 1) so a bot-vs-bot match runs from the
first update, on both arenas with BUGS ON.

## 8. Party deathmatch (up to 16 badges, M8)

Up to 16 badges, each plugged into one laptop by USB, play one deathmatch
in lockstep through the laptop's `badge lobby` relay (root
[docs/LOCKSTEP_N.md](../../../docs/LOCKSTEP_N.md)). It needs the **fork
firmware** (`/home/exedev/sycl-badge-fork`, branch `main`): its cart
serial port is what the cart talks to. On stock firmware the title's
PARTY entry is greyed with NEEDS PARTY FIRMWARE (always so in the web
simulator and badge-bench: our wasm build does not speak the fork
simulator's serial socket). The row exists only in builds with
`-Dstein_party=true` (the `party` branch's default; main leaves it out
until the fork's cart serial port ships). SPEC.md section 20 has the rules.

**Set up the laptop and the badges:**

```
cd /home/exedev/sycl-badge-fork && zig build          # zig-out/firmware/sycl-os-kernel.uf2
python3 tools/badge/badge.py flash zig-out/firmware/sycl-os-kernel.uf2 --all
# this repo, from the root:
zig build -Dcart=snoutenstein
python3 /home/exedev/sycl-badge-fork/tools/badge/badge.py install zig-out/firmware/snoutenstein.uf2 --all
python3 /home/exedev/sycl-badge-fork/tools/badge/badge.py lobby   # leave it running
```

Carts survive a firmware flash; `badge list` shows every badge and its
ports. A powered hub helps beyond four badges. Everyone is "SNOUTY" in
the roster (the badge has no text entry): the slot colour and number
tell players apart.

**On each badge:** title, Down twice to PARTY, A. The screen says START
BADGE LOBBY ON THE LAPTOP until `badge lobby` has the port open, then
JOINING... and the lobby: the room count (n/16), the rules, the roster
(two columns of eight: slot colour, name, a green tick when ready, your
own row highlighted, a Coral name on another cart version). The lowest
id hosts (HOST in the header): Up/Down picks ARENA (preselected for the
head count: Server Room up to 6, Build Farm up to 8, Data Hall beyond;
Coral when the room is over its size), FRAGS (5 to 25), BUGS, TEAMS
(FFA, 2, 4), your TEAM (team modes) and DELAY (AUTO = the suggestion
from everyone's round trips to the relay, or 2 to 12 ticks; the
suggestion stays visible beside a manual value), Left/Right changes it.
In a team match everyone picks a team with Left/Right before readying.
A readies; the host's START: GO! appears once two or more are ready
(two teams in a team match) and Start goes. A badge that joins during a
match sees MATCH IN PROGRESS and plays the next one.

**Hardware check, two badges first:**

1. Both on the fork firmware with this cart, `badge lobby` running. Both
   PARTY screens leave START BADGE LOBBY within a second; one shows HOST,
   the roster lists 2/16 on both.
2. Host changes each rule; the guest's screen follows within a frame or
   two. TEAMS 2: each badge's Left/Right moves its own swatch between
   RED and BLUE on both screens.
3. A on both, host Start: both start at once, each from its own slot. The
   other badge is a tinted rival with its slot number over its head
   within 6 cells; the HUD shows #rank/2 and TOP; the kill feed line at
   the top agrees on both badges (FRAGGED P2 here is P1 FRAGGED YOU
   there).
4. Hold Select: the scoreboard on both, same numbers.
5. Start on either pauses both; Start resumes. B in the pause on one:
   it returns to its lobby, and the other ends with YOU WIN: FORFEIT
   (one human left; with three or more a bot takes the leaver's slot,
   "P2 LEFT: BOT", and the match goes on, still paused until someone
   presses Start).
6. Unplug one badge's USB mid-match: the other hands the slot over on
   the same tick and ends as above; the unplugged badge (on battery) goes
   back to START BADGE LOBBY when its port closes.
7. A DESYNC band is a bug: note the arena, the head count and roughly
   when. YOU WERE DROPPED (a badge silent for 3 s while the others
   waited) should not happen with badges that keep running; report it
   with what that badge was doing.

**Then N badges (4, 8, 16):** as above with everyone in; watch for
WAITING FOR PLAYERS lasting more than a moment (the relay or one badge
cannot keep up: try DELAY 4 or 6), Data Hall preselected beyond 8
players, and the 16-row scoreboard (two columns). Report the worst
stutter and the delay that felt right; M8.1 tunes the default delay and
the stall-drop time from that.

**Without the network** (simulator, previews, bench) a local match of
bots stands in, one tick a frame: `debug_party_bots:V` (V: rules byte 0
in bits 0-7, as section 7's R plus bit 5 = 25 frags; team mode in bits
8-9, 0 FFA, 1 two teams, 2 four teams; players in bits 16-20, 0 = 16;
the shown slot in bits 24-27), `debug_party_view:S` (show slot S, also
with `--call-at`), `debug_party_names:1` (sample names instead of
P1..P16) and `debug_party_lobby:K` (the lobby as 1 a host of 9, 2 a
guest of 16 in 4 teams, 3 a late joiner, 4 no laptop lobby, 5 joining;
0 is the real NEEDS PARTY FIRMWARE screen). Hold Select for the
scoreboard.

```
node ../../tools/preview.mjs ../../zig-out/bin/snoutenstein.wasm --frames 1200 --every 6 --out out/party \
  --call debug_party_names:1 --call debug_party_bots:$((0x16)) --call-at "600 debug_party_view:5"
```

The bench pokes `stein_party_bench` (the same V with bit 31 set):
`tools/bench_m8.sh` runs 16 bots on Data Hall and on Server Room, BUGS
ON.
