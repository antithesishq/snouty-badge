# Snouty GC: plan

`SPEC.md` is the design. This file is the contract for the milestone being
built, detailed enough that parallel tracks (Opus agents) can work without
talking to each other. Status lines go at the bottom of each milestone
block. Decisions taken without Adrian are listed under "Deferred questions"
at the end, so he can override them in one pass.

Build approved by Adrian on 2026-10-04: "go ahead and build", using
subagents, progressing through the milestones until blocked on feedback,
decisions or device testing.

## File layout (target; M0 creates the engine half, the art track the art half)

```
carts/snouty-gc/
  build.zig              pub fn add: RAM cart (+ the XIP build every cart has), host tests, check-float
  CLAUDE.md              cart notes for agents (modules, gates, commands)
  SPEC.md, PLAN.md, ASSETS.md (art), ASSETS_ENGINE.md (Zero's placeholder sheets)
  cart/src/main.zig      start/update, state machine, wasm shims, debug exports
  cart/src/fixed.zig     Q16.16, sin/cos, xorshift Rng            (Zero)
  cart/src/gen/sin.zig   committed sine table                      (Zero)
  cart/src/font.zig      8x8 font blit                             (Zero)
  cart/src/input.zig     buttons -> the 8-bit race input byte (SPEC 5.1)
  cart/src/camera.zig    follow camera, look back                  (Zero)
  cart/src/render.zig    Mode 7 floor, horizon, fog, shake         (Zero)
  cart/src/hills.zig                                               (Zero)
  cart/src/sprites.zig   scaled blit, depth list                   (Zero)
  cart/src/track.zig     embedded league art + track data, LZ unpack (Zero)
  cart/src/tracks/*.track
  cart/src/world.zig     World: 6 cars + pools, no pointers
  cart/src/sim.zig       simulate(world, inputs: [2]u8)
  cart/src/ai.zig        centerline AI, crews, autopilot           (Zero, extended)
  cart/src/racers.zig    roster table (SPEC 4.1)                   (M0 chassis, M1 the rest)
  cart/src/weapons.zig, pickups.zig, fx.zig                        (M1, M2)
  cart/src/hud.zig, menu.zig, select.zig, results.zig              (Zero / M1, M3)
  cart/src/net.zig                                                 (M4)
  cart/src/garage.zig, career.zig                                  (M5)
  cart/src/tuning.zig    every gameplay constant
  cart/src/host_tests.zig, sim_test.zig
  cart/build/convert_gfx.zig   per-cart copy
  assets/gen/            generated, committed (tracks, tilesets, horizons, font, sprites)
  assets/gen/art/        the art track's sheets (portraits, cars, weapons, pickups, fx)
  tools/build_tracks.py, tools/leagues.py, tools/gen_sin.py, tools/gen_font.py   (Zero)
  tools/draw_art.py      the art track's generator (portraits, cars, weapons, pickups, fx)
  tools/scripts/*.json   preview.mjs / badge-bench input scripts (tools/record_script.py)
  tools/check.sh         the cart gate
  docs/RUNNING.md, docs/*.gif, docs/*.png
badge-bench/carts/snouty-gc.toml
```

## M0 Fork

Goal: a playable 6-car race on Landfill Loop in the Dumps, on Zero's engine
with no rewind, plus the cart's whole art set drawn in parallel.

### Track A: engine fork (worktree /home/exedev/snouty-badge-gc, branch gc/spec)

Owns everything in the layout except `tools/draw_art.py`, `assets/gen/art/`
and `ASSETS.md`'s art section.

1. Copy Zero (`carts/snouty-zero` at origin/main) into `carts/snouty-gc`,
   with a provenance line at the top of each copied file
   (`//! Forked from snouty-zero/<file> at <sha>.`). Rename the binary,
   the module names and the debug exports. Register the cart in the root
   `build.zig`, the root `CLAUDE.md` cart list, and
   `badge-bench/carts/snouty-gc.toml`.
2. Strip what this cart doesn't have: `history.zig` and every rewind
   path, Overclock and the thermal bar, traffic, Zero's nine tracks and
   three leagues, the Grand Prix and machine select. Keep the menu
   skeleton, splash, title, pause and results as simple placeholders,
   which M1 and M3 replace. Keep the engine drone behind the sound
   toggle.
3. **Dumps league art** from `tools/leagues.py` (forked): a **128-tile**
   tileset (SPEC 13.2) with CRT-glass sand, circuit-board flats, cable
   ruts, wreckage walls, a monitor-pile background and a start line; the
   horizon pair (monitor mountains, smoke columns) and palette.
   **Landfill Loop** `.track`, 3,500 to 4,500 world px a lap, with walls,
   an open-edge pit section, a ramp and a coolant puddle. Mark where crate
   rows and a service bay will go as comments (M1 and M2 add the feature
   words).
4. **Driving**: SPEC 5.1 and 5.2. Auto-throttle, Down brake, Down+dir
   powerslide, Up burst (charges per lap), wheel grip values, all in
   `tuning.zig`. `input.zig` packs the race byte (bit 0 up, 1 down, 2 left,
   3 right, 4 A, 5 B, 6 start, 7 select). `sim.simulate(w: *World,
   inputs: [2]u8)`. The World has `cars: [6]Car`, each with
   `racer: u8` (0..5, SPEC 4.1 order: SNOUTY, LEGACY, KIDDIE, SYSADMIN,
   ROOTKIT, BOTNET), `human: u8` (0 or 1 = which input byte drives it,
   0xFF = AI) and the chassis multipliers. Nothing in `simulate` knows
   which car this badge draws; `main.zig` keeps a render-side
   `follow: u8`.
5. **Six cars** on the grid in placeholder liveries (Zero's machine
   sprite re-paletted is fine: the art track replaces it in M1), five
   driven by Zero's AI with per-racer chassis multipliers (SPEC 4.2:
   SNOUTY and SYSADMIN WORKSTATION, LEGACY and BOTNET MAINFRAME, KIDDIE
   and ROOTKIT THIN CLIENT). The player is SNOUTY until the M1 select.
   Rank, laps, minimap and results work. No weapons, no armor bar yet.
6. **Tests and gate**: host tests for trig, attribute lookups, lap
   counting, `simulate` twice from one state equals byte-for-byte, a
   2,000-tick run with random inputs equal across two runs, the
   completable test on Landfill Loop (autopilot, 3 laps, no fall, time
   bound), `@sizeOf(World)` printed. `zig build check-float`.
   `tools/check.sh` runs build, test, check-float and a preview script.
7. **Measure** (SPEC 18): `size -A` of the RAM ELF (`.text`, `.data`,
   `.bss`) and the bench (`--symbols`, and once with `--lcd`) on a
   600-frame race script, mean and worst. Holding Select alone in the
   upstream OS: read `sycl-badge/src/os` for any Select-only handling and
   record the answer.
8. A preview GIF `docs/preview_m0.gif` and `docs/RUNNING.md` (simulator
   and headless commands). Tag `snouty-gc/m0` when the gate is green.

### Track B: art (worktree /home/exedev/snouty-badge-gc-art, branch gc/art off gc/spec)

Owns `carts/snouty-gc/tools/draw_art.py`, `carts/snouty-gc/assets/gen/art/`,
`carts/snouty-gc/ASSETS.md` and `carts/snouty-gc/docs/art_*.png`. No Zig.

Every sheet is an RGB PNG with `#FF00FF` as the transparent key and at
most 15 other colours (the per-cart `convert_gfx` at 4 bits), laid out as
a horizontal strip of equal cells, as Zero's `machine.png` is. Code-drawn
in Python with Pillow, deterministic, regenerated by one command.

1. **Portraits** `portraits.png`: six 48x48 cells in SPEC 4.1 order, each
   a character, readable at 1:1 and at half scale (24x24 nearest). Each
   portrait gets its own 15-colour palette, so either use one sheet per
   portrait (`portrait_<racer>.png`) or keep a shared palette across the
   strip; ASSETS.md says which. **Snouty** comes from the study05 rig
   (`snouty-art/`, `styles/study05`; see `snouty-art/CLAUDE.md` and
   `tools/install_badge.py` for how carts take heads), with a black
   **eyepatch** over the left eye, its strap round the head, a small scar
   under it, and a squint in the other eye. LEGACY, KIDDIE, SYSADMIN,
   ROOTKIT and BOTNET as in SPEC 4.1's portrait column. These are the
   cart's personality, so they get a real art pass: distinct silhouettes,
   faces that read, a little humour in each.
2. **Cars**: one sheet per racer, `car_<racer>.png`, cells 32x16: rear,
   rear-quarter right, side right (the renderer mirrors for left), plus
   a wreck frame, plus an airborne frame. Silhouette by chassis (SPEC 4.2)
   and details by racer (ANTEATER snout prow with Snouty's eyepatched
   head in the cockpit; BIG IRON plough; CTRL-V stickers and spoiler;
   UPTIME LED rack; PERSIST matte black with lights; ZOMBIE patched bus
   with heads in the windows). Livery colours are distinct on the minimap.
3. **Weapons** `weapons.png`, 8x8 cells: PING pellet, BROADCAST pellet,
   SPEAR PHISH missile (rear, side and 3/4 views), LOGIC BOMB (`if`),
   MEMORY LEAK puddle (flat, drawn as seen from above, 16x8 in its own
   sheet `decals.png` with BIT ROT caltrop, SPAGHETTI tangle, FIREWALL base,
   cycle chip), FIREWALL flame (2 frames, 16x16 in `fx.png`).
4. **Pickups** `pickups.png`, 16x16 icons for the HUD box: the 16 pickups
   of SPEC 6.3 plus the roulette blank and the RMA crate (a 16x16 crate
   sprite, plus HONEYPOT's off-by-a-shade fake), the RUBBER DUCK sprite,
   the `&` FORK BOMB, the DDOS drone (4x4), the KERNEL PANIC packet.
5. **Effects** `fx.png`, 24x24: explosion 4 frames, smoke puff 2,
   spark 2, muzzle flash, the GC claw (24x32 own sheet `claw.png`).
6. **Screens**: `bsod.png` is not needed (drawn in code). The CAPTCHA grid
   is drawn in code. The fish-hook reticle is 12x12 in `hud.png`, with the
   lock/unlocked frames, a burst pip, an ammo pip and the `ACK` glyph if it
   reads better as art.
7. **Review**: `docs/art_contact.png`, every sheet at 3x on one page with
   labels, and `docs/art_select_mock.png`, a 160x128 mock of the racer
   select (SPEC 8.1) at 3x for each of the six racers, using the font in
   `carts/snouty-zero/assets/gen/font.bin` (96 glyphs of 8 bytes, ASCII
   32..127, bit 7 = left pixel) so the bios are seen at real size.
8. Commit on `gc/art` with ASSETS.md describing every sheet (file, cell
   size, frames, palette, what M1 must wire). The lead merges it into
   the cart branch.

### M0 gate

`tools/check.sh` green (build, `zig build test`, check-float, preview);
the completable and determinism tests pass; bench mean/worst and the RAM
figures recorded below; `docs/preview_m0.gif`; art contact sheet
reviewed by the lead; tag `snouty-gc/m0`; merged to main.

### M0 status

- 2026-10-04: Track A (engine fork) DONE, tag `snouty-gc/m0` on `gc/spec`
  (art review and the merge to main are the lead's). Forked from
  `carts/snouty-zero` at f8f6962 by copy, a provenance line on every copied
  file; Zero untouched. Stripped: `history.zig` and every rewind path,
  thermal and Overclock, traffic, Zero's nine tracks and three leagues, the
  Grand Prix, the machine select, the free camera, the column floor loop and
  the XIP-only art copy. New: `world.zig` (6 `Car`s with `racer`, `human`
  and the chassis multipliers; `Input` = the race byte; `Setup`),
  `sim.simulate(w, inputs: [2]u8)` pure in `(World, inputs)` with
  `reset(w, setup)` (AI grid order shuffled from the seed, humans at the
  back), `racers.zig` (roster, chassis, placeholder liveries; pulled forward
  from M1 because the chassis multipliers need it), per-racer AI `Crew`s,
  render-side `follow` in `main.zig` (camera, HUD, hills, engine sound all
  key on it; the attract demo follows an AI car), `input.zig` with the
  Start+Select chord mask, `tools/record_script.py` (records the
  autopilot's drive into an input script that badge-bench replays exactly),
  `tools/check.sh`, `ASSETS_ENGINE.md` (Zero's sprite manifest for the
  copied placeholder sheets). Track data at runtime: `League`/`Track` are
  structs of slices and the renderer takes its art pointers at race start
  (SPEC 19 door open).
- Driving (SPEC 5.1, 5.2): auto-throttle (thrust always on; a chassis'
  accel multiplier scales the drag too, so terminal speed depends on top
  speed alone: 3.0 px/tick WORKSTATION, 3.24 THIN CLIENT, 2.7 MAINFRAME),
  brake 0.04 (not with A or B), powerslide grip 0.88 and 1.6x yaw, grip
  0.70, coolant 0.97, BURST on the Up edge (+35% thrust, 60 ticks, one
  charge refilled per lap), walls as Zero's rails, ramps as hops (40 ticks
  airborne), a fall into a pit is a wreck: out for the WATCHDOG 120 ticks,
  then back on the last centerline sample with floor under it, 60 immune
  ticks. Contacts exchange velocity weighted by mass (MAINFRAME pushes).
- Dumps league (`tools/leagues.py`): 128-tile set (91 named) with
  CRT-glass sand, glints, shards, keys, cables, board scrap, 2x2 scrap
  heaps and monitors; the road of flattened circuit boards with cable ruts;
  wreckage walls; pit lips and pits; coolant; ramp; start line; 52-colour
  palette; horizon of monitor mountains with blinking screens over a smog
  sky with smoke columns. Landfill Loop: 20 control points, lap 3666 px,
  min radius 58 px, an open pit edge down the east side (`open:left`), a
  coolant band, the ramp and its pit on the bottom straight, the dunes
  (hill samples 127..147); crate rows and the service bay marked as comments.
  Packed map 6.5 KB.
- Tests (`zig build test-gc`; `zig build test` fails in this fresh
  worktree only in snouty-boy, snouty-lynx and snouty-genesis runners, on
  their missing test ROMs): trig, attribute lookups at known points, packed
  map round trip, lap needs both sectors (and refills BURST), simulate
  twice from one state equal field by field over 400 ticks, 2000 ticks of
  random inputs on two human slots equal across two runs (3 seeds), two
  interleaved worlds stay equal (no leak through globals), grid placement
  and chassis by racer, auto-throttle terminal speeds, Down+A does not
  brake, BURST edge and charges, a fall wrecks and the WATCHDOG respawns,
  mass-weighted contact, **completable**: the SNOUTY autopilot finishes 3
  laps of Landfill Loop at tick 4968 (best lap 1623 ticks, 27 s), 0 wrecks,
  under the 50 s/lap bound; every racer's chassis completes it; an AI-only
  race finishes with ranks 1..6. **`@sizeOf(World)` = 400 bytes** (Car 64).
- `tools/check.sh` green: build, test (fallback above), check-float, the
  generator byte-identical on rerun, preview (`m0_race.json` replay equals
  the autopilot's race; an autopilot Quick Race reaches the results with 3
  laps and no wreck pending; the attract demo starts after 10 s idle),
  bench plain and `--lcd`.
- RAM ELF `size -A`: **.text 73,956 + .data 5,036 + .bss 23,820** (+ 456
  exidx/extab/descriptor) = 103,268 B; the window less the 32 KB stack is
  274,176 B, so **170,908 B (167 KB) free** for combat, portraits, cars and
  the Runoff (SPEC 13.2 budgets 226 KB .text + 24 KB .bss in all). `.bss` is
  mostly the 16 KB unpacked map; the tileset is 8 KB.
- Bench (calibrated, `m0_race.json`, 600 frames: menus, the race from frame
  21, GO at 221, the autopilot's drive through the first corners; all six
  cars on screen at the grid): **mean 3.13 ms, worst 3.90 ms** (frame 20,
  the race start: map unpack, minimap, hills; p95 3.38), 23% of budget;
  `--lcd` identical (full-frame redraw). `render.draw` 74% of cycles
  (floor + horizon), `draw_race` 15%, the font 4%; `hills.height_ahead`'s
  64-bit divides 3% (a fast path for M5).
- SPEC 18 answers: (1) the stripped fork is 74 KB `.text` / 24 KB `.bss`
  (above); (2) `@sizeOf(World)` 400 B; (3) the 64-object sprite cost is
  M1's stress scene; (4) **Select alone triggers nothing**: the pinned OS
  (a6ce19f `src/os/kernel.zig`) acts only on Start+Select held 500 ms (stop
  the cart) and on the joystick click (FPS overlay), and current upstream
  (5955625) only on Start+Select held 500 ms (settings box, the cart gets
  no input while it is open); Select by itself reaches the cart in the
  mailbox controls, so hold-Select look-back is safe; (5) `lib/link.zig`:
  not on main yet, M4's question.
- `docs/preview_m0.gif` (the autopilot from the grid through the first half
  lap: the coolant spill, the ramp over its pit, the dunes), `docs/RUNNING.md`.

## Deferred questions

SPEC 17 holds the design defaults. Taken during M0 (Track A):

1. **Grid**: AI cars in front in a seed-shuffled order, the human(s) on the
   back row (so the player starts 5th or 6th, as Zero's F-Zero grid).
2. **Wreck in M0** is only a fall into a pit: no world-wide hit-stop
   (SPEC 5.3's 12-tick hit-stop would freeze both badges in a link race;
   M1 decides whether it is a per-car freeze), the car vanishes for the
   WATCHDOG 120 ticks and respawns on the last centerline sample with
   floor under it (a car that fell into the ramp pit comes back before the
   ramp).
3. **Messages**: the countdown reads `SCAVENGERS READY`, 3, 2, 1, `GO`; a
   car finishing reads `FINISHED`; a fall `SEGMENT FAULT` (SPEC 3.3);
   `FINAL LAP`. Per-car messages live in the Car (shown on the badge that
   follows it), the countdown in the World. Placeholders until M3.
4. **Speed readout** is `MPH` (speed x 80, so a WORKSTATION tops out near
   240); Zero's `Tb/s` belonged to its datacenter.
5. **Race end**: the race is finished when every human has finished (or,
   with no human, when the leader has); AI cars keep driving after it.
6. **Ramp pit**: the ramp keeps Zero's hop gap (a pit across the road past
   the ramp), so missing the jump is a fall; a ramp alone would only be a
   bump. Coolant is a band across the road (Zero's throttled-zone shape).
7. **Chassis grip** for THIN CLIENT 0.95 and MAINFRAME 1.05 scale the slip
   removed per tick (Zero's `grip_q8` rule), not the kept fraction.
8. **Accel vs top speed**: a chassis' accel multiplier also scales the
   drag, so it changes how fast the car gets to its top speed without
   changing the top speed (SPEC 4.2 lists them separately).
9. **Contacts** split Zero's 30% exchange by mass; no damage yet (M1).
10. **Lap time**: the autopilot laps Landfill Loop in 27 s (SPEC 5.2
    hoped for 22 s); a human with BURST is faster. `tuning.accel`/`drag`
    are the knobs.
11. **Placeholder liveries**: SNOUTY purple, LEGACY rust, KIDDIE pink,
    SYSADMIN green, ROOTKIT slate, BOTNET school-bus yellow (also the
    minimap dots), until the art track's car sheets.
12. **Select** does nothing in the M0 race (look-back is M3); the minimap
    is 32 px fixed (Zero's Select toggle is gone).
