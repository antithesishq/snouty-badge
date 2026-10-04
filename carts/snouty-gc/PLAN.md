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

## M1 Guns and racers

Goal: a 3-lap Quick Race with any racer is a real fight. SPEC 4 (roster,
own cars, portraits, bios, taunts), 5.3 (armor, ramming, wrecks, hulks,
respawn, smoke) and 6.1, 6.2, 6.5 (all 8 equipped weapons, AI aim and
drop). Pickups are M2.

### M1.0 Interface (lead, committed before the tracks start)

`world.zig` gains `Front`, `Rear`, `Projectile` (pool of 48), `Drop` (pool
of 32), `Event` (ring of 16, `event_seq`), `no_car`, `Wreck.armor` and
`.zero_day`, and the `Car` combat fields (`armor`, `front`, `rear`, levels,
ammo, `fire_cd`, `charge`, `lock`, `last_hit_by`/`last_hit_ticks`,
per-car `hitstop`, `hit_flash`, press edges, `kills`, `wrecks`).
`racers.zig` gains each racer's `front`/`rear` loadout. World is 1,940 B
(test cap 2,560: no rewind copies, so it only bounds the M4 CRC).
Contract:

- Only `sim.simulate` writes these. Rendering reads the pools and the
  event ring with its own cursor (`last_seq` in main.zig) and never writes.
- **Events** are the only way the presentation learns about one-off
  happenings: `hit` (attacker, victim, damage) for `ACK` and the hit flash,
  `wreck` (victim, killer or `no_car`, cause) for the kill feed and the
  taunt pop-ups, `lance` (owner, target, length) for the beam,
  `explode` (car, radius, x, y) for explosions, `respawn`.
- **Hit-stop is per car** (deferred question 2 settled): the wrecked
  car freezes 12 ticks; the world never stops, so a link race never
  freezes both badges. The shake is render-side, on the victim's badge.
- A wrecked car stays where it died as a burning **hulk** for the first
  90 ticks of its WATCHDOG delay and blocks like a wall, then vanishes
  until the respawn.

### Track A: combat simulation (Opus agent, worktree /home/exedev/snouty-badge-gc, branch gc/spec)

Owns `world.zig` (beyond the interface: may add fields, must not rename
or remove interface ones), `sim.zig`, new `weapons.zig`, `ai.zig`,
`tuning.zig`, `racers.zig` gameplay fields (`Crew` characters, SPEC 4.3),
`sim_test.zig`, new `weapons_test.zig`.

1. Armor from chassis, damage, kill credit (last hit within 180 ticks,
   else a fall is uncredited), ramming damage by mass and relative speed
   with MAINFRAME's front-quarter plough x2, wreck at armor 0, per-car
   hit-stop, hulk, WATCHDOG respawn with full armor and kept ammo, 60
   ticks of immunity, `kills`/`wrecks` tallies, events.
2. The 4 front weapons and 4 rear weapons exactly as SPEC 6.1/6.2, with
   per-lap ammo refill on the start line, Down+A rear, and A/Down+A not
   braking. Projectiles: walls kill them (spark = `explode` radius 0),
   they pass under airborne cars, they never hit their owner. FIBER LANCE
   is hitscan along the heading. SPEAR PHISH lock in a 24-degree cone
   within 400 px, homing at 600 turns/tick.
3. AI aim and drop (SPEC 6.5) per crew character, deterministic from the
   world PRNG.
4. Scenario tests for each weapon (hits, damage, ammo, refill, cooldowns,
   lance fizzle, phish lock and homing, bomb arming, leak growth and
   expiry, caltrops consumed, firewall damage per tick), ramming, wreck,
   hulk, respawn, kill credit; a seeded 6-AI combat soak of 20 races that
   all finish with no car stuck for more than 600 ticks and no pool
   overflow (slots are reused or the oldest is dropped, never an
   out-of-bounds write); determinism with combat on.
5. Keep the cart building and the M0 gate green throughout (render code
   does not draw the new pools yet: Track B does). Commit with
   `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, push gc/spec.

### Track B: presentation (Opus agent, worktree /home/exedev/snouty-badge-gc-present, branch gc/present off gc/spec 7b2d1eb3)

The art landed (merged 3c6a5356; `ASSETS.md` lists every sheet, its cells,
and the lines for `build.zig`). Track B owns `main.zig`, new `select.zig`,
new `roster_text.zig` (bios, taunts, wrecked lines; SPEC 4.1 table,
SYSADMIN line 2 = `MACHINES WOKE UP.`), new `fx.zig`, `hud.zig`,
`sprites.zig`, `camera.zig`, `menu.zig`, `results.zig`, the look-back and
jitter hooks in `render.zig`, `build.zig`, `tools/scripts/`, `docs/`.
It must not edit Track A's files (`world.zig`, `sim.zig`, `weapons.zig`,
`ai.zig`, `tuning.zig`, `racers.zig`, `sim_test.zig`, `weapons_test.zig`).
It renders only from the M1.0 interface, so the two merge cleanly.

1. **Wire the art** into `build.zig` per ASSETS.md (the art `fx.png`
   clashes with Zero's `fx.png` by name: rename one module symbol). Drop
   the placeholder re-paletted machine sprite and Zero's sheets the cart
   no longer uses.
2. **Cars**: each racer's own sheet. Pick the cell from the angle between
   the camera and the car heading (rear, rear quarter, side; mirrored for
   the other side), the airborne cell while `hop > 0`, the wreck cell plus
   flames from `fx` for the hulk (the first 90 ticks of a wreck), nothing
   after that until the respawn, blinking while `immune`, a white hit flash
   while `hit_flash`. Smoke puffs below 50% armor and black smoke with
   sparks below 25%, render-side in `fx.zig`.
3. **The 64-object depth list** in `sprites.zig`: cars, projectiles
   (`weapons.png` cells, SPEAR PHISH by view), drops. Flat drops (puddle,
   caltrops, firewall base) go through a **non-uniform scaled blit**
   (height x squash) so they lie on the floor; the firewall flames stand
   up. Farthest culled first.
4. **Effects from events** (`fx.zig`, render-side particle ring, cursor
   over `World.events` by `seq`, never written back): explosions (4
   frames), sparks (radius 0), the FIBER LANCE beam (6 frames, a 1 to 2 px
   line from car to target or along the heading for `length` px), muzzle
   flash, respawn flicker. The fish-hook reticle on the followed car's
   `lock` target (`hud.png`), and the charge glow while `charge > 0`.
5. **HUD** (SPEC 10 layout, 4 px margins): lap, rank, armor bar
   green-to-red, front ammo count and rear ammo pips, burst pips, the kill
   feed line from `wreck` events (`KILLER > VICTIM`, or `VICTIM` plus the
   cause for a fall), `ACK` above the victim on the followed car's `hit`
   events, and the **taunt pop-up** (a 24x24 half-scale portrait plus the
   line, top left, 90 ticks): the killer's taunt when they wreck the
   followed car, and the victim's wrecked line when the followed car makes
   the kill. Per-car messages for wrecks (`WRECKED BY SYSADMIN`,
   `SEGMENT FAULT`).
6. **Racer select** (`select.zig`, SPEC 8.1, matching
   `docs/art_select_mock.png`): portrait, name, car, the car turning on
   its yaw cells, SPD/ARM/DMG bars, the two weapon names with the `A` and
   `↓A` glyphs, the bio, `< A PICK >`. The flow is Title, then Start, then
   select (A picks), then the track row (one track for now, Left/Right is
   ready for more), then the countdown. The picked racer drives car slot
   `human = 0`; the other five are AI. The splash uses Snouty's
   eyepatched portrait. Results show each row's half-scale portrait, and
   the winner's full portrait and taunt.
7. **Look back** while Select is held (camera yaw + 180 degrees, own car
   hidden, `BEHIND` over the horizon), render-side only.
8. **A render stress scene**: a debug export that fills the World pools
   (six cars on screen, all projectile kinds, every drop kind, two
   explosions) without the sim, and `tools/scripts/m1_render_stress.json`,
   benched worst frame (plain and `--lcd`) recorded in "M1 status".
   Preview scripts for the select across all six racers and a race.
9. `tools/check.sh` green in the worktree, commits on `gc/present` with
   the `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` line,
   branch pushed. The lead merges `gc/present` into `gc/spec` after
   Track A lands and runs the integrated gate.

### M1 gate

`tools/check.sh` green; weapon scenario tests and the combat soak pass;
the stress bench script (six cars on screen, every weapon firing, two
explosions) under 8 ms worst; `docs/preview_m1.gif` with a racer select
and a real fight; tag `snouty-gc/m1`; merged to main.

### M1 status

- 2026-10-04: **Track A (combat simulation) DONE** on `gc/spec`. New
  `weapons.zig` (firing from the race byte, the projectile and drop pools,
  hit resolution, the SPEAR PHISH lock, the event ring writer) and
  `weapons_test.zig`; `sim.zig` gains armor and `damage`, `wreck` with
  kill credit, ramming by mass and closing speed with MAINFRAME's plough,
  wall damage by impact, hulks, per-car hit-stop, respawn with full armor
  and kept ammo, the per-lap ammo refill, and calls into the weapons and
  the AI aim; `ai.zig` crews gain SPEC 4.3/6.5 characters (target
  preference, reaction delay, aim noise from the world PRNG, drop rules,
  LEGACY rams, ROOTKIT stalks, everyone steers round a FIREWALL, LANCE
  charged on straights). Every number is in `tuning.zig` (SPEC values where
  SPEC gives one, the dangerous side where it does not). Interface: no
  field renamed or removed; added `Car.rot_ticks`, `rear_cd`, `on_leak`,
  `aim`, `aim_ticks`, `World.combat`, `Setup.combat` (default true; false
  only for the completable tests, SPEC 12). `Car.a_was` holds "A without
  Down" last tick. Render-side helpers: `sim.is_hulk(c)` (draw the burning
  hulk: `sprites.draw_cars` still hides every wrecked car),
  `weapons.projs_live`/`drops_live`.
- Events as M1.0 specified: `hit` (attacker or `no_car` for a wall/hulk,
  victim, damage; damage under `hit_event_min` = 2, i.e. a FIREWALL tick,
  logs only when no hit flash is running), `wreck` (victim, killer or
  `no_car`, `Wreck` cause), `lance` (owner, target or `no_car`, length px
  capped at 255: the beam reaches 300, so use the event's x, y end point),
  `explode` (`a` = the wrecked or hit car or `no_car`, `b` = radius px: 24
  for a wreck and a LOGIC BOMB, 12 for a SPEAR PHISH hit, 0 for a spark on
  a wall or hulk), `respawn` (car). An armor wreck sets no per-car
  `Message` (the `Message` enum belongs to hud.zig's switch): the
  presentation keys its text on the `wreck` event.
- Tests (`zig build test-gc`): **51 pass** (25 before). New in
  `weapons_test.zig`: PING (cadence, damage, ammo per volley, range, never
  the owner, empty), BROADCAST (fan, damage, knock, cooldown, reach), FIBER
  LANCE (fizzle free, charge cap, hit, miss off the line, first car in line
  takes it, a wall stops it), SPEAR PHISH (lock cone, range, behind, nearest,
  not on wrecks; homing within 600 turns/tick hits a dodging target; no lock
  flies straight; 3 a lap), shots pass under airborne and immune cars and
  spark on walls and hulks, rear press edge and cooldown (Down+A never fires
  the front), LOGIC BOMB (arming, trigger, blast radius, push, spares cars
  outside 24 px), MEMORY LEAK (growth 6 to 18, slick and yaw kick, expiry at
  600), BIT ROT (row, damage per caltrop, consumed, slow), FIREWALL (1 a
  tick inside, nothing beside, no event flood, expiry), pools at cap reuse
  slots, ramming (formula both ways, plough x2 from the front only, grazes
  free, combat off), wreck (credit, events, hit-stop while the world runs,
  hulk blocks a car driven at it for 90 ticks, respawn at 120 with full
  armor, kept ammo, immunity), kill credit (180-tick window, falls, walls,
  own drops), loadouts and the line refill, combat off, AI aim and
  reaction, target preference (BOTNET the leader, SYSADMIN the human),
  drops (KIDDIE on its line, LEGACY wide), LANCE charge and release,
  firewall dodge; determinism with combat (a seeded 6-AI fight twice, two
  worlds interleaved with both humans firing). The M0 random-input
  determinism tests now run with combat on.
- **Soak** (20 seeded 6-AI races, combat on, run until all six finish):
  all finish in 6,641 to 7,962 ticks (the clean autopilot needs 4,968 for
  3 laps); longest no-progress run **228 ticks** (gate 600); pools peak at
  21 of 48 shots and 32 of 32 drops (BIT ROT's six caltrops a drop; the
  oldest is reused); 19 wrecks a race on average (374 in all; 1 fall),
  every car wrecked 1 to 8 times; up to 741 events a race. The SNOUTY
  autopilot as the human in a full combat race (10 seeds): mean finish
  6,222 ticks, 4 wrecks a race, ranks 2 to 6. Damage by source over those
  10 races: BOTNET 6,574, SNOUTY 4,271, SYSADMIN 3,961, LEGACY 3,000,
  KIDDIE 2,712, ROOTKIT 1,483, walls and hulks 395.
- **`@sizeOf(World)` = 1,964 B** (Car 84; cap 2,560).
- Gate: `tools/check.sh` green (build, test via test-gc, check-float,
  tracks, preview, bench). Bench on the re-recorded `m0_race.json` (600
  frames, combat on): mean 3.08 ms, worst 3.92 ms (frame 20, the race
  start), `--lcd` identical; `sim.simulate` (with the weapons and AI aim
  inlined) is 2.4% of cycles. The stress scene is Track B's script.
- Changes outside Track A's files, for the gate: `tools/check.sh` (the
  preview's World bound 1024 -> 2560, matching sim_test's cap, since the
  M1.0 pools already made it 1,940 B; the "no car wrecked when the results
  come up" expectation dropped, as combat makes it legitimate) and
  `tools/scripts/m0_race.json` re-recorded with `tools/record_script.py`
  (the autopilot now fires, so the M0 recording no longer replayed its
  race).
- 2026-10-04: **Track B (presentation) DONE** on `gc/present` (gc/spec
  with Track A merged in; not merged back, not tagged). The art is wired
  (`build.zig` per ASSETS.md; Zero's `fx.png` renamed `exhaust.png` for
  the BURST flame, `machine.png` and `snouty_head.png` retired) and every
  sheet goes through one runtime `sprites.Sheet` and blit with separate
  width and height. New `select.zig`, `roster_text.zig` (bios, taunts,
  wrecked lines, weapon names, HUD liveries, stat bars; host-tested),
  `fx.zig`, `stress.zig`. **Cars**: the racer's own sheet, cell from the
  camera-to-heading angle (rear under 22.5 degrees, quarter under 67.5,
  else side, mirrored for the left; no front view exists), the followed
  car leans into its steer, airborne cell while `hop`, `sim.is_hulk` draws
  the wreck cell with flames, immunity blinks, `hit_flash` white, a lance
  charge glows (faster, then white when full). **Depth list**: cars,
  projectiles (PING, BROADCAST, SPEAR PHISH by view), drops (MEMORY LEAK
  and BIT ROT as squashed decals, LOGIC BOMB dark until armed then
  blinking, FIREWALL as 16 px segments of bricks with standing flames) and
  particles, sorted far first on u32 keys, 64 drawn, the farthest culled
  first except cars (never culled). **fx.zig** reads the event ring with
  its own `last_seq` (never writes): explosions (radius from `explode`),
  sparks, respawn spark ring, grey smoke under 50% armor and black smoke
  with sparks under 25% and from hulks, muzzle flashes when `ammo_front`
  drops, lance beams (12 projected points from the owner to the event's
  x, y, 6 ticks), the kill feed, taunt pop-up, ACKs, the wreck note
  (`WRECKED BY X`, `ZERO-DAY`; a fall keeps the sim's `SEGMENT FAULT`),
  the armor-bar flash and a 12-tick shake on the victim's badge.
  **HUD** (4 px margins): LAP left, rank centre, the empty pickup box
  (roulette blank) right; feed y 23; pop-up y 33 (24x24 portrait, name,
  the line wrapped at 15); message bar y 62; bottom left (all left of x
  61, clear of the car sprite): MPH, `A` + front count + BURST bolts,
  `Down+A` + rear pips, armor bar 40x4 green/yellow/red; minimap with
  the art liveries, wrecked cars blink; SPEAR PHISH reticle on `lock`;
  `BEHIND` while looking back. The race clock left the race HUD (SPEC 10
  has none; results keep the times). **Flow**: splash (Snouty's
  eyepatched portrait at 2x), title, Start to the **racer select** (as the
  mock: Left/Right racers, Down to the track row, A or Start races, B to
  the title), countdown, race, results (the winner's card, then the field
  with 24x16 portrait bands, best lap, time, kills, wrecks), then the
  select again. M0's QUICK RACE/SOUND menu is gone; Sound is in pause.
  The picked racer drives car `human = 0`. **Look back** (Select held):
  the camera turns round `cam_behind` ahead of the car for that frame
  only, the hills march backward (`hills.backward`), own car hidden.
  **Stress scene**: `export var gc_stress` (bench `--poke gc_stress=1`) or
  the wasm `debug_stress:1`: six cars in view (a hulk, a hit-flasher, a
  charger, a smoker), all 48 projectiles, all 32 drops (8 FIREWALLs = 40
  segments), two explosions, a beam, a hit and a wreck event every 30 / 90
  ticks, the view sweeping +-14 degrees; 125 to 136 objects gathered, 64
  drawn. `tools/scripts/m1_render_stress.json` holds Select 400..460.
- Track B bench (calibrated, 600 frames): **stress mean 4.72 ms, worst
  5.13 ms** (frame 94; p95 5.06), `--lcd` identical; look-back frames 3.2
  ms (22 objects). The sprites cost about 1.6 ms of it: `blit_rect` 26%
  of cycles (85 blits a frame), the list (gather, project, sort) 0.4 ms;
  SPEC 18's 64-object estimate of 1 ms holds for the blits alone. Two
  cheapenings: the list sorts u32 keys (distance << 8 | slot) instead of
  entries, and `hills.height_ahead` caches the height under the camera
  (it was two 64-bit divides per projected point; 192 a frame).
  `m0_race.json` (a real combat race): mean 3.69 ms, worst 4.92 ms (frame
  285), `--lcd` identical (Track A alone 3.08 / 3.92). RAM ELF `size -A`:
  **.text 136,636 + .data 6,676 + .bss 29,804** (+ 592 exidx/extab/
  descriptor) = 173,708 B: **100,468 B (98 KB) free** under the 274,176 B
  window less the stack. `tools/check.sh` green: it now also runs a select
  preview (Start, Right x3 = SYSADMIN, B, Start, Left = BOTNET, A races
  car 5), a stress preview (64 drawn of more gathered) and the stress
  bench plain and `--lcd` under 8 ms. `docs/preview_m1_select.gif` (splash,
  title, all six racers, the track row, the pick) and
  `docs/preview_m1_race.gif` (an autopilot combat race: wrecks with the
  taunt pop-up, the kill feed, the reticle, a MEMORY LEAK, look back).
  Deferred questions 24 to 31.

## M2 Pickups

Goal: RMA crates on the track, the roulette, rank-weighted rolls and the
15 non-league pickups of SPEC 6.3 with their gags, AI pickup policies
(SPEC 6.5 item 3). PROMPT INJECTION waits for the Perimeter league.

### M2.0 Interface (Track A, committed before the pickup behaviour)

Same contract as M1.0: only `sim.simulate` writes these; rendering reads
the World, the pools and the event ring (its own `seq` cursor) and never
writes. Nothing was renamed or removed; `proj_count` went 48 -> 40 (the
M1 soak peaked at 21; the new `Projectile.seg` byte made a slot 20 B) and
`drop_count` 32 -> 40 (room for a FORK BOMB's 8). World 2,436 B (Car 112),
under the 2,560 cap.

- **`world.Pickup`**: SPEC 6.3 table order, `prefetch = 0` ..
  `prompt_injection = 15`, `none = 16`, so `@intFromEnum(p)` is the
  `pickups.png` cell and `none` is the roulette blank (cell 16). Tiers:
  A `prefetch`..`spaghetti`, B `fork_bomb`..`race_condition`, C
  `kernel_panic`..`zero_day`. `prompt_injection` never rolls on the Dumps.
- **Car** (timers in ticks, 0 = off): `pickup` (held; while `roll_ticks
  > 0` it is the roulette's hidden result: draw `FETCHING...`, B does
  nothing), `roll_ticks` (45 at a crate), `zero_day_used`, `b_was`;
  `prefetch` (boost), `duck` (u16, RUBBER DUCK on its tether), `patch`
  (HOT PATCH repairing), `tangle` (SPAGHETTI: held to 40%) then `strand`
  (dragging a cable strand, -10%), `spin` (HONEYPOT spin-out), `bit_flip`
  (Left/Right swapped: the HUD blink and the 1 px jitter on a human's
  badge), `chain` + `chain_ticks` (DEADLOCK: chained to car `chain`, or to
  the nearest wall when `chain == no_car`), `heisen` (HEISENBUG: draw on
  odd frames only), `frozen` + `frozen_by` (`Freeze.panic`: KERNEL PANIC;
  the blue screen is the first 30 of its 90 ticks, i.e. `frozen > 60`),
  `captcha` (ticks until freed) with the mini-game `captcha_cursor`
  (0..8, row-major 3x3), `captcha_lit` and `captcha_done` (9-bit cell
  masks: traffic lights, cleared), `sudo` (u16, root: the `#`),
  `swap_with` + `swap_ticks` (RACE CONDITION tearing on both cars, then
  the swap).
- **Projectiles**: `ProjKind.panic`, the KERNEL PANIC packet (`target` =
  the car it runs to; `seg` = the centerline sample it runs toward,
  internal; velocity gives its heading).
- **Drops**: `DropKind.fork` (one `&`; `size`/`dir` internal), `honeypot`
  (the fake crate: alternate `pickups.png` cells 18/19 on odd frames),
  `spaghetti` (the 24 px tangle, flat).
- **DDOS drones**: `World.drones: [8]Drone` (`state` none/flying/orbit,
  x/y Q16, `owner`, `target`, `ttl`, `angle`); the target's speed reading
  stutters while any drone orbits it.
- **Crates**: positions come from the track: `track.crate_spots[0..
  track.crate_n]` (world px, filled by `track.select` from the centerline
  samples flagged `track.flag_crates`); `World.crates[k]` is spawn k's
  respawn timer, 0 = the crate is there (draw `pickups.png` cell 17).
- **Events** (`EventKind` gains `roll`, `use`, `effect`, `swap`; see the
  field comments in `world.zig`): `roll` (car, rolled pickup, crate index;
  x, y the crate) when a car takes a crate; `use` (user, pickup, target or
  `no_car`; x, y where it lands or strikes) when B uses one; `effect`
  (source or `no_car`, affected car, pickup; x, y the affected car) for a
  one-off impact: KERNEL PANIC hit, BIT FLIP strike, DEADLOCK chain (one per
  chained car), DDOS swarm arrival, HONEYPOT burst (`<honey>` tags),
  SPAGHETTI tangle, RUBBER DUCK popped (affected = the duck's owner),
  ZERO-DAY (plus its `wreck` event, cause `zero_day`); `swap` (the two
  cars) the tick a RACE CONDITION trades them. A shot-down drone or a drop
  destroyed by SUDO is an `explode` of radius 0 (a spark); a FORK BOMB hit
  is an `explode` of radius 8.
- **Render-side helpers** (pure reads, in `pickups.zig`):
  `duck_pos(c)` (the duck's world position behind its car), and
  `chain_anchor(w, i)` (the far end of car i's chain: the partner, or the
  nearest track edge for a wall chain).

### Track A: pickup simulation (Opus agent, worktree /home/exedev/snouty-badge-gc, branch gc/spec; starts while M1 Track B is still running)

Owns what M1 Track A owned (`world.zig`, `sim.zig`, `weapons.zig`,
`ai.zig`, `tuning.zig`, `racers.zig` gameplay, `sim_test.zig`,
`weapons_test.zig`), plus new `pickups.zig` and `pickups_test.zig`,
`track.zig`'s data accessors (not the renderer's league slices), and
`tools/build_tracks.py` plus `cart/src/tracks/*.track` and the generated
track `.bin`s for the crate rows. It must not edit M1 Track B's files
(see M1 Track B). M1 Track B merges `gc/spec` in before it finishes.

1. **M2.0 interface first**, as its own commit before the behaviour, and
   documented here under "M2.0 Interface": the World and Car fields the
   presentation will read. That means `Car.pickup` (an enum in SPEC 6.3
   order, plus `none`), the roulette ticks, per-car status timers (bit
   flip, deadlock partner and ticks, captcha with the human mini-game
   state: cursor cell, lit mask, cleared mask; sudo, heisenbug, prefetch,
   spaghetti drag, frozen with the KERNEL PANIC cause, the rubber duck),
   crate state (positions come from the track; respawn timers in the
   World), and new projectile, drop and event kinds: the KERNEL PANIC
   packet, a DDOS drone pool (8), FORK BOMB, HONEYPOT, SPAGHETTI,
   RACE CONDITION swap, roll result, and pickup used. Same contract as
   M1.0: only `simulate` writes, the presentation reads.
2. **Crates on the track**: a `crates` feature word in the `.track` format
   (a row of 3 or 4 spawns across the track at a centerline sample);
   `build_tracks.py` writes the crate positions into the track data; at
   least two crate rows on Landfill Loop; each crate respawns 180 ticks
   after it is taken. The generator stays byte-deterministic.
3. **Rolls**: driving through a crate with no pickup starts the 45-tick
   roulette; the result comes from the world PRNG by rank tier (SPEC 6.4).
   KERNEL PANIC is excluded for 1st, and ZERO-DAY is limited to 5th and 6th
   and once per car per race. B uses the pickup, and Down+B uses it
   backward where SPEC gives a direction.
4. **The 15 pickups** exactly as SPEC 6.3 (numbers into `tuning.zig`).
   The CAPTCHA mini-game runs in the sim from the human's input byte (A
   on a lit cell under the sweeping cursor clears it), so it plays
   identically on both badges of a link race. AIs "solve" by character
   (KIDDIE slowest). HEISENBUG makes a car untargetable by locks and the
   AI, and it passes through cars and drops. RUBBER DUCK takes homing
   targets and the first hit from behind. SUDO makes a car invulnerable,
   ramming deals 40, and drops it touches are destroyed.
5. **AI pickup policies** per crew (SPEC 4.3 and 6.5).
6. **Tests**: a scenario per pickup (SPEC 12 lists the key asserts), roll
   odds over many seeded rolls within tolerance of the table, crate
   respawn, the chaos soak extended with pickups (20 races finish, no car
   stuck for more than 600 ticks, no pool overflow), and determinism with
   pickups on.
7. Gate green, PLAN "M2 status" Track A paragraph, deferred questions,
   commits with the `Co-Authored-By: Claude Opus 5.5
   <noreply@anthropic.com>` line, push gc/spec. No tag, no merge.

### Track B: pickup presentation (Opus agent, worktree /home/exedev/snouty-badge-gc-present, branch gc/present)

M1 is tagged (`snouty-gc/m1`, on main c010781f). `gc/present` has merged
the M2.0 interface (b55a19bf), so the build fails until the two `sprites.zig`
switches handle the new projectile and drop kinds: that is the first fix.
Track B owns the same files as M1 Track B (`main.zig`, `select.zig`,
`roster_text.zig`, `fx.zig`, `hud.zig`, `sprites.zig`, `camera.zig`,
`menu.zig`, `results.zig`, `stress.zig`, `render.zig` hooks, `hills.zig`,
`build.zig`, `tools/scripts/`, `docs/`), and never edits Track A's
(`world.zig`, `sim.zig`, `weapons.zig`, `pickups.zig`, `ai.zig`,
`tuning.zig`, `racers.zig`, `track.zig`, the tests, `build_tracks.py`,
the `.track` files). It renders only from the M2.0 interface and merges
`gc/spec` in again whenever Track A pushes behaviour.

1. **HUD pickup box** (top right): the held pickup's `pickups.png` cell,
   the roulette while `roll_ticks > 0` (cycling cells, caption
   `FETCHING...`, landing on the hidden result at 0), blank when empty.
2. **World objects** in the depth list: crates (cell 17, hidden while the
   respawn timer runs), the HONEYPOT crate (cells 18/19), FORK BOMB `&`,
   SPAGHETTI tangle (flat), the KERNEL PANIC packet, DDOS drones, the
   RUBBER DUCK at `pickups.duck_pos`, DEADLOCK chain lines to
   `pickups.chain_anchor`, the cable strand behind a stranded car.
3. **Car states**: HEISENBUG drawn on odd frames only, SUDO's `#` above
   the car and a flashing palette, KERNEL PANIC frozen car tinted blue with
   `:(` above it, CAPTCHA grid glyph over each captcha'd AI, RACE CONDITION
   tearing (row-offset slices of the sprite) on both cars during
   `swap_ticks`, the PREFETCH boost flame, the HONEYPOT spin.
4. **The human gags** on the followed car's badge only: the KERNEL PANIC
   blue screen while `frozen > 60` (full screen, `:(` and `YOUR RIG RAN
   INTO A PROBLEM`, about 30 ticks), BIT FLIP (the HUD blinks `BIT FLIP`
   with a mirrored arrow, plus a 1 px per-row floor jitter), the **CAPTCHA
   mini-game** (a 48x48 3x3 grid centred over the floor from
   `captcha_lit`, `captcha_done` and `captcha_cursor`, with traffic lights
   in the lit cells, the cursor sweeping, cleared cells ticked, and the
   caption `SELECT ALL SQUARES WITH TRAFFIC LIGHTS` wrapped to fit, then
   `PRESS A`), DDOS (the speed reading stutters), and the pickup kill-feed
   lines (`ZERO-DAY`, `KERNEL PANIC > KIDDIE`).
5. **Effects** from `roll`, `use`, `effect` and `swap` events: the crate
   pop, the honey `<honey>` tags burst, the duck pop, the ZERO-DAY flash,
   the swap glitch. A short `use` caption over the user is optional.
6. **Stress scene** extended with pickup objects (8 drones, 8 fork bombs,
   chains, packet, crates); the stress bench stays under 8 ms worst.
7. **Previews**: `docs/preview_m2.gif` showing a FORK BOMB growing, a
   KERNEL PANIC on the player (blue screen), and a CAPTCHA solve. Add
   debug exports that force a pickup into the followed car's slot and an
   effect onto it, so the preview script can show each gag
   deterministically (render-side debug hooks only; the sim stays pure).
8. Gate green in the worktree, commits with the `Co-Authored-By: Claude
   Opus 5.5 <noreply@anthropic.com>` line, push `gc/present`. The lead
   merges both branches.

### M2 gate

Gate green; pickup scenario tests and the soak pass; stress bench under
8 ms worst with pickups in play; `docs/preview_m2.gif`; tag
`snouty-gc/m2`; merged to main.

### M2 status

(empty)

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

Taken during M1 (Track A, combat simulation):

13. **Wall bounce fixed**: Zero's rail reflection subtracts `(1 + e) vn`
    from both velocity components whatever the normal, which flings a car
    along the wall faster than it hit it. With wall damage that turned
    scrapes into 60-damage hits and most falls into the pits. GC reflects
    along the normal (`v -= (1 + e)(v.n) n / |n|^2`); Zero is untouched.
    The clean autopilot's 3 laps are unchanged (4,968 ticks).
14. **Wall damage** (SPEC 3.3 gives no number): 4 per px/tick of normal
    impact speed over 1 px/tick, so a 3 px/tick head-on costs 8. Hulks
    are walls for it.
15. **Contacts never push a car into a wall** (a hulk's push-out could
    shove a car through a two-tile wall onto the next leg), and a car more
    than its sample's half width + 32 px off the centerline is off its leg:
    a fall (SEGMENT FAULT), credited to whoever hit it last.
16. **Drops spare their owner for 60 ticks**, then hit anyone; a LOGIC
    BOMB's blast hurts every car within 24 px, its owner included.
    Unexploded bombs clear after 30 s, caltrops after 20 s (SPEC silent).
17. **Immune (respawned), airborne and finished cars**: shots pass through
    or under them and drops ignore them; finished cars neither fire nor
    take damage. The AI does not aim at immune or airborne cars.
18. **Ramming is mutual**: each car rams the other with the SPEC formula;
    closing under 0.25 px/tick deals nothing (pack grinding). The plough
    applies when the victim is within 45 degrees of the MAINFRAME's nose:
    LEGACY at 3 px/tick into a KIDDIE deals 82, a wreck in one hit.
19. **Unspecified weapon timings**: PING one ammo a twin volley; BROADCAST
    24-tick cooldown; LANCE 20-tick cooldown after a shot; SPEAR PHISH
    launched at the car's velocity + 3 px/tick, 40-tick cooldown; rear
    weapons on the Down+A press edge with a 30-tick cooldown. FIREWALL
    flame is 24 px deep (a car crossing at speed takes about 8). BIT ROT's
    slow brakes the car while it is over 80% of its top speed.
20. **Hit-stop** is only the per-car counter (12 ticks, for the
    presentation); the WATCHDOG delay runs from the wreck, not after it.
21. **AI characters** (`ai.crews`): reaction ticks / aim noise px: SNOUTY
    12 (of lock) / 2, LEGACY 4 / 10, KIDDIE 1 / 14, SYSADMIN 6 / 2,
    ROOTKIT 8 / 4, BOTNET 6 / 8. SYSADMIN prefers humans, BOTNET the
    leader, the rest the nearest. A braking AI does not fire; a LANCE
    holder that must brake lets go (a charged beam fires blind).
22. **Ammo refills only on a credited lap** (the sectors seen), so backing
    over the line does not reload.
23. **Balance** is left where the soak puts it (19 wrecks a 6-AI race; the
    autopilot human wrecked about 4 times a race and about 21 s slower than
    a clean race). Adrian's play test sets the numbers in `tuning.zig`.

Taken during M1 (Track B, presentation):

24. **Flow**: Title, Start, the racer select, A races (SPEC 8.1's "two
    presses"); the track row is reached with Down on the select (one track,
    Left/Right ready). M0's main menu (QUICK RACE, SOUND) is gone until
    the M3 modes need a menu; the sound toggle lives in pause. Pause QUIT
    and the results go back to the select.
25. **No race clock in the race HUD** (SPEC 10 lists none and the pickup
    box took its row); the results show finish times and best laps.
26. **Rank in the top centre**, the pickup box drawn empty (the roulette
    blank) from M1 so the layout is final; feed at y 23 and pop-up at y 33
    (under the box, not y 8 as SPEC 10's table has it: the 8x8 font needs
    the rows), message bar moved from y 56 to y 62.
27. **Cars are never culled** by the 64-object cap; among the rest the
    farthest go first.
28. **No front view**: past 67.5 degrees off the camera every car (and
    SPEAR PHISH) shows its side view, mirrored by the nose's side.
29. **Results** are two cards (the winner's, then the field) because six
    half-scale portraits and the winner's full one do not fit 128 px; the
    rows show a 24x16 band (portrait rows 8..39) at half scale.
30. **Liveries**: the HUD (minimap, select, results, feed) uses the art
    track's suggested colours (`roster_text.color`); `racers.livery` (the
    M0 placeholders, sim side) is unused by rendering now.
31. **Effects mapping**: a `hit` sparks on the victim, `ACK` only over cars
    the followed car hit; a `wreck` makes no explosion of its own (the
    sim's `explode` radius 24 follows it); explosions are drawn 1.5 x
    radius + 8 world px across; the muzzle flash keys on `ammo_front`
    dropping.
