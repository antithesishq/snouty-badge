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
  the car it runs to; `seg` = the centerline sample it runs toward and
  `ttl` = its direction, both internal; velocity gives its heading).
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
- **Render-side helpers** (pure reads, in `pickups.zig`, both returning
  a `pickups.Point` {x, y} in Q16): `duck_pos(c)` (the duck's world
  position behind its car), and `chain_anchor(w, i)` (the far end of car
  i's chain: the partner, or the nearest track edge for a wall chain).
  Also usable: `pickups.tier_of(p)`, `pickups.drones_live(w)`.

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

- 2026-10-04: **Track A (pickup simulation) DONE** on `gc/spec`: the
  M2.0 interface (b55a19bf, above) and the behaviour (cc7f56b0). New
  `pickups.zig` (rolls, crates, the 15 pickups, statuses, the KERNEL PANIC
  packet, DDOS drones, FORK BOMB forking) and `pickups_test.zig`; hooks in
  `sim.zig` (the race byte through `pickups.filter`, thrust and speed
  limits in the driving step, `control` for B and the CAPTCHA board before
  the weapons, `pickups.update` after them; SUDO in `damage` and the ram,
  HEISENBUG in the contacts, `on_wreck`, PREFETCH's wall damage),
  `weapons.zig` (the packet, drones shot down, the duck, root clearing
  drops, the new drop kinds, HEISENBUG breaking locks and homing),
  `ai.zig` (`want_use` per crew, the BIT FLIP weave, everyone ignores a
  HEISENBUG car). Crates: a `crates` feature word in `.track` sets
  centerline flag bit 2 on the sample nearest the segment middle;
  `track.find_crates` (run by `select`) puts 4 crates 20 px apart where
  the half width is at least 56, else 3. Landfill Loop has three rows (top
  straight 4, middle straight 3, after the switchback 3: 10 crates), the
  generator validates every crate on plain road and draws them in
  `docs/landfill_loop_preview.png`. No new asset file, so `build.zig` is
  untouched. Every number is in `tuning.zig` ("Pickups" and "AI pickups").
- Tests (`zig build test-gc`): **77 pass** (51 before). Roll odds over
  40,000 seeded rolls per rank: every tier within 0.3 points of SPEC 6.4
  (gate 1.5), uniform within a tier (gate 15%), no KERNEL PANIC for 1st,
  no ZERO-DAY for 1st..4th or twice a race. Crates (rows from the track,
  the roulette, B waiting for it, respawn at 180, a full car drives
  through, airborne cars pass over). A scenario per pickup: PREFETCH
  (+40%, the kick, wall damage halved), HONEYPOT (throw 60 px, drop
  behind, owner spared, 30 and a spin), RUBBER DUCK (first hit from behind,
  draws SPEAR PHISH, front shots still hurt, 600 ticks), HOT PATCH (40 over
  60 ticks, capped, clears BIT FLIP and DEADLOCK), SPAGHETTI (40% for 60,
  then -10% for 180), FORK BOMB (1, 2, 4, 8 at ticks 60, 120, 180, none at
  481, spread 60 px across the road on floor, 15 a hit), BIT FLIP (range,
  mirrored steering, 180 ticks), DEADLOCK (pair at 30%, the pull, freed on
  touch or at 150, lone car to the wall with its anchor on the edge), DDOS
  (8 drones arrive, orbit, 96 damage in 6 pulses, -20%, shot down by
  PING), HEISENBUG (lock and homing lost, AI aim ignores it, drops and cars
  pass through), RACE CONDITION (exactly two cars swap after 6 ticks; out
  of range nothing; across the start line the laps stay whole), KERNEL
  PANIC (runs 220 px in 30..50 ticks, 40 and 90 frozen, frozen car does not
  move, from 1st it runs back to 2nd, root shrugs it off), CAPTCHA (10%,
  each AI frees at its crew's tick, KIDDIE last; the human board solved in
  under 50 ticks, a wrong press clears it, 120 ticks unsolved; A on the
  board never fires), SUDO (no damage, a ram deals 40 and bounces, drops
  cleared untriggered, 300 ticks), ZERO-DAY (through duck, HEISENBUG and
  root, credited), a wreck clearing statuses. AI policies (KIDDIE at once,
  SYSADMIN's patch and duck triggers, ROOTKIT's last lap, BOTNET's leader,
  HONEYPOT and FORK BOMB behind, RACE CONDITION on the last lap within
  60 px). Determinism with pickups (a race twice, two worlds interleaved
  with humans pressing B and A).
- **Soak with pickups** (20 seeded races, half with SNOUTY on the
  autopilot as a human; the M1 combat soak also runs with crates now):
  all finish in 6,845 to 7,796 ticks; longest no-progress run **305
  ticks** (gate 600); pools peak at 18 of 40 shots, 38 of 40 drops (the
  oldest is reused), 8 of 8 drones; 469 wrecks (23 a race, M1 19). Every
  pickup rolled and used: rolls 14 (ZERO-DAY) to 59 (DDOS), uses 14 to 53;
  RACE CONDITION is the most held (48 rolled, 28 used: its trigger is the
  last lap within 60 px). The autopiloted SNOUTY finishes 2nd to 5th with
  4 to 5 wrecks a race. The autopilot's Quick Race in the wasm takes
  7,245 ticks (M1 about 6,200).
- **`@sizeOf(World)` = 2,436 B** (Car 112; cap 2,560 kept).
- Gate: `tools/check.sh` green on `gc/spec` (build, test via test-gc,
  check-float, tracks, preview, bench). Bench on the re-recorded
  `m0_race.json` (600 frames, combat and pickups on): **mean 3.10 ms,
  worst 3.93 ms** (frame 20, the race start), `--lcd` identical;
  `sim.simulate` 2.8% of cycles. RAM ELF on `gc/spec` (M0 menus, no M1
  presentation): `.text` 117,420, `.data` 7,068, `.bss` 23,884. The
  stress scene with pickups is Track B's.
- Outside Track A's files, for the gate: `tools/check.sh` (the
  autopilot Quick Race gets 9,000 frames, was 6,000) and
  `tools/scripts/m0_race.json` re-recorded with `tools/record_script.py`
  (recorded on `gc/spec`'s M0 menu flow: re-record it again after the
  integration with the M1 select). `host_tests.zig` lists the new files.
- 2026-10-05: **Track B (pickup presentation) DONE** on `gc/present`
  (M1 Track B plus `gc/spec` merged in up to 46281911; not merged back,
  not tagged). The two `sprites.zig` switches handle the M2.0 kinds.
  **World objects** in the depth list: RMA crates (cell 17, bobbing,
  hidden while their timer runs), the HONEYPOT crate (18/19 on odd
  frames), FORK BOMB `&`s at 2x that swell and flash orange in the 12
  ticks before each fork, SPAGHETTI tangles (flat decal), the KERNEL
  PANIC packet (2x, ghosts trailing), DDOS drones (2x, buzzing) and RUBBER
  DUCKs at `pickups.duck_pos`; before the list, the floor lines: DEADLOCK
  chains to `chain_anchor` (dashed two-colour links), duck tethers and the
  swaying SPAGHETTI strand. **Car states**: HEISENBUG on odd frames only,
  SUDO's gold palette flashing with `#` over the car, KERNEL PANIC's blue
  palette with `:(` over it, the CAPTCHA tag over captcha'd cars (not over
  a followed human, who plays it), RACE CONDITION tearing (four shifted
  bands, one magenta) on both cars, PREFETCH's twin flames, the HONEYPOT
  spin (the view steps round the car). The tints are luma-mapped palettes
  per sheet built at comptime (`Blit.pal`). **HUD**: the pickup box shows
  the held icon, the roulette while `roll_ticks > 0` (a decelerating reel
  of random cells, never the hidden result, caption `FETCHING...`), then
  the pickup's name for 60 ticks; pickup feed lines (`KERNEL PANIC >
  KIDDIE`, two rows when wider than the screen) and `SNOUTY <> KIDDIE` for
  a swap. **Gags** on the followed car's badge: the KERNEL PANIC blue
  screen while `frozen > 60` (full frame instead of the race: `:(` at 3x,
  `YOUR RIG RAN INTO A PROBLEM AND NEEDS TO RESTART.`, `NN% COMPLETE`, a
  fake QR, `STOP CODE: KERNEL_PANIC` and the sender as `KIDDIE.SYS`),
  BIT FLIP (`<R BIT FLIP L>` blinking between itself and its mirror image,
  each floor row jittering 0 or 1 px), the CAPTCHA card (a reCAPTCHA
  header, the 3x3 grid of road photos with traffic lights in the lit
  cells, the sweeping cursor, ticked cells, the wait bar, `PRESS A`, `TRY
  AGAIN` after a miss, `HUMAN VERIFIED` in the bar on a solve), DDOS (the
  speed reads real, real, `503`, blank), the ZERO-DAY flash (white, then a
  red frame) and red dart, the RACE CONDITION screen glitch. **Effects**:
  crate pops, `<honey>` `</honey>` `<honey/>` tags flying out of a
  HONEYPOT, the popped duck tumbling up with `QUACK`, BIT FLIP's cosmic ray
  from the top of the screen, sparks for the rest. No `use` caption.
  **Stress scene** (stress.zig): 8 crates in two rows, the 8 drones round
  a rival (then SNOUTY), 8 FORK BOMBs, a HONEYPOT, a tangle, a KERNEL
  PANIC packet, a chain, ducks, a strand, SUDO, panic, tearing and
  HEISENBUG cars, and SNOUTY's CAPTCHA board, BIT FLIP, DDOS and roulette
  in turn; 152 objects gathered, 64 drawn. **Preview hooks** (wasm only,
  documented in RUNNING.md): `debug_give_pickup`, `debug_roll_pickup`,
  `debug_give_ahead`, `debug_effect` (`stress.force_effect`: 17 gags),
  readers for the CAPTCHA board, frozen ticks and forks; autopilot mode 2
  lets the pad's A and B through (the pad alone plays a CAPTCHA).
- Track B bench (calibrated): stress (`m1_render_stress.json`, 600
  frames) **mean 5.26 ms, worst 6.34 ms** (frame 61, p95 6.17; M1 4.72 /
  5.13); `m0_race.json` mean 3.73, worst 5.04 (frame 285); new
  `tools/scripts/m2_race.json` (3,000 frames of an autopilot race with
  pickups, `record_script.py --frames 3000`) **mean 3.55, worst 5.11**
  (frame 2742); every `--lcd` run identical. The blue screen frame skips
  the floor, so it is the cheapest race frame. RAM ELF `size -A`: **.text
  178,232 + .data 7,152 + .bss 30,780** (+ 860 exidx/extab/descriptor) =
  217,024 B: **57,152 B (56 KB) free** under the 274,176 B window (M1
  Track B 173,708; Track A's pickups and this track together +43 KB).
  `tools/check.sh` green: also a gag preview (the GIF's run: the CAPTCHA
  solved by its A presses, the blue screen at frozen > 60, the `&` ahead
  forked) and the `m2_race.json` bench plain and `--lcd`. `m0_race.json`
  re-recorded on the select flow comes out byte-identical, so it stays.
  `docs/preview_m2.gif`: from frame 1300 of an autopilot race, a CAPTCHA
  on SNOUTY (a miss, `TRY AGAIN`, the solve, `HUMAN VERIFIED`), the
  roulette landing a FORK BOMB, a rival's `&` ahead, the KERNEL PANIC blue
  screen, SNOUTY frozen blue while the `&` forks into 2 and 4, and the
  drive into them. Deferred questions 44 to 54.

## M3 Content and flow

Goal: six tracks over two leagues with their hazards, GARBAGE COLLECTION
mode, and the full flow (splash, title, attract, menus, pause, results).
SPEC 3.2, 3.3, 8 and 19.4 (hazard kinds are generic from the start, so
the M7 track packs can reuse them).

### M3.0 Interface (Track A, committed before the content and modes)

Same contract as M1.0 and M2.0: only `sim.simulate` writes these;
rendering reads the World, `track`'s caches and the event ring (its own
`seq` cursor) and never writes. Nothing was renamed or removed. World
2,508 B (cap 2,560 kept).

- **`world.Mode`** `race`, `gc`, `attract` and **`Setup.mode`** (default
  `race`), copied to **`World.mode`** by `sim.reset`. `attract` is race
  rules plus the scripted KERNEL PANIC on the leader in lap 2 (the sim
  hands it out, `World.scripted` once done), so main.zig's attract demo
  only has to pass `.mode = .attract`.
- **`World.laps`**: the laps to run, from the track (`track.Track.laps`, 3
  on every built-in track). The HUD's `LAP n/3` should read it, not
  `tuning.laps`. GARBAGE COLLECTION has no lap limit.
- **`World.gc`** (`world.Gc`): `marked` (the MARKED car or `no_car`),
  `mark_ticks` (since the mark was set or passed), `sweeps` (sweep points
  the leader has passed), `collected` (bit i = car i), `survivor` (the
  winner once one car is left, else `no_car`). A collected car has
  `active = false` (so every pool, lock and the minimap skip it), keeps
  its `rank` as its final place (6th for the first one out), and its
  bit in `gc.collected`. The survivor gets `finished`, `finish_tick` and
  rank 1, and the phase goes `finished`. Sweep points: the sector 2 line
  (sample 170) and the start line, as the race leader passes them.
- **`World.hazards[world.hazard_max = 4]`** (`world.Hazard`): `kind`
  (`HazardKind`: `none`, `blast`, `mover`, `turret` and `crust` reserved),
  `state` (`idle`, `warn` = the telegraph before it acts, `active` = it
  hurts), `timer` (ticks into its cycle), `x`/`y` (Q16: a mover's current
  position; a blast's mouth), `hit` (cars hit this firing / crossing),
  `leg` (mover: 0 going A to B, 1 coming back). Slot k is driven by
  **`track.hazard_specs[k]`** (`track.HazardSpec`, `k < track.hazard_n`,
  filled by `track.select` from the track's `feat` records, like
  `crate_spots`): kind, `warn`, `size` (blast: half width of its lane;
  mover: body radius), `damage`, `x0,y0` (blast mouth / mover end A),
  `x1,y1` (lane end / mover end B), `period`, `on` (blast firing ticks),
  `phase`, `push`, `speed`, and derived `len`, `ux`/`uy` (unit A to B,
  Q16), `travel` (mover crossing ticks). Draw a vent's lane from the mouth
  along (`ux`, `uy`) for `len` px, `size` px either side; a mover as a
  body of radius `size` at (`x`, `y`). The record layout is
  `track.hazard_record` (20 bytes, documented in track.zig and
  tools/build_tracks.py); the M7 packs reuse it.
- **Service bay**: the tile attribute `bay` (as M0); a car on it
  (`Car.on_bay`) gets 1 armor every 4 ticks. The generator can paint a
  whole segment or one lane of it (`bay:left`, `bay:right`).
- **Events** (`EventKind` gains `mark`, `collect`, `blast`,
  `hazard_hit`; `world.GcCause` sweep / tag / wreck): `mark` (newly marked
  car, the tagger or `no_car` for a sweep, cause), `collect` (car, final
  place, cause sweep or wreck; x, y the car: the claw comes down there),
  `blast` (hazard index, kind; a vent starts firing or the Sweeper starts
  crossing; x, y the mouth or the mover), `hazard_hit` (hazard index,
  car, damage; x, y the car).
- **Track table** for the menus: `track.tracks` in rotation order (name,
  `league.name`, `laps`), `track.leagues` in CIRCUIT order.

### Track A: content and mode simulation (Opus agent, worktree /home/exedev/snouty-badge-gc, branch gc/spec; runs while M2 Track B finishes)

Owns what M2 Track A owned (`world.zig`, `sim.zig`, `weapons.zig`,
`pickups.zig`, `ai.zig`, `tuning.zig`, `racers.zig` gameplay, `track.zig`
data accessors, the tests, `tools/build_tracks.py`, `tools/leagues.py`,
`cart/src/tracks/*.track`, the generated track and league `.bin`s), plus
new `hazards.zig`, `gc_mode.zig` and their tests. It must not edit the
presentation files (see M2 Track B). `render.zig` reads the league slices
already. If the Runoff league needs a renderer change, write it down for
Track B.

1. **M3.0 interface first** (own commit, documented under "M3.0
   Interface"): `Setup.mode` (race, gc) and the World fields for GC state:
   the marked car, sweep count, collected flags, survivor, events `mark`
   and `collect`. Also the hazard state in the World (`hazards: [N]Hazard`
   with kind, phase timer, mover position) and the hazard kinds of SPEC
   19.4 (timed blast, crossing mover, turret reserved for the Perimeter,
   breakable crust reserved for M7), with their track-data layout. The
   service bay is a tile attribute. Events: `blast` (hazard fires) and
   `hazard_hit`.
2. **Hazards** (generic, parameterised by the track file): the Dumps
   **Sweeper** (a crossing mover: path, speed, size, 60 damage and a
   shove), the Runoff **exhaust vent** (a timed blast: position,
   direction, width, period 240, 30 ticks on, 20 damage and a push), and
   the **service bay** (repairs 1 armor per 4 ticks). AIs avoid an active
   blast or mover where they can.
3. **The Runoff league** in `tools/leagues.py`: a 128-tile set (cracked
   salt pan, teal coolant puddles, pipe-tunnel walls, outflow mouths,
   salt-crust edges), the two-layer horizon (cooling towers over a
   cracked horizon), palette, fog. Read SPEC 3.2. The look must read
   clearly at speed: a calm background texture and a clear track edge.
   (M0's Dumps sand shimmered. Calm the Dumps background a little too,
   if it is cheap.)
4. **Five new tracks** (SPEC 3.2 names): Dumps: **Monitor Dunes** (hills,
   a Sweeper lane), **Cathode Flats** (fast, wide, pits); Runoff: **Salt
   Pan Sprint** (fast oval-ish with vents), **Outflow Canyon** (tight,
   walls, a pipe tunnel, vents), **Coolant Basin** (coolant slicks, a
   ramp over the basin). Each has crate rows, at least one hazard, a
   service bay on most, and its own character. Add a Sweeper to Landfill
   Loop if it fits. Every track passes the completable test (combat off)
   and the combat soak.
5. **GARBAGE COLLECTION mode** (SPEC 8.2, mark and sweep): a sweep point
   at the sector 2 line and the start line. The last car is MARKED, and
   any weapon hit by the marked car on another car passes the mark on.
   At the next sweep point the marked car is COLLECTED (`active = false`,
   a `collect` event) and the new last car is marked. A wreck while
   marked is an immediate collection. The last car running wins. A soak:
   20 seeded GC races each end with exactly one car.
6. **Track rotation data** for the menus: a table of the six tracks with
   name, league and lap count.
7. Tests, gate green, World under the cap (raise it with a reason if
   needed), bench worst under 8 ms on the busiest new track (record a
   race script there), PLAN "M3 status" Track A paragraph and deferred
   questions, commits with the `Co-Authored-By: Claude Opus 5.5
   <noreply@anthropic.com>` line, push gc/spec. No tag, no merge.

### Track B: flow and mode presentation (Opus agent, worktree /home/exedev/snouty-badge-gc-present, branch gc/present)

M2 is tagged and on main (`snouty-gc/m2`, main 20e2172a). `gc/present`
has the M3.0 interface (999ee5fc). Track A is still building the tracks,
hazards and GC rules on `gc/spec`: merge `origin/gc/spec` in as it pushes.
Track B owns the M2 Track B files plus `tools/draw_art.py`, `tools/art/`,
`assets/gen/art/` and `ASSETS.md` (new art sheets: hazards), and never
edits Track A's files.

1. **Menu** after the title (SPEC 8.1): QUICK RACE | GARBAGE COLLECTION |
   LINK (greyed, `NO LINK YET` until M4) | SOUND. Then racer select, then
   the track row over the six tracks from Track A's rotation table (name
   and league; a track not yet built is skipped), then the countdown.
   Pause keeps Resume, Restart, Quit, Sound. The HUD's `LAP n/N` reads
   `World.laps`, and GC shows `SWEEP n` instead of laps.
2. **GC visuals**: the MARKED car gets a red outline and a `MARKED` tag
   over the sprite (blinking on the minimap); a `mark` event passing the
   mark flashes `TAGGED!`; a `collect` event lowers the claw (`claw.png`)
   from the top of the screen over that car, closes it and lifts the car
   out, with `GC: freed KIDDIE` in the feed. A collected human watches the
   race from the leader's camera with `COLLECTED` on screen. The survivor
   screen shows the winner's full portrait and taunt and `LAST PROCESS
   RUNNING`. Results for GC rank by collection order.
3. **Hazards drawn** from `World.hazards` and `track.hazard_specs`: the
   Sweeper (a new code-drawn sprite sheet in `draw_art.py`: a huge
   maintenance crawler with brushes and a warning light, a few frames,
   seen from behind and the side), its warning (light flashing during
   `warn`), the exhaust vent (the lane telegraphed during `warn`, a heat
   blast of flame or steam along it during `active`), sparks on
   `hazard_hit`. Read Track A's notes in PLAN "M3 status" when it lands.
   If the Runoff horizon or palette needs anything from the renderer,
   do it.
4. **Title screen**: SNOUTY GC / GARBAGE COLLECTION over the Dumps
   horizon with the six portraits along the bottom, then `PRESS START`.
   It goes to attract after 10 s idle.
5. **Attract**: an AI-only race with `.mode = .attract` (the sim scripts
   the lap 2 KERNEL PANIC on the leader), the camera cutting between
   cars every few seconds, `PRESS START` blinking, any button back to the
   title. Rotate the track each time.
6. Previews (`docs/preview_m3.gif`: the menu, a GC race with a mark, a
   tag and a claw, the survivor screen, a vent and a Sweeper, the attract
   blue screen), bench (add a GC race script, plain and `--lcd`, under 8
   ms worst), gate green, PLAN "M3 status" Track B paragraph and deferred
   questions, commits with the `Co-Authored-By: Claude Opus 5.5
   <noreply@anthropic.com>` line, push `gc/present`. No tag, no merge.

### M3 gate

Gate green; all six tracks completable; the GC soak ends with one car;
bench under 8 ms; `docs/preview_m3.gif`; tag `snouty-gc/m3`; merged to
main.

### M3 status

- 2026-10-05: **Track A (content and mode simulation) DONE** on
  `gc/spec`: the M3.0 interface (999ee5fc, above), the content and modes
  (e8710a72), the RAM fit (323e4d38) and the attract and packet fixes
  (ee1d5c38). New `hazards.zig` (the generic hazards and the service
  bays), `gc_mode.zig` (mark and sweep, attract's script),
  `content_test.zig`; the Runoff league in `tools/leagues.py`; five new
  `.track` files; hooks in `sim.zig` (hazards after the contacts, the GC
  rules after the ranks, `damage` tags only on weapon hits, `wreck`
  collects a marked car, no lap limit in GC), `ai.zig` (`dodge_hazards`),
  `pickups.zig` (ZERO-DAY tags; the packet fix), `track.zig` (track
  table, hazard specs, the league art slot). Every number is in
  `tuning.zig` ("Track hazards, service bays, modes") or, for each
  hazard, in its track's data.
- **Tracks** (lap px from the generator; the SNOUTY autopilot's 3 laps
  with combat off, ticks, and its best lap):

  | # | Track | League | Lap | 3 laps (best lap) | Crates | Hazards | Bay |
  |---|---|---|---|---|---|---|---|
  | 0 | LANDFILL LOOP | Dumps | 3,666 | 5,121 (1,624 = 27 s) | 10 | Sweeper past the ramp landing | west, right lane |
  | 1 | MONITOR DUNES | Dumps | 3,646 | 5,484 (1,800) | 12 | Sweeper on the bottom straight | west, left lane |
  | 2 | CATHODE FLATS | Dumps | 3,644 | 5,207 (1,681) | 12 | Sweeper on the east side | west, right lane |
  | 3 | SALT PAN SPRINT | Runoff | 3,622 | 5,039 (1,641) | 12 | 3 vents (phases 0, 120, 60) | west, right lane |
  | 4 | OUTFLOW CANYON | Runoff | 3,630 | 5,671 (1,854 = 31 s) | 6 | 2 vents in the narrows | west, right lane |
  | 5 | COOLANT BASIN | Runoff | 3,613 | 5,005 (1,615) | 7 | vent on the top straight | west, left lane |

  Characters: Monitor Dunes two dune runs (hills) and flowing bends;
  Cathode Flats wide (half 60 to 70) with open pit edges on the start
  straight (both sides), the east side and the M's notch, a ramp over a
  pit; Salt Pan Sprint a fast C with a long tongue; Outflow Canyon narrow
  (half 44) with a ribbed pipe tunnel and two vents where there is no
  room to go round; Coolant Basin round two brine-pit basins (open on the
  basin side, `pit_band 11`), a causeway with a ramp over a channel,
  three coolant bands. Map previews `docs/<track>_preview.png` (vent
  lanes orange from the mouth, Sweeper paths yellow with their parking
  circles, crates white), in-cart views `docs/m3_tracks_race.png` (the
  six tracks at four moments of an autopilot race, rendered with
  gc/present's M2 presentation merged in a scratch worktree; hazards are
  not drawn yet), `docs/runoff_tiles.png`, `docs/runoff_horizon.png`.
- **The Runoff**: a pale polygon-cracked salt pan with brine pools,
  stains and drain grates (calm on purpose), a dark graded-mud road with
  tyre seams, rust-orange outflow pipes as walls (a pipe painter for
  `paint_track_pieces`), salt-crust lips over teal-black brine pits,
  ribbed pipe floor for tunnels; horizon of hyperboloid cooling towers
  with steam plumes and blinking red rim LEDs (front entry 15) over a
  flat salt horizon, the far datacenter halls in a hazy sky. The Dumps
  sand is calmer (2x2 grains, lower contrast, fewer glints). Open edges
  now drop into a drawn pit band in both leagues.
- **Hazards** (SPEC 3.3, 19.4; generic, numbers in the `feat` records):
  vents fire for 30 of 240 ticks after 40 of warning: 20 damage once a
  firing and a 1.75 px/tick shove along the lane; the Sweeper (radius 18,
  1.25 px/tick, period 600) waits, warns 60, crosses in about 160 ticks:
  60 damage once a crossing, a 2 px/tick shove plus its own velocity, and
  it pushes cars out of its body. Airborne cars pass over both. Service
  bays repair 1 armor every 4 ticks. The AI reads the cycles: it slows to
  reach a vent as the firing ends and passes behind the Sweeper (or
  slows); KIDDIE ignores both (`heed_hazards`).
- **GARBAGE COLLECTION** as specified (M3.0 above): the GC soak (20
  seeded 6-AI races, every track) **ends with exactly one car every
  time**, 5 collections each, in 4,811 to 6,488 ticks (mean 5,508, about
  92 s), 0 to 6 tags a race, no car stuck over 600 ticks, pools within
  caps. A GC race with the autopilot as the human ends only on one car.
- **Attract**: `.mode = .attract` launches a KERNEL PANIC packet at the
  leader in lap 2 (12 samples behind it, "fired" by the best-placed car
  behind it: a `use` event); the leader is frozen in 6 of 6 seeded runs,
  55 to 295 ticks later.
- **Tests** (`zig build test-gc`): **97 pass** (77 before). New: hazard
  cycles (blast and mover phases, the record decode), every track well
  formed with hazards, crates and a bay, a vent hitting a parked car once
  a firing with its shove and events (and not beside the lane, airborne),
  the Sweeper hitting a stalled car once a crossing and pushing it out,
  the bay repair rate, the AI waiting for a vent from 8 to 12 samples
  out (KIDDIE hit every time), a combat soak on **every** track (4 seeded
  races each: all finish, longest no-progress run 260 ticks, pools within
  caps), the GC rules (first sweep marks the last car, the next collects
  it, the grace, tags by weapon hit not by ram, a wreck while marked, the
  survivor and the places 1 to 6), the GC soak, GC with a human,
  attract, the packet over half a lap, determinism (a GC race twice, two
  GC worlds interleaved with two humans on random inputs), the human
  autopilot finishing a full combat race on every track (3 seeds each:
  2.7 to 5.3 armor wrecks a race, as M2's 4 to 5).
- **`@sizeOf(World)` = 2,508 B** (cap 2,560 kept).
- **RAM**: gc/spec alone `.text` 141,780 + `.data` 7,356 + `.bss` 44,436
  (+ 808 exidx/extab) = 194,380 B, 78 KB free. **Merged with gc/present
  (4c7e2458, M2 presentation) in a scratch worktree: `.text` 202,920 +
  `.data` 7,440 + `.bss` 51,332 + 948 = 262,640 B, only 11.3 KB free**
  under the 274,176 B window less the 32 KB stack. The first merge
  overflowed by about 1.4 KB, hence 323e4d38: the league tiles and
  horizons are stored packed and unpacked into one RAM slot when the
  league changes (SPEC 19.2's pack slot pulled forward; the renderer reads
  the same slices), the backgrounds repeat a 32-tile wallpaper (packed
  maps 3.4 to 4.3 KB, were 5.2 to 6.0), centerline samples take 6 bytes.
  All league and track data is 30.7 KB packed. M4 (net) and M5 (garage,
  career) need room: see deferred question 56.
- **Bench**: gc/spec gate (`m0_race.json` re-recorded, 600 frames): mean
  3.21 ms, worst 3.78 ms (frame 20, the race start), `--lcd` identical.
  The busiest new track, integrated build: `tools/scripts/m3_outflow_race.json`
  (1,500 frames: Start, Start, Down, Right x4, A at frame 26 on the
  merged select's track row, then the autopilot's recorded drive round
  Outflow Canyon's pipe tunnel and vents): **mean 3.14 ms, worst 5.26 ms**
  (frame 26, the race start: the Runoff art and the map unpacked, ~36 K
  byte copies), p95 3.95, `--lcd` identical. The script replays only on
  the merged flow.
- Gate: `tools/check.sh` green on `gc/spec` (build, test via test-gc,
  check-float, tracks: 26 generated files byte-identical, preview, bench).
- **For Track B** (presentation; nothing in main.zig is needed from me):
  - **Data moved**: the league and track `.bin`s are in
    `cart/src/gen/tracks/`, embedded by `track.zig`. Please drop the six
    `dumps_*` / `landfill_loop_*` entries from `build.zig`'s `data_files`
    and `git rm` those `assets/gen/` copies (stale, unreferenced).
  - **League art slot**: `League.tiles`/`.horizon` are a RAM slot filled
    by `track.select(t)` (or `track.load_art(league)`); call one before
    `render.set_track(t)` on any screen that draws a floor or horizon
    (the title over the Dumps: `track.select(&track.landfill_loop)`, as
    `start()` already does).
  - Draw the **Sweeper** at `World.hazards[k]` (`kind == .mover`; `x`,
    `y`; body radius `track.hazard_specs[k].size` = 18 world px, so about
    a 40 px sprite at the car's scale; `state` `warn` = beacons flashing
    at its parking spot, `active` = crawling along `leg` 0 (A to B) or 1;
    `blast` event when it starts). Its gates in the walls and the striped
    crossing are floor tiles already.
  - Draw the **vents**: mouth at `x0, y0` (a grille tile in the wall
    already), lane along (`ux`, `uy`) for `len` px, `size` px either side
    (a scorched grate band is painted); `warn` = glow or smoke at the
    mouth, `active` = flame or steam along the lane; `blast` event when it
    fires, `hazard_hit` (hazard, car, damage) for sparks and a hit note.
  - **GC**: `World.gc` and the `mark` / `collect` events (M3.0 above);
    a collected car is `!active` (hide it after the claw), its `rank` is
    its place; the survivor `finished` with rank 1 and the phase
    `finished`. `GC: freed X` on `collect`, `TAGGED!` on a `mark` with
    cause `tag`.
  - **Runoff**: no renderer change needed (the horizon's front entry 15
    is the towers' red LEDs, blinking with Zero's swap; pale fog).
  - HUD `LAP n/N` from `World.laps`; attract passes `.mode = .attract`;
    GC `.mode = .gc`. `m0_race.json` was re-recorded on gc/spec's M0 menu
    flow (Start, Start, A): re-record after the M3 menu lands.

- 2026-10-05: **Track B (flow and mode presentation) DONE** on
  `gc/present` (gc/spec merged in up to ea6a03f7; not merged back, not
  tagged). **Flow**: splash, the title (SNOUTY GC at 2x with a coral drop
  over Landfill Loop's floor and the Dumps horizon, GARBAGE COLLECTION,
  PRESS START, the six half-scale portraits along the bottom, one stepping
  up at a time; 10 s idle starts attract), the **main menu** over the same
  backdrop (QUICK RACE, GARBAGE COLLECTION, LINK greyed with `NO LINK YET`
  flashing on A, SOUND; a highlight bar, a line about the row; B back to
  the title), the racer select (B back to the menu; the track row cycles
  `track.tracks` and its panel shows name, league, `3 LAPS` or `MARK AND
  SWEEP`, the hazards and the track's outline), countdown, race, pause
  (Resume, Restart, Quit, Sound), results, the select again. The HUD's
  `LAP n/N` reads `World.laps`. **GARBAGE COLLECTION**: `SWEEP n` (the
  next sweep) with a 40 px bar filling as the leader nears it
  (`gc_mode.sweep_at`); the MARKED car in a blinking red outline with
  `MARKED` over it, blinking red on the minimap; feed lines `KIDDIE
  MARKED`, `LEGACY TAGGED KIDDIE`, `GC: freed KIDDIE`; `TAGGED!` rising
  over the newly tagged car; bar notes on the badge concerned (`MARKED!
  TAG SOMEONE`, `TAGGED! PASS IT ON`, `MARK PASSED`); on `collect` the
  claw (`claw.png`) comes down from the top edge on its cable over the
  car (24 ticks), closes (10), and lifts it out of the frame (56), drawn
  from a render-side copy because the World has taken the car out; a
  collected player's camera stays on the claw, then rides with the
  leader (changing car at most every 2 s) with `COLLECTED` bottom left and
  the watched racer's name under the top row. The survivor card reads
  `LAST PROCESS / RUNNING` over the winner's portrait, car, sweeps, kills
  and taunt; the table ranks by place with `SURVIVOR`, `SWEEP n` or
  `WRECKED`. **Hazards**: new `hazards.png` (tools/art/hazards.py, 4 cells
  of 48x32, 13 colours): the Sweeper's end and side views with treads and
  brushes turning, its roof beacon lit in code (flashing during `warn`,
  steady while crossing), drawn 2 x size + 8 world px wide at
  `World.hazards[k]`, an orange dot on the minimap; a vent's `warn`
  blinks dashed lane edges and puffs steam at the mouth, `active` throws
  flame (the first 40% of the lane) and steam puffs every 12 px reaching
  the far end in 6 ticks and thinning in the last 6; `blast` bursts at the
  mouth, `hazard_hit` sparks, flashes the armor bar and shakes the victim's
  badge, and adds a `VENT > X` / `SWEEPER > X` feed line. The Runoff
  needed nothing from the renderer. **Attract**: `.mode = .attract` on the
  next track each time (from Landfill Loop), the camera cutting to the
  next running car every 5 s and to any car a KERNEL PANIC freezes (held
  2.5 s, so the blue screen shows: in the gate's boot run the scripted
  panic blue-screens the leader at frame 3,470), the spectator HUD,
  `PRESS START` blinking on the bar row, any button back to the title.
  **Stress scene**: now in GC mode with a MARKED car, a tag and a claw
  every 90 frames, a Sweeper crossing and two vents firing 30 of every 40
  frames (its own hazard specs: a debug write of the track's cache, like
  its crates); 159 objects gathered, 64 drawn.
- **RAM, and the build mode.** Merged, the RAM cart no longer fit
  ReleaseFast: Track A's merge measured 262,640 B (11.3 KB free); this
  track's code and the Sweeper sheet take it to about 283,800 B, 9.6 KB
  over the 274,176 B window (measured through the XIP build's sizes).
  The cart now builds **ReleaseSmall** (`build.zig`): `size -A` **.text
  137,116 + .data 7,480 + .bss 51,372** (+ 1,164 exidx/extab +
  descriptor) = 197,152 B, **77,024 B (75 KB) free**. Gameplay is
  untouched. ReleaseSmall alone made the stress worst 7.75 ms (8.97 with
  M3's hazards); the hot paths were rewritten so it does not need the
  optimizer's unrolling: `sprites.blit_rect`'s inner loop specialised per
  case (plain, flat, odd-pixel skip), the 8x8 glyph unrolled with `inline
  for`, `hud.fill_rect` writing columns directly for every filled HUD
  rectangle (the API's `rect` was 9% of a frame), the camera and
  depth-list helpers `inline`, a 32-bit divide in `hills.height_ahead`,
  nothing drawn under this badge's CAPTCHA card, and the select drawn
  once more on the frame a pick unpacks the track's art and map.
- **Bench** (calibrated, every run `--lcd` identical): stress mean 5.12,
  **worst 6.15 ms** (M2 ReleaseFast 6.34); `m0_race.json` mean 3.63, worst
  5.20; `m2_race.json` mean 3.58, worst 5.20; `m3_outflow_race.json`
  (Outflow Canyon, re-recorded on the M3 menus) mean 3.62, worst 5.66
  (frame 28, the art unpack; was 7.49 before the select redraw); new
  `m3_gc_race.json` (a GARBAGE COLLECTION race on Monitor Dunes: marks,
  two collections, the player collected and watching, the Sweeper) mean
  3.47, **worst 5.64 ms**. `tools/check.sh` green (build, test via test-gc:
  97 pass, check-float, tracks, preview, bench); it adds the main menu
  run (LINK stays, GC races), a GC race to its survivor, the CAPTCHA
  presses re-derived for the merged sim, the stress check at frame 200
  (the CAPTCHA card covers the list before it), and the two M3 benches.
  `tools/record_script.py` takes `--track` and `--gc` and walks the M3
  menus (Start 2, Start 10, Down 12 for GC, A 14, Down 16, Right every
  2, A); `m0_race.json`, `m2_race.json` and `m3_outflow_race.json` are
  re-recorded on it. `build.zig` dropped the stale Dumps and Landfill
  Loop entries from `data_files` (the copies are removed).
- `docs/preview_m3.gif` (310 frames, 50 ms): the title, the menu, GC's
  select and track row, the Sweeper crossing, LEGACY marked, SNOUTY
  marked and tagging ROOTKIT (`MARK PASSED`), the claw lifting SNOUTY out
  and the leader's camera, the last `GC: freed`, the survivor card and the
  table, a vent firing on Salt Pan Sprint, the attract demo's blue screen.
  Deferred questions 70 to 86.

## M4 Link

Goal: two badges joined by the link cable race in one field (SPEC 7),
deterministic lockstep over `lib/link.zig` (docs/LINK.md), LINK RACE and
LINK GC, waiting, peer-left, and the desync check.

### Track A: lockstep core (Opus agent, worktree /home/exedev/snouty-badge-gc-net, branch gc/net off main 20e2172a)

Built and host-tested off main (which has `lib/link.zig` and the M2 sim)
while M3 finishes on `gc/spec` and `gc/present`. It touches only new files
plus the smallest wiring, so the lead's integration merge stays easy.
Owns new `cart/src/net.zig`, new `cart/src/net_test.zig`, the
`host_tests.zig` import line, the `link` import in `build.zig` (one
line for the cart module and its test module), and new `docs/NET.md`.
No `main.zig`, no menus, no rendering: that is Track B after M3 lands.

1. **`net.zig`, generic over the link type** (`Net(comptime L: type)`,
   with `L` = `link.Badge` on the badge, a `link.Link(link_virtual...)` in
   tests, and a null link in wasm), so the same code runs in the cart and
   in host tests. Entry points for main.zig: `init`, `pump(now)` (polls
   the link; call it often), a setup state machine (`host` = the higher
   HELLO nonce, `SETUP`, `PICK`, `GO` messages with a kind byte, SPEC 7.3),
   `ready_for(tick)` / `inputs_for(tick) ?[2]u8`, `submit_local(tick,
   byte)`, `state()` (searching, connected, setup, racing, waiting,
   peer_left, desync), and the slot this badge drives.
2. **Lockstep** (SPEC 7.2): input delay 2 ticks; each input packet is 5
   payload bytes (tick low byte, inputs for t, t-1, t-2, one check byte),
   so a whole packet fits the 8-entry RX FIFO. Lost packets are covered
   by the repeats, with no retransmit protocol. The badge advances tick t
   only with both inputs for t. WAITING shows after 30 frames without
   them. When the link reports the peer gone (state not `.connected`, or
   the `session` changed), `peer_left` hands the peer's car to the AI
   (a `Car.human = no_human` change made through a function the sim
   exposes or a documented field write before the next `simulate`;
   coordinate by writing it down in PLAN).
3. **Desync check**: a CRC8 over the `World` bytes every 32 ticks, sent a
   byte at a time in the check byte. A mismatch is `desync`.
4. **Pause and quit** travel in the input byte (Start), so they are part
   of the lockstep. Quit is a setup message.
5. **Host tests** (`net_test.zig`): two `Net` + two Worlds on a
   `link_virtual` cable; 10 seeded link races with scripted inputs on
   both ends, World bytes equal on both every tick; the same with 1%
   injected byte loss (still in sync, finishes); unplugging mid-race
   gives `peer_left` and the race finishes with the AI driving; a forced
   World mutation on one side gives `desync` within 64 ticks; a GC-mode
   link race to one survivor. Read `lib/link_virtual.zig` and
   `lib/tests/link_unit.zig` for how the virtual cable runs.
6. **Bench note**: measure the cost of `pump` with an idle and a busy link
   in the host (cycles are not available; report the operation counts).
   The real poll-gap measurement is Track B's, on the badge-bench.
7. `docs/NET.md`: the protocol (message kinds, byte layouts, timing), how
   main.zig drives it frame by frame (pump points: top of update, between
   floor bands, in the waiting loop), and what Track B must build.
8. Gate: `zig build test-gc` passes including the net tests, `zig build
   -Dcart=snouty-gc` builds, check-float passes. PLAN "M4 status" Track
   A paragraph and deferred questions; commits with the `Co-Authored-By:
   Claude Opus 5.5 <noreply@anthropic.com>` line; push `gc/net`. No tag,
   no merge.

### Track B: link integration (Opus agent, worktree /home/exedev/snouty-badge-gc-present, branch gc/present)

M3 is on main (tag `snouty-gc/m3`, main ed6e920d). The cart builds
ReleaseSmall (75 KB of RAM free, deferred question 71), which serves as
the RAM diet. `gc/present` merged `gc/net` (Track A, 5343564a) and is now
the one integration branch: `gc/spec` and `gc/net` are retired. Track B
owns every file in the cart.

1. **Fix first**: `net_test` "GC mode link race in sync to its end"
   fails after the merge (L4: written before M3's GC rules). Make it end
   on the GC survivor.
2. **Crews** (L3): add `Setup.crews` (4, 2 or 0 AI racers; the unused
   racer cars are left off the grid, `active = false` from the reset, on
   both badges) and carry it through `net.world_setup()`.
3. **The LINK menu** (SPEC 7.3): cable state while searching (`PLUG IN
   THE CABLE`, `SEARCHING...`, `WRONG CART` for another cart's link), host
   or guest. The host picks mode (LINK RACE | LINK GC), track and crews,
   and the guest sees them read-only. Then the shared racer select, with
   the peer's racer greyed and a ready mark for each side. The host's A
   starts both. In the simulator, LINK stays greyed with `NO LINK IN
   SIMULATOR` (state offline).
4. **The race loop over `net`** as docs/NET.md section 3 says: `submit`,
   `step` (one tick per frame), pump points at the top of update, between
   floor bands in `render.zig` (every 16 rows) and between the sprite and
   HUD passes, the waiting loop with `WAITING FOR PEER` after 30 frames,
   `PEER LEFT, AI DRIVING`, `DESYNC` ending the race to results, pause
   and quit from either badge, and each badge following its own car with
   its own gags. Results return both badges to the lobby, with a rematch
   from there.
5. **Bench the poll gap**: add an instrumentation export (worst
   microseconds between two `pump` calls in a race frame) and a link-race
   bench script with a fake connected peer if badge-bench allows (see
   `badge-bench` docs and the snouty-link cart's bench toml for the
   no-cable fake). Otherwise bench a single-player race with the pump
   points in place and report the worst gap from the frame structure. The
   goal is a gap shorter than one packet's wire time (about 80 us) at
   the floor-band level. If that is not reachable, say what is.
6. **Hand-off docs**: `docs/LINK_PLAY.md`, which says how to cable two
   badges (JST-SH 3-pin to 3-pin on the UART headers, either
   orientation; docs/LINK.md), flash both, and start a LINK RACE. Also
   the cart CLAUDE.md module list (net.zig).
7. Gate green (check.sh including the net tests), bench under 8 ms worst
   with the pump points in, RAM recorded, `docs/preview_m4.gif` (the
   LINK menu in the simulator, which is offline, plus a host-test-driven
   or debug-forced view of the lobby and of WAITING / PEER LEFT if
   practical), PLAN "M4 status" Track B paragraph, deferred questions
   numbered `L15` on, commits with the `Co-Authored-By: Claude Opus 5.5
   <noreply@anthropic.com>` line, push `gc/present`. No tag, no merge.

### M4 status

**Track A (lockstep core), 2026-10-05, branch `gc/net`.** `cart/src/net.zig`
(`Net(L)`, generic over the link), `cart/src/net_test.zig`, the `link`
import for the cart module and a `link_host` test module in `build.zig`
(L11), `docs/NET.md` (protocol, frame-by-frame driving, Track B's list).
`main.zig`, `sim.zig` and `world.zig` are untouched; nothing imports
`net.zig` in the cart yet, so the cart ELF is unchanged.

- **API for main.zig** (docs/NET.md section 3): `Net(link.Badge).init(
  link.Badge.init(.{}, net.app_id, cart.rand()))`; `pump(now)` often;
  `state()` = offline / searching / wrong_cart / lobby / racing / waiting /
  peer_left / desync; lobby: `role`, `set_rules` (host), `rules()`,
  `set_pick(racer, ready)`, `peer_racer()`, `can_go()`, `go(now)` (host);
  `take_started()` then `sim.reset(&w, world_setup())` and `follow =
  local_car()`; race: `submit(now, byte)` once a frame, `step(&w)` at most
  once a frame (retry in the waiting loop), `paused`, `left`,
  `handed_over`; `leave(now)` for QUIT, after the results, after
  peer_left or desync.
- **Protocol**: control messages SETUP / PICK / GO / QUIT / DESYNC (2 to 4
  bytes, kind byte first); the input packet is 5 bytes and always exactly
  8 on the wire (salted CRC, no SLIP escapes; L9); input delay 2; each tick
  in 3 consecutive packets; a stalled partner gets the window it lacks
  (its newest tick tells); World hash every 32 ticks, 7-bit pieces in the
  check byte; pause from Start edges in the agreed bytes.
- **Tests** (`zig build test-gc`: 93 pass, 14 of them net): packets always
  8 wire bytes (64 x 128 x 6 encodings); world_hash covers every field;
  lobby roles over 24 seeds and both cable kinds, another cart, rules
  reach the guest, racer clash blocks GO, GO through 5% byte loss; **10
  seeded link races** on a clean cable, World hash equal at every tick and
  final Worlds equal (75,698 ticks; 0.41% of packets lost to the FIFO
  model; 0.28% of frames without a tick, at most 2 in a row); **10 races
  with 1% byte loss** (8.75% of packets lost) in sync and finished (1.8%
  of frames without a tick, at most 8 in a row, pumping to 14 ms; 4.4% /
  13 without the pump loop); a LINK GC race in sync (L4); **unplug**
  mid-race: both `peer_left` 42 ms later, each finishes with the AI on the
  other car; **desync** found on both badges at most 32 ticks after one
  World is changed (contract: 64); pause and resume on the same tick on
  both; quit mid-race, then a rematch (race 2, new seed) in sync.
- **Sizes**: `@sizeOf(Net(link.Badge))` = 568 bytes, the link 344 of them
  (its 8-packet queue and 64-byte pending buffer); 16-byte local and
  remote rings, four 8-byte hash slots; no other buffers.
- **Cost** (operation counts; Track B benches the badge): an idle pump is
  one `link.poll` (one FIFO read, one pin read) and a few compares; a
  racing pump averages 1.99 FIFO reads; a packet in is 8 FIFO reads, a
  6-byte CRC and ~30 operations; a packet out up to 3 salt CRCs plus the
  link's CRC and 8 FIFO writes; `world_hash` is 1,356 field mixes every
  32 ticks (estimate ~90 us on the badge).
- `zig build -Dcart=snouty-gc` and `zig build check-float` pass;
  `zig fmt` clean.

**Track B (link integration), 2026-10-05, branch `gc/present`.** The LINK
menu, the shared racer select and the link race are in, over Track A's
`net.zig` as docs/NET.md section 3 says; `docs/NET.md` section 4 lists
what was built, `docs/LINK_PLAY.md` is the hand-off (cable, flashing,
playing, the two-badge check).

- **Item 1**: the LINK GC net test ends on the GC survivor (a collected
  human is out, the survivor finished: L4). **Item 2**: `world.Setup.crews`
  (default every AI car, so single player's grid is unchanged: a test
  compares the Worlds); `sim.reset` keeps the first `crews` AI cars of the
  seed's grid shuffle and leaves the rest off the grid (`active = false`,
  rank 0, never drawn); `net.world_setup()` carries the host's CREWS (L3).
- **Item 3, the LINK menu** (`main.lobby_frame`, `link_ui.zig`):
  `PLUG IN THE CABLE` / `SEARCHING...`, `WRONG CART`, then HOST or GUEST
  and the cable kind, the host's MODE (LINK RACE / LINK GC), TRACK (six)
  and CREWS (4 / 2 / 0) rows with Left/Right, the guest's greyed copy
  (`WAITING FOR HOST` before the first SETUP), the partner's pick. A goes
  to the shared racer select (`select.link`): the partner's ready racer
  greyed `TAKEN`, a panel with the rules, `PEER` and `YOU` with their
  `READY` marks, the bottom row `A READY` / `TAKEN` / `A START` (host,
  both ready) / `HOST STARTS`; B takes the mark back, then back to the
  lobby. In the simulator LINK is greyed and A flashes `NO LINK IN /
  SIMULATOR`.
- **Item 4, the race** (`main.link_race_frame`): pump at the top, submit
  the race byte, one `step` (the tick's effects, GC camera and sound
  after it), draw with the pump points, `WAITING FOR PEER` / `PEER LEFT,
  AI DRIVING` (3 s, with `CABLE OUT` / `PEER RESTARTED` / `PEER QUIT`),
  then pump and retry the step until 14 ms into the frame
  (`tuning.link_pump_until_us`). Each badge follows its own car
  (`local_car`) with its own gags; LINK GC's collected player watches the
  leader as in single player. Pause from either badge's Start (RESUME,
  QUIT, SOUND; only Start reaches the race, RESUME and B send a Start
  edge); QUIT leaves, the partner's AI takes the car. `DESYNC` goes to
  the results with a `DESYNC: RACE ENDED` band. After the finish the
  World runs on locally (L16); the results' last A leaves, both badges
  are back in the lobby for a rematch (new seed).
- **Tests** (`zig build test-gc`: **116 pass**, 16 of them net): new
  `CREWS 2 and 0` (three link races in sync to the end: LINK RACE CREWS 2,
  CREWS 0 on a straight cable, LINK GC CREWS 2; 2 + crews cars on the
  grid), `main's pause` (menu presses masked to the Start bit, RESUME's
  injected edge while Start may still be held, the other badge's pause
  and resume, in sync to the finish with 0.2% byte loss), sim tests
  `CREWS` (grid, ranks, a race to the finish with the cars still off)
  and `after the finish no input reaches the World` (race and GC, 900
  ticks of random bytes against zeros). The headless preview gains a
  LINK run (offline in the simulator, the made-up lobby and select, a
  Quick Race after them is not linked). Single player is unchanged: the
  M0-M3 input scripts replay to the same World checksums as before this
  track (`m0_race` 1,125,151,687 at update 2,999, `m2_race` 1,116,132,432,
  `m3_gc_race` -1,540,294,026, `m3_outflow_race` 69,064,753).
- **Item 5, the poll gap.** badge-bench has no connected-peer fake (and
  is not this cart's tool), so `--poke gc_pump_probe=1` runs every pump
  point in a single-player race with the link searching, plus the
  per-tick work that needs no partner (`encode_input` each frame,
  `world_hash` every 32 ticks), and traces the worst gap ending at each
  kind of pump point every 120 frames (`check.sh` prints them). Worst
  over the stress scene, `m2_race`, `m3_outflow_race` and `m3_gc_race`
  (us): **floor 59** (every 3 rows: under one packet's 80 us wire time),
  horizon 89 (every 16 columns; 279 for the first, after the hills' row
  tables), floor lines 218, HUD passes 543 (the ZERO-DAY flash's half
  screen, the CAPTCHA card's halves), the tick 513 (`simulate` and the
  effects: one stretch, `simulate` stays pure), **one sprite 774** (the
  Sweeper or a claw close up: a blit is not split). The frame boundary
  (14 ms to the next frame's top: ~2.7 ms plus `present`) is the longest
  stretch. None of these loses a packet: in a race the link sends no
  keepalives (traffic flows) and input packets are at least 12 ms apart,
  so the FIFO holds every packet whole while the gap stays under 12 ms;
  the floor-band target (80 us) is met on the floor and the horizon.
- **Bench** (calibrated; `--lcd` identical): `m0_race` mean 3.65, worst
  5.22 ms; stress 5.02 / **6.17** (M3 5.12 / 6.15: the CAPTCHA card is
  now an outline and two halves instead of a full fill under the face,
  same pixels); `m2_race` 3.58 / 5.22; `m3_outflow_race` 3.64 / 5.66;
  `m3_gc_race` 3.49 / 5.67. With the probe (every pump point on): stress
  5.16 / **6.34**, `m3_gc_race` 3.59 / 5.80, `m2_race` 3.69 / 5.38,
  outflow 3.76 / 5.66: the pump points cost ~0.1-0.15 ms a frame with an
  idle link. `tools/check.sh` green (build, test via test-gc, float,
  tracks, preview, bench with the two probe runs).
- **RAM**: `size -A` **.text 150,312 + .data 7,480 + .bss 52,032** (+
  1,580 exidx/extab + descriptor) = 211,424 B, **62,752 B (61 KB) free**
  (M3: 77,024). `Net(link.Badge)` 568 B of the .bss; `world_hash` 1.9 KB
  and `Net.pump` 1.8 KB of the .text.
- `docs/preview_m4.gif` (389 frames, 50 ms): the menu (LINK greyed, `NO
  LINK IN SIMULATOR`), the made-up LINK screens (searching, the host's
  lobby changing MODE / TRACK / CREWS, the guest's, another cart), the
  host's select readying LEGACY with KIDDIE ready (`A START`), the
  guest's on a `TAKEN` racer, then a Quick Race with `WAITING FOR PEER`
  and `PEER LEFT, AI DRIVING` forced over it. Deferred questions L15 to
  L27.
- **Never run on two badges.** `docs/LINK_PLAY.md` section 4 is the
  hardware check for the show.

## M5 Circuit and polish

Goal: a full two-league CIRCUIT is playable start to finish (SPEC 8.2,
9, 16): menu, CIRCUIT, racer select, garage, race, results, standings
with CYCLES, garage again, three tracks of the Dumps, the league card,
the Runoff unlocked, three tracks of the Runoff, the circuit end card.
Plus the polish list: `TAGGED!` clipped at the screen edge, Quick Race in
two presses, a balance pass that errs dangerous, the bench profile and
fast paths. One agent (Opus), worktree
/home/exedev/snouty-badge-gc-present, branch `gc/present` off origin/main
90683be4 (M0-M4 merged, tag `snouty-gc/m4`). It owns every file of the
cart except `cart/src/net.zig`, `net_test.zig` and `link_ui.zig` (another
session is moving `net.zig` into a shared `lib/lockstep.zig`); LINK races
keep the L0 upgrades through the `Setup` defaults.

### M5.0 Interface (committed before the career code)

Same contract as M1.0 to M4: only `sim.simulate` writes the World,
rendering and the career read it. The World stays pointer-free and under
its 2,560 B cap (raised only with a comment if it must be).

- **`world.Loadout`** (one per car): `front: ?Front` and `rear: ?Rear`
  (null = the racer's own, SPEC 4.1), `front_level` and `rear_level` 1..3,
  `plating`, `clock`, `traction`, `burst` (BURST BUFFER) and `watchdog`
  0..3. **`Setup.loadouts: [car_count]Loadout`**, indexed by car (= racer),
  default all `.{}`: L0 and the stock weapons, which is today's car
  exactly. `sim.reset` applies it (SPEC 9.2): armor `+30` a PLATING level
  (`Car.ecc` at L3: a hit of 4 or less is ignored, PING cannot chip you),
  top speed `+4%` a CLOCK level (`top_q8`), grip `+0.03` a TRACTION level
  (`grip_q8 + 8`), `Car.burst_max` 1 + BURST BUFFER charges a lap,
  `Car.watchdog` 120 / 90 / 60 / 40 ticks of WATCHDOG delay (the hulk
  burns for the first 90 of them, or all of a shorter delay), the weapons
  and their levels (front L2 `+25%` ammo, L3 also `+25%` damage; rear L2
  `+1` ammo, L3 also `+25%` effect: bomb and caltrop damage, the caltrop
  slow, the leak's grown size, the firewall's width).
- **Cycle chips** (SPEC 9.1): **`Setup.chips`** (false by default; the
  CIRCUIT sets it) turns them on; `track.chip_spots[0..chip_n]` (a cache
  `track.select` fills, like the crates) are 8 trails of 3 chips along the
  line, offset across the road in turn. **`World.chips: u32`** has bit k
  set while chip k is taken; every taken chip comes back each 240 ticks
  (`chip_clock`; first planned as "on the leader's next lap", which left
  none for the back of the field). A car on the ground whose centre comes within its
  radius + 3 px takes one: **`Car.chips`** counts them, and an **event
  `chip`** (car, chip index; x, y the chip) tells the presentation.
- **CYCLES accounting is outside `simulate`** (`career.zig`, pure, host
  tested): at the race end it reads each car's `rank` (place: 1000 / 600
  / 400 / 250 / 150 / 100), `kills` (the last-hit wreck credit: 150
  each), `chips` (10 each), and adds the league win (1500) at a league's
  end. `career.Career` holds the circuit: the player's racer, league and
  race, the open leagues, the player's wallet, every racer's points,
  loadout, CYCLES earned and spent, each AI's place in its upgrade plan,
  and the last race's award (for the standings). `setup(seed)` gives the
  next race's `world.Setup` (track = league x 3 + race, the player in slot
  0, the six loadouts, chips on). `finish_race(&w)` books the race,
  `league_over()` / `league_result()` / `advance()` close a league (top 3
  opens the next; otherwise it is replayed, CYCLES kept), `buy(slot,
  pick)` is the garage, `ai_shop()` the AIs' plans.
- **AI upgrade plans** (SPEC 4.3, 9.2): a fixed list of slots per racer
  (LEGACY: PLATING first, then front L2, never CLOCK; KIDDIE: CLOCK
  first, never PLATING; and so on), bought in order before each race with
  a budget of the larger of the AI's own CYCLES and a share of what the
  player has spent, so difficulty follows the player's and is a pure
  function of the races so far.

### Work list

1. M5.0 in `world.zig`, `sim.zig`, `weapons.zig`, `track.zig` (chips),
   with tests: each upgrade's effect, ECC L3, the chips, and the M0-M4
   replays unchanged (golden fingerprints of seeded races recorded
   before the change, and the four input scripts' `debug_world_sum`
   pinned in `check.sh`).
2. `career.zig` (CYCLES, points, leagues, garage prices and purchases, AI
   plans) and `career_test.zig` (CYCLES accounting, purchases, AI plans
   deterministic and rising with the player's, a scripted full-circuit
   soak to the end card with the autopilot driving).
3. Presentation: CIRCUIT in the main menu (SPEC 8.1 order: QUICK RACE,
   GARBAGE COLLECTION, CIRCUIT, LINK, SOUND); the racer select without a
   track row; **the garage** (`garage.zig`, SPEC 9.2: the portrait, the car
   on its turntable, the slot list with levels and prices, Up/Down a slot,
   Left/Right an item, A buys, a one-line reaction from the racer's
   portrait per purchase, in each racer's voice: `roster_text.zig`);
   results with CYCLES; **standings** (points table and the CYCLES
   breakdown); the **league card** (won / cleared / failed), the
   **unlock card** (the Runoff), the **circuit end card** (SPEC 8.2: "You
   reached the fence. The Hyperscalers did not notice."). Chips drawn on
   the floor (a `hud.png` cell) with a `+10` pop; BURST pips up to 4.
   Career state in RAM only, no saves (SPEC 17.6).
4. Polish: `TAGGED!` (and every world-anchored text) kept on screen; A on
   the title goes straight to the Quick Race select (two presses, SPEC
   8.1); the balance pass (dangerous; measured in the circuit soak); the
   bench profile and any fast path the new screens or chips need.
5. Gate: `tools/check.sh` gains the golden replays, a circuit preview run
   (menu to garage, a purchase, a race, standings) and a circuit bench
   (a recorded circuit race with chips, plain and `--lcd`); worst frame
   under 8 ms; RAM free reported (62,752 B at M4).

### M5 gate

`tools/check.sh` PASS; the full-circuit soak reaches the end card; the
M0-M4 replays unchanged; bench under 8 ms; `docs/preview_m5.gif` (garage
purchases with reactions, standings, the league unlock, the end card);
PLAN "M5 status"; deferred questions L28 on. The lead tags
`snouty-gc/m5` and merges.

### M5 status

**2026-10-05, branch `gc/present`.** The SNOUTY GCP (CIRCUIT) is playable
from the main menu to the end card; the polish list is done. Commits:
the plan (9e86ef55), the sim side (f0b7e09e), the screens and polish
(54bc7ebd), chips every 4 s and the docs (4e8845d8), this status.

- **M5.0 as planned** (`world.Loadout`, `Setup.loadouts`, `Setup.chips`,
  `Car.ecc` / `burst_max` / `watchdog` / `chips`, `World.chips_on` /
  `chip_clock` / `chips`, event `chip`; L34 changed the chips' return to
  every 240 ticks). **World 2,540 B** (cap 2,560 kept), `Car` 116 B. The
  stock setup is the M0-M4 car: `career_test.zig` replays five seeded
  4,000-tick races (race on tracks 0, 3, 4, GC on 1, attract on 5) to
  fingerprints recorded at 90683be4, with the default and with an
  explicit stock `Loadout`; `check.sh` pins the four input scripts at
  update 2,999 (`m0_race` 1,125,151,687, `m2_race` 1,116,132,432,
  `m3_gc_race` -1,540,294,026, `m3_outflow_race` 69,064,753: as at M4).
- **Career** (`career.zig`): CYCLES 1000/600/400/250/150/100 by place,
  150 a credited wreck, 10 a chip, 1500 a league win; points 9/6/4/3/2/1;
  top 3 opens the Runoff, the Runoff's top 3 ends the Prix; SPEC 9.2's
  prices; AI plans per racer (LEGACY never CLOCK, KIDDIE never PLATING)
  on 75% of the player's garage spending (L35).
- **Screens**: CIRCUIT in the menu, the select's `A ENTER THE PRIX`, the
  garage (`garage.zig`) with 60 reaction lines, the standings, league,
  unlock and end cards (`standings.zig`), chips on the floor (a new
  `hud.png` cell, `+10` pops), four BURST bolts, `TAGGED!` clamped on
  screen, A on the title to the Quick Race select (two presses).
- **Tests** (`zig build test-gc`: **137 pass**, 21 new in
  `career_test.zig`): the golden races, each upgrade (PLATING to 230 on a
  MAINFRAME, ECC ignoring 1..4 with no kill credit, PING L3 chipping ECC
  in a frozen scenario, CLOCK, TRACTION, BURST BUFFER 1..4 refilled on
  the line, WATCHDOG 120/90/60/40 with the hulk, weapon levels and swaps,
  LOGIC BOMB L3 44), chips (20+ on every track, all on the floor, the
  autopilot takes some, one event each, they come back, none without
  `Setup.chips`), CYCLES and points, a league won / failed / cleared,
  standings ties, the garage's prices, poor and maxed, every reaction
  fitting two rows, the plans' rules, plans deterministic and rising
  with the player's spending, and the **circuit soak**: the autopilot
  (SNOUTY's AI) drives SNOUTY and KIDDIE through whole Prix to the end
  card, buying the cheapest level it can before each race (12 races each,
  two failed leagues; about 4.8 wrecks a race; L37 has the other racers).
- **check.sh**: the golden replays, the title shortcut, a CIRCUIT run
  (menus, garage, two purchases, a real race to the standings, then
  made-up results to the league, unlock and end cards), two new benches.
  **PASS** (test via test-gc: another cart's runner fails in `zig build
  test`, as before).
- **Bench** (calibrated; `--lcd` identical, mean / worst ms): `m0_race`
  3.65 / 5.22; stress 5.02 / **6.17**; `m2_race` 3.58 / 5.22;
  `m3_outflow_race` 3.64 / 5.71; `m3_gc_race` 3.49 / 5.67; new
  `m5_circuit_race` 3.51 / 4.66 (the garage, then a CIRCUIT race with
  chips and upgraded AIs); new `m5_cards` 1.75 / 5.43 (the unlock card's
  A frame: its floor plus the garage drawn over it). Probe: stress 5.17 /
  6.34, GC 3.59 / 5.80. The one fast path: the end card's chain-link
  fence by columns (6.39 -> under 4 ms on that card).
- **RAM**: `size -A` **.text 162,188 + .data 7,688 + .bss 52,144** (+
  1,728 exidx/extab + descriptor) = 223,768 B, **50,408 B (49 KB) free**
  (M4: 62,752).
- `docs/preview_m5.gif` (644 frames, 60 ms): the menu's CIRCUIT row, the
  select, the garage (SPEAR PHISH L2 and SNOUTY's line, PING shown as an
  800 swap, PLATING L1 and L2, then `NO CYCLES. I'LL GO HUNT SOME.`), a
  CIRCUIT race with chips, the real results and standings (4th, 8 kills,
  8 chips: +1,530), then made-up results: the Dumps PRIX WON card, NEW
  PRIX UNLOCKED over the Runoff, the Runoff's card and the end card.
- **On a badge**: never run. Check the garage's text and pips at 1:1, the
  chips' readability at speed, that a human can clear the Dumps (L37), the
  title's A, and the menu's five rows.

### Integration (menu-fix, lockstep)

**2026-10-05, branch `gc/integrate`** (worktree
`/home/exedev/snouty-badge-gc-m5merge`, off main bf0cac90 = M5). Merged
`gc/menu-fix` (PICKUPS page, the 18-char panel guard, the Snouty GCP
rename and lockup, short hints) and `link/gc-lockstep` (net.zig over
`lib/lockstep.zig`, `net_m4.zig` + `net_compat_test.zig`, WRONG VERSION),
then origin/main (lockstep `wants_pump`, bf037753).

- **Main menu**: QUICK RACE, GARBAGE COLLECTION, CIRCUIT, PICKUPS, LINK,
  SOUND. Geometry in `menu_text.layout`, built for M6's 7 rows (BATTLE
  after GARBAGE COLLECTION): lockup (SNOUTY 1x, GCP 2x) at y 3, ink to
  y 20; rows 11 px apart in a panel `n * 11 + 5` tall, centred in
  y 23..104 (7 rows: 23..104 exactly; the 6 shipped: 28..98); a bar from
  y 107 to the bottom with one hint line at 109 over `A SELECT  B BACK`
  at 119 (L46). `panel_text_test` checks 1 to 7 rows; the wasm
  `debug_menu_battle:1` draws a made-up BATTLE row (check.sh `menu7`).
  PICKUPS is `debug_screen` 11 (M5's 8 to 10 kept).
- **Title**: `A  QUICK RACE` (grey) in PRESS START's off half (L48).
- **Lockstep**: the wire stays M4's (`net_compat_test` passes); WRONG
  VERSION adds `SAME BUILD ON BOTH`, `debug_link_view:7` fakes it.
- **RESUME fix** (`net.Resume`, main.zig and net_test use the same
  code): RESUME / B hold Start on every submitted byte until `paused`
  turns off, after one kept byte without Start if the last kept byte had
  it; `Net.submit` returns whether it kept the byte. One rising edge in
  the kept bytes, so no double toggle. New test: 24 pauses under 1% byte
  loss, RESUME picked inside a stall: all resume both badges on one
  tick, once (10 of 24 had the first held Start dropped: M4 lost those);
  plus a unit test of the edge rules (L50).
- **wants_pump**: the after-draw pump loop runs while
  `lnk.wants_pump()` (a race, or the link handshaking), so the LINK lobby
  and link select keep pumping through a HELLO (10 wire bytes, 8-byte
  FIFO). Searching and a settled lobby now pump once a frame (before,
  GC's lobby looped to 14 ms in every state) (L51).
- **Gate**: `check.sh` PASS (test via test-gc: other carts' runners fail
  on missing ROMs). **148 tests** (M5 137 + menu-fix 5 + 3 net_compat +
  layout + 2 RESUME). Golden checksums unchanged. Bench (calibrated,
  `--lcd` identical, mean / worst ms): `m0_race` 3.63 / 5.19; stress 4.99
  / 6.14; `m2_race` 3.55 / 5.19; `m3_outflow_race` 3.61 / 5.71;
  `m3_gc_race` 3.46 / 5.64; `m5_circuit_race` 3.48 / 4.63; `m5_cards`
  1.75 / 5.40; probe stress 5.10 / 6.27, probe GC 3.54 / 5.74.
- **RAM**: `size -A` .text 164,520 + .data 7,688 + .bss 52,472 (+ 1,784
  exidx/extab) = 226,464 B; **47,624 B free** from the end of .bss to
  the stack (M5: 50,408 by the sum).
- `docs/preview_pickups.gif` re-recorded with the new menu (three Downs).

## M6 Battle (KILL -9)

Goal: SPEC 8.3 and 16 M6 (decision 16). A BATTLE round on The Sandbox:
six cars (or fewer by CREWS) with lives, scored on eliminations, ending by
lives or by time; the hunter AI; LINK BATTLE over the shared lockstep.
Lead: the M6 coordinator. Two Opus tracks after the M6.0 interface
commit, with disjoint files. Branch base: `gc/present` = origin/main
edd1ab92 (M0 to M5.1 merged, tag `snouty-gc/m5.1`).

### M6.0 Interface (Track A, committed before the tracks split)

Same contract as M1.0 to M5.0: only `sim.simulate` writes the World;
rendering reads the World, `track`'s caches and the event ring (its own
cursor) and never writes. Battle is additive: the race modes, their
replays and fingerprints are unchanged (`check.sh` pins the four input
scripts, `career_test.zig` the seeded races).

- **`world.Mode.battle`** and the options on **`world.Setup`**: `lives`
  (1, 3, 5, 9; **0 = INF**; default 3) and `minutes` (2, 3, 5; **0 =
  NONE**; default 3; NONE with INF lives is read as 3). The menus offer
  `tuning.battle_lives_opts` and `tuning.battle_minutes_opts` (SPEC 8.3's
  rows, in order). `Setup.track` indexes **`track.arenas`** in battle
  (The Sandbox is 0; M7's pack arenas join after it), `track.tracks`
  otherwise; `sim.track_of(w)` picks the table by `w.mode`. `Setup.crews`
  keeps its meaning (AI cars on the grid: 5..1 single player, 4/2/0 link).
- **`World.battle`** (`world.Battle`): `lives` (each car's at the start,
  0 = INF), `limit` (the round in ticks, 0 = none), `refill` (ticks until
  the next ammo and burst refill: counts down from
  `tuning.battle_refill` = 1200; the HUD sweep is `refill /
  battle_refill`), `out` (bit i: car i is out of lives), `leader` (the
  kill leader: most eliminations, ties to the better rank; `no_car` until
  someone scores), `end` (`world.BattleEnd`: `none`, `lives` = one car
  left, `time`). The round clock is `w.tick` (ticks since GO): time left =
  `limit - tick`.
- **`Car.lives`** (left; meaningless with INF), **`Car.kills`** = the
  car's eliminations (the existing last-hit credit within
  `tuning.credit_ticks` = 180; a wreck with no hit scores nobody),
  **`Car.safe`** (SAFE MODE ticks left, 90 after a battle respawn: the car
  blinks, cannot be hit (`immune` runs with it) and cannot fire, ram,
  smash or use a pickup), **`Car.nav`** (the hunter's waypoint, internal).
  An out car is `active = false` with its bit in `battle.out`, its `rank`
  its final standing and `finish_tick` the tick it went out. At the end
  every car still in gets `finished` and `finish_tick`, ranks are final
  and `phase` is `finished`.
- **Ranks in battle** are the standings: eliminations, then lives left
  (INF: fewer wrecks), then time survived, ties to the lower index. The
  pickup odds read them (SPEC 8.3).
- **Events** (`EventKind` gains four): `eliminated` (a = the killer, b =
  the victim, c = the killer's eliminations now; x, y the victim: the
  `kill -9 KIDDIE` feed); `out` (a = the car, b = the cars still in after
  it, c = 0; x, y the hulk: the claw comes down there; its standing is its
  `rank`, which keeps moving with the others' scores until the end);
  `stack_smash` (a = the car
  that landed, b = the car under it, c = damage; x, y the victim);
  `clean_landing` (a = the car, b = its burst charges now). The `wreck`
  and `respawn` events are unchanged.
- **Arena data** (`track.Track.arena`, a blob; empty on a race track):
  spawn pads (x, y, heading), crate pads (x, y), and the navigation field
  (a 32x32 grid of 32 px cells, each the waypoint to head for; up to
  `track.nav_max` waypoints with flags `bay` / `jump`, and an all-pairs
  next-hop table). `track.select` unpacks it into the caches
  `track.arena` (`Arena`: `spawns[0..spawn_n]`, `nodes[0..node_n]`,
  `next`, `cells`, `bays`), and the crate pads into `track.crate_spots`
  as the race rows are. The format is documented in `track.zig` and
  `tools/build_arena.py`. The arena also has a ring centerline (256
  samples) so the race code that reads one keeps working; battle never
  ranks or respawns by it.
- **Tile attributes `kicker`** (3, was Zero's unused `reserved`) and
  **`jump`** (11): the arena's one-way ramps. They launch only a car
  moving the way the tile faces (`track.facing(tile)`), so a landing on
  the far side's ramp does not relaunch; `kicker` flies
  `tuning.kicker_ticks` (64: the bit bucket), `jump` a race ramp's 40 (the
  corner gaps, the wall kickers). New Dumps tiles at unused indices:
  `KICKER` 64 + direction, `JUMP` 92 + direction, `PAD_SPAWN` 23 +
  direction, `PAD_CRATE` 27; the race maps do not use them. The touchdown
  tick reads the floor in battle (a landing in a pit or on a wall is
  resolved on the tick the stunt is scored).
- **World cap** 2,560 -> **2,624 B** (`tuning.world_cap`; World 2,572 B,
  `Car` 120 B).
- **Debug exports** (wasm, main.zig; the simulator fakes): `debug_start_battle:N`
  (a round on The Sandbox with the select's racer, N lives (0 INF), 3 min),
  `debug_battle_minutes:M` (the next round's TIME, 0 NONE),
  `debug_battle_crews:K`; reads `debug_battle_lives:i`,
  `debug_battle_elims:i`, `debug_battle_safe:i`, `debug_battle_left`
  (ticks left, 0xFFFFFFFF none), `debug_battle_refill`,
  `debug_battle_out`, `debug_battle_leader`, `debug_battle_end`; fakes
  `debug_battle_set_lives:(car | lives << 8)`, `debug_battle_kill:(victim
  | killer << 8)` (a credited wreck; killer 255 = none), `debug_battle_clock:T`
  (T ticks left). badge-bench `--poke gc_battle=1`: an AI-driven battle on
  The Sandbox at boot (SNOUTY on the autopilot, 3 lives, 3 min);
  `gc_battle=2`: the render stress scene placed in the arena.
- Stubs: The Sandbox loads (`track.sandbox`, `track.arenas`) and
  `battle.zig` (the rules) compiles; main.zig's `Mode.battle` (debug_mode
  5) runs a round from `debug_start_battle` with race visuals. Track B
  replaces that flow.

### Track A: battle simulation (lead's agent, worktree /home/exedev/snouty-badge-gc-present, branch gc/present)

Owns `world.zig`, `sim.zig`, `weapons.zig`, `pickups.zig`, `hazards.zig`,
`gc_mode.zig`, `ai.zig`, `tuning.zig`, `racers.zig` (gameplay), `track.zig`,
new `battle.zig` (rules) and `hunt.zig` (the hunter AI),
`tools/build_tracks.py`, `tools/leagues.py`, new `tools/build_arena.py`,
`cart/src/tracks/`, `cart/src/gen/tracks/`, the sim tests (`sim_test`,
`weapons_test`, `pickups_test`, `content_test`, `career_test`, new
`battle_test.zig`), `host_tests.zig`, `tools/check.sh` (the `tracks`,
golden and `bench` steps; Track B adds its preview runs only inside the
`# --- M6 Track B previews` block), the battle bench scripts
(`tools/scripts/m6_*.json`), PLAN "M6 status" Track A paragraph.

1. **The Sandbox** (`tools/build_arena.py`, run by `build_tracks.py` so
   the `tracks` gate covers it): a walled 704 px square in the Dumps
   tileset. The bit bucket (a 128 px pit in the middle) with a kicker on
   each side; four wall-ringed scrap islands at the diagonals; fences
   between the outer ring and the four plazas with a wall kicker on each
   side of the ring that jumps the fence; gap jumps (ramp pairs) near
   the corners on the west and east straights; 8 crate pads (one per
   lane: the four ring straights, the four plazas); 2 service bays in
   the NW and SE corners at half the repair rate; 6 spawn pads on the
   rim facing in; the Sweeper along the north straight on its timer; the
   navigation field with jump edges over the kickers.
2. **Rules** (`battle.zig`): lives, respawn at the pad farthest from the
   nearest enemy, SAFE MODE 90 ticks, eliminations by last hit within
   180 ticks, no-hit wrecks score nobody, out of lives = out, the round
   end by lives or time, the standings.
3. **Refills** every 1200 ticks (ammo and burst charges).
4. **Stunts**: STACK SMASH (40 damage on landing on a car, a ram bounce,
   the hit counts), CLEAN LANDING (a ramp landing clear of walls gives a
   burst charge back).
5. **Pickups**: "ahead" = the nearest car in the front 90-degree cone,
   else the nearest car; KERNEL PANIC homes on the kill leader (2nd if the
   user leads) along the navigation field; ZERO-DAY only for the bottom
   two of the standings, once per round; the odds use the standings.
6. **The hunter AI** (`hunt.zig`, called by `ai.drive` in battle): target
   by crew (nearest, biased to the human and the kill leader by crew),
   nav-field steering with the jumps, fire in the cone, rear drops when
   chased, retreat to a bay below 30% armor, around the Sweeper.
7. **Tests** (`battle_test.zig`): the arena's data, a scenario per rule,
   a soak of 5-AI rounds ending by lives and by time, AI eliminations
   against each other, a determinism replay, the jumps; the bench script
   `m6_battle.json` (`--poke gc_battle=1`) and the arena stress
   (`--poke gc_battle=2`), plain and `--lcd`, worst under 8 ms.
8. Balance errs dangerous; rounds about 2 to 3 minutes at 3 lives.

### Track B: battle presentation and link (Opus agent, worktree /home/exedev/snouty-badge-gc-battle-ui, branch gc/battle-ui off the M6.0 commit)

Owns `main.zig`, `menu.zig`, `menu_text.zig`, `select.zig`, `hud.zig`,
`render.zig`, `sprites.zig`, `fx.zig`, `results.zig`, `standings.zig`,
`stress.zig`, `camera.zig`, `link_ui.zig`, `net.zig`, `net_test.zig`,
`net_compat_test.zig`, `panel_text_test.zig`, `roster_text.zig`, new
`battle_ui_test.zig` (registered in `host_tests.zig` by M6.0), the art
(`tools/draw_art.py`, `tools/art/`, `assets/gen/art/`, `ASSETS.md`),
`docs/RUNNING.md`, `docs/NET.md`, `docs/LINK_PLAY.md`, the previews and
GIFs, the `# --- M6 Track B previews` block of `check.sh`, and PLAN "M6
status" Track B paragraph. Merge `origin/gc/present` in as Track A pushes.

1. **Menu**: BATTLE after GARBAGE COLLECTION (`menu_text.layout` fits 7
   rows), its hint line.
2. **Battle setup**: LIVES (1/3/5/9/INF), TIME (2/3/5 min/NONE; NONE not
   offered with INF), CREWS (5..1 AI cars) after the racer select; the
   `KILL -9` title card ("no cleanup handler, no appeal").
3. **Battle HUD**: lives pips, eliminations, the clock, the ammo bar's
   refill sweep (`battle.refill`), SAFE MODE blink (`Car.safe`), the
   whole-arena minimap (the map, cars, crate pads), the `kill -9 KIDDIE`
   feed (`eliminated`), STACK SMASH and CLEAN LANDING notices, the claw on
   the last life (`out`), the spectate camera (the kill leader's) once
   out.
4. **Results**: battle standings (eliminations, lives, time survived),
   the winner's card.
5. **LINK BATTLE** in the lobby: `rules_len` 5 and `G.version` 1 through
   `lib/lockstep`'s paged SETUP (docs/LOCKSTEP.md 4.3, 4.7): mode, the
   arena, CREWS 4/2/0, LIVES, TIME; an older GCP build sees WRONG
   VERSION, never a desync. `net_test`: link battles in sync to the end,
   lossless and with 1% loss.
6. Docs (RUNNING.md, NET.md, LINK_PLAY.md), `docs/preview_m6.gif`.

### M6 gate

`tools/check.sh` PASS at the merged head; the four race scripts and the
seeded races replay unchanged; the 5-AI soak ends by lives and by time
and the AIs score eliminations; the virtual-cable link battle stays in
sync to its end (lossless and 1%); the arena bench and stress worst under
8 ms (calibrated, plain and `--lcd`); RAM free reported (47,624 B at
M5.1); deferred questions from L52.

GIFs (`docs/preview_m6.gif`, Track B): the menu's BATTLE row, the setup
screen, the `KILL -9` card, a round with the HUD, a jump over the bit
bucket, a STACK SMASH, `kill -9` in the feed, SAFE MODE blinking, the claw
on a last life, the spectate camera, the clock running out, the results.
Track A records `docs/m6_sandbox.png` (the arena map with its pads and
navigation field) from the generator.

### M6 status

**Track A (battle simulation), 2026-10-05, branch `gc/present`.** M6.0
interface 3a112fbd; then the hunter, pickups and damage (2ff29e5b), the
rule scenarios and `Car.air` (fb56feed), the lead-approved `car_lift`
fix in sprites.zig (18abaaae: a kicker hop outlasts `tuning.ramp_ticks`
and crashed the ReleaseSmall bench), the kicker air test (704ed99c), this
status.

- **The Sandbox** (`tools/build_arena.py`, run by `build_tracks.py`, so
  the `tracks` gate covers it; `docs/m6_sandbox.png`,
  `docs/sandbox_preview.png` with the nodes and edges): a walled 704 px
  square at tile 22 in the Dumps tileset. The bit bucket is a 128 px pit
  with a 64-tick kicker on each side (clean from 2.2 px/tick, a crawl
  falls in). Four wall-ringed scrap islands sit at the diagonals (a
  landing on one is a fall). Fences separate the outer ring from the four
  plazas, with a 40-tick wall kicker on each ring straight that jumps the
  fence. Gap jumps (5-tile pits with a jump each side) cross the west and
  east straights near the corners (clean from 1.4 px/tick). There are 8
  crate pads (one per lane), 2 bays (NW, SE corners, 1 armor / 8 ticks),
  6 spawn pads facing in (none on the north straight), and the Sweeper on
  the north straight (period 1200, 2 px/tick). The nav field has 34 nodes,
  260 ground edges and 16 jump edges, two next-hop tables (with the jumps,
  and ground only for a car too slow for its run-up) and a 32x32 grid of
  32 px cells. The arena blob is 3,616 B; with the map (2,338), the ring
  centerline (1,536) and the Sweeper record (20), the arena adds 7.5 KB.
  New Dumps tiles: `KICKER` 64+d, `JUMP` 92+d, `PAD_SPAWN` 23+d,
  `PAD_CRATE` 27. The arena's ramps are one-way (attributes `kicker`, `jump`).
- **Rules** (`battle.zig`): lives (INF never out), eliminations by the
  existing last-hit credit (180 ticks, falls included), no-hit wrecks
  score nobody. A respawn goes to the pad farthest from the nearest
  enemy, in SAFE MODE for 90 ticks (immune; no fire, rams, smash or
  pickup use). Out of lives = out (`active = false`, `out` event). The
  round ends by lives or time. Standings go by eliminations, then lives
  (INF: fewer wrecks), then time survived. A full ammo and BURST refill
  comes every 1200 ticks, and the kill leader is tracked. STACK SMASH (40
  and a bounce, a credited hit) and CLEAN LANDING (+1 BURST) happen on the
  touchdown tick.
- **Pickups**: "ahead" is the nearest car in the 90-degree front cone,
  else the nearest (the race ranges as Euclidean px). KERNEL PANIC runs
  node to node to the kill leader's cell (2nd if the user leads).
  ZERO-DAY rolls only for the bottom two of the standings, once a round.
  DEADLOCK's wall chain anchors on the nearest node.
- **Hunter** (`hunt.zig`): the target is the nearest car with per-crew
  bias to the human, the kill leader, the hurt and the aimed-at; with
  nobody to hunt it goes to the nearest crate. It chases on a clear ground
  line and otherwise follows its waypoint (`Car.nav`, kept by
  `update_nav`). A jump leg is committed only at the run-up speed. In a
  dogfight it extends out instead of circling, swings off nose-to-nose
  stalls, and steers off pits and stray ramps. It escapes the Sweeper and
  retreats to a bay below its crew's armor share (KIDDIE never, LEGACY
  20%, ROOTKIT 40%, the rest 30%; it holds to 80%). It fires and drops
  with the race habits (`ai.arm`), and its LANCE charges when a car is in
  the cone.
- **Balance**: battle damage is 18% of the race's
  (`tuning.battle_damage_pct`, with the fraction carried per car in
  `Car.dmg_frac`). **Soak** (8 rounds, 3 lives, TIME NONE, SNOUTY on the
  autopilot plus 5 hunters): all end by lives, **mean 126 s** (59 to 178
  s), 113 eliminations (79 AI on AI) over 133 wrecks, 68 of them falls
  (most credited: pushed into a pit; about 15% of wrecks score nobody),
  1 car slow for 600 ticks (holding at a bay). INF lives, 2 min: 3 of 3
  end by time at 7,200 ticks with 15 to 26 eliminations.
- **Tests**: 168 pass (M5.1 had 148; 18 in `battle_test.zig`, 1 in
  `battle.zig`, the Track B placeholder). The race goldens are unchanged
  (`career_test`, and `check.sh`'s four scripts).
- **Bench** (calibrated, `--lcd` identical, mean / worst ms): the new
  `m6_battle` (`--poke gc_battle=1`, 3,600 frames: SNOUTY on the
  autopilot among five hunters) **3.35 / 5.24**, the arena stress
  (`--poke gc_battle=2`) **4.71 / 5.94**; unchanged: `m0_race` 3.63 /
  5.20, stress 4.99 / 6.14, `m2_race` 3.56 / 5.20, `m3_outflow_race` 3.62
  / 5.75, `m3_gc_race` 3.47 / 5.65, `m5_circuit_race` 3.49 / 4.63,
  `m5_cards` 1.75 / 5.40, probe stress 5.10 / 6.27, probe GC 3.54 / 5.75.
  `check.sh` **PASS** (all steps; `zig build test` passed for every cart).
- **RAM**: `size -A` .text 179,584 + .data 8,088 + .bss 52,472 (+ 1,912
  exidx/extab) = 242,056 B: **about 32,000 B free** (M5.1: 47,624). The
  arena data is 7.5 KB of it, the hunter and rules about 7 KB of code. World
  2,572 B (cap raised to 2,624, `tuning.world_cap`), `Car` 120 B.


**Track B (presentation and LINK BATTLE), 2026-10-05, branch
`gc/battle-ui`** (worktree `/home/exedev/snouty-badge-gc-battle-ui`, off
the M6.0 commit 3a112fbd; `origin/gc/present` merged up to f4c0eceb,
Track A's finished head). The BATTLE presentation and LINK BATTLE are in;
PLAN's Track B list is done. Decisions L80-L93.

- **Flow**: the menu's BATTLE row (third, `ARENA, MOST KILLS`), the racer
  select (`A  TO THE ARENA`), the setup over the arena's floor (arena,
  LIVES 1/3/5/9/INF, TIME 2/3/5/NONE with NONE skipped on INF, CREWS 5..1,
  FIGHT!; `battle_ui.zig`, words and rows in `battle_text.zig`), the
  `KILL -9` card over the countdown's READY and 3, the round, pause
  (RESUME / RESTART / QUIT / SOUND), the winner card and standings.
  Screen 12 is the setup.
- **HUD**: ELIM, the clock (last 10 s blinking; TIME NONE counts up), the
  standing, lives pips (INF), the refill sweep, the whole-arena minimap
  (one draw path with the race minimap at an arena scale), feed lines
  `kill -9` / `REAPED` / `SMASHED` and `SMASH!`, bar pops STACK SMASH! /
  STACK SMASHED / CLEAN LANDING, SAFE MODE, TIME UP / LAST ONE STANDING,
  the GC claw on a last life, `REAPED` and the kill leader's camera once
  out. Results: TOP KILLER / LAST PROCESS UP and the standings (ELIM,
  `LIVES n`, `WRECKS n`, `OUT m:ss`) with the half portraits.
- **LINK BATTLE**: the lobby's mode row cycles LINK RACE / LINK GC / LINK
  BATTLE; LINK BATTLE shows the arena and LIVES / TIME rows (six rows),
  the link select its rules. `net.Game` is version 1 with five rules bytes
  (mode, track or arena, CREWS, LIVES, TIME) in lockstep's paged SETUP;
  `net.GameV0` keeps the M5.1 wire for the compat tests (L84).
- **Tests**: **182 pass** at the merged head (`zig build test-gc`, the
  binary run directly). Track B's: `battle_ui_test.zig` (10: panel
  widths, setup rows, the card's window, the clock, standings lines, the
  winner title, the lobby's rows and changes, the agreed setup),
  `net_test` (the wire test with LINK BATTLE's bytes and junk decoding;
  the five bytes reaching the guest through 1% loss; 6 seeded LINK BATTLE
  rounds in sync every tick to their end, clean: 31,530 ticks, 0.35% of
  packets lost to the FIFO model, at most 13 frames in a row without a
  tick; 6 with 1% byte loss: 40,286 ticks, 8.6% lost, at most 17 in a
  row), `net_compat_test` (v0 still M4's bytes; the cart's v1 against M4;
  v0 against v1 either side, both cables, clean and 1%: both
  `wrong_version`, no DATA packet, never racing). Two harness fixes (L92).
- **check.sh PASS** at the merged head (test via test-gc as before).
  Track B's previews: the 7-row menu to the setup (B back, LIVES INF,
  TIME 2) and a round; LINK BATTLE in the made-up lobby and select, WRONG
  VERSION; a last life (`debug_battle_kill`), the claw, the kill leader's
  camera, pause and resume, the round to its results; the arena stress.
  The menu-dependent runs outside the block moved by one Down (L91).
  Golden checksums unchanged.
- **Bench** (calibrated, `--lcd` identical, mean / worst ms): `m6_battle`
  (`--poke gc_battle=1`, 3,600 frames, the battle HUD on Track A's
  hunter) 3.43 / 5.27; arena stress with the battle HUD's stress (`--poke
  gc_battle=2`) 4.85 / 6.13; the race benches as before (`m0_race` 3.62 /
  5.19, stress 4.99 / 6.14; probe stress 5.10 / 6.26, probe GC 3.55 /
  5.64; the rest within 0.05 ms of Track A's). The
  first merged bench found a ReleaseSmall crash in `sprites.car_lift` (a
  kicker's 64-tick hop); Track A fixed it with `Car.air` (18abaaae).
- **RAM**: `size -A` .text 185,640 + .data 8,104 + .bss 52,428 (+ 2,008
  exidx/extab) = 248,180 B; **25,908 B free** from the end of .bss to the
  stack (Track A's head alone: 32,008; M5.1: 47,624), so Track B costs
  6,100 B. Two size fixes on the way: `hud.fill_rect` is one out-of-line
  body (its generic `w`/`h` had made a copy per call shape: 1.8 KB
  across the cart), the winner cards share their own-place and taunt
  lines, and the arena and race minimaps one draw path.
- `docs/preview_m6.gif` (463 frames, 50 ms, every third update: real
  time; `tools/m6_gif.py cut 344`): the title, the menu's BATTLE row, the
  select, the setup (TIME 2, LIVES 5), the KILL -9 card and countdown,
  a STACK SMASH, a CLEAN LANDING over the bit bucket, kill -9 lines, a
  wreck and the respawn in SAFE MODE, the claw on SNOUTY's last life and
  the kill leader's camera, TIME UP, the winner card and the standings.
- **On two badges**: never run; `docs/LINK_PLAY.md` items 10 and 11 are
  the LINK BATTLE and version checks.


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

Taken during M2 (Track A, pickup simulation):

32. **Crate rows** are a centerline flag (bit 2) on one sample, not a new
    data file, so `build.zig` needs no new asset. 4 crates 20 px apart on
    road at least 56 px half width, else 3; their touch radius (16) makes a
    row cover the lane, as Mario Kart's item rows. Three rows on Landfill
    Loop (SPEC asks two at least). A car that holds a pickup drives through
    a crate and leaves it; airborne cars pass over. The service bay stays
    unbuilt (not in the M2 contract; M3 with the other track features).
33. **The roll happens at the crate** (SPEC: "at the moment of contact");
    the result sits hidden in `Car.pickup` while `roll_ticks` runs. ZERO-DAY
    counts as used when it is rolled.
34. **"Ahead" means race progress** (`sim.progress_px`), for BIT FLIP and
    DEADLOCK (within 400 px), RACE CONDITION (300), DDOS and ZERO-DAY (any
    distance). A pickup with no target is spent for nothing (a human's
    whiff); the AIs wait for a target, except KIDDIE.
35. **What HEISENBUG and SUDO shield**. HEISENBUG: no lock, homing and
    drones let go, the AI ignores the car (aim, drops, rams, passing),
    BIT FLIP / DEADLOCK / DDOS / RACE CONDITION cannot pick it, the KERNEL
    PANIC packet waits behind it, it passes through cars, hulks and drops
    (bomb blasts too); plain shots and the LANCE still hit (they aim, not
    observe); it still takes crates. SUDO: no damage of any kind, and no
    status from a rival's pickup (not picked by BIT FLIP, DEADLOCK, DDOS,
    RACE CONDITION; exempt from CAPTCHA; the packet and drones fizzle on
    it). **ZERO-DAY goes through everything**, root included (a zero-day
    beats root). Falls still wreck a root car.
36. **RUBBER DUCK**: "the first hit from behind" is a shot or LANCE beam
    whose source is behind the car's heading; a SPEAR PHISH is drawn to the
    duck from any side and pops it; DDOS drones arriving at a ducked car pop
    the duck and the whole swarm disperses; BIT FLIP pops it instead of
    flipping. The KERNEL PANIC packet is not a homing weapon in SPEC's list,
    so the duck does not stop it.
37. **KERNEL PANIC** targets the best-ranked racing car other than the user
    (so 2nd when the user is 1st) and runs backward along the line when that
    car is behind; it homes once within 64 px or past the target's sample,
    and fizzles if the target wrecks or finishes. A packet has no life limit.
38. **Status numbers SPEC leaves open**: HONEYPOT spin 30 ticks (heading
    about a full turn, speed x0.92 a tick, no steering); thrown items land
    60 px ahead, pulled back to the nearest floor; pickup drops clear after
    30 s; SPAGHETTI touch radius 18 and it is used up by the first car; FORK
    BOMB children drift 24, 12, 6 px apart over 30 ticks after each fork,
    touch radius 14, a car can set off two at once; DEADLOCK's chain pulls
    the pair together at 0.08 px/tick^2 so "until they touch" happens; DDOS
    drones fly at 7 px/tick through walls, orbit at 16 px, 1 HP against any
    shot; PREFETCH also kicks +1 px/tick on use ("instant"); HOT PATCH +2
    armor every 3 ticks; SUDO's bounce 1.5 px/tick.
39. **CAPTCHA board**: three lit cells of nine, the cursor steps a cell
    every 5 ticks (a sweep in 45, so a clean solve takes up to about 45);
    A on a lit cell clears it, A on an unlit cell clears the board (so
    mashing does not solve it); the solving press does not fire; A never
    fires while the board is up. AI solve ticks: SYSADMIN 60, SNOUTY 75,
    ROOTKIT 80, LEGACY 100, BOTNET 110, KIDDIE 120. Root cars are exempt.
40. **RACE CONDITION swaps the place in the race** (sample, sectors and
    laps) with the position, so no lap is gained or lost overall across the
    start line; a pending swap is cancelled if either car wrecks.
41. **A wreck clears every pickup status** (and ends a chain or pending
    swap for the partner, disperses drones on it); the held pickup and a
    running roulette survive, as ammo does.
42. **AI triggers SPEC leaves open**: PREFETCH on a straight; HONEYPOT
    and SPAGHETTI dropped on a car within 120 px behind on the line, thrown
    at one 30..140 px ahead; FORK BOMB with any car within 200 px behind;
    BIT FLIP, DEADLOCK, DDOS, ZERO-DAY when a target exists; HEISENBUG at
    once (ROOTKIT: last lap); the AI does not shoot drones on purpose. Under
    BIT FLIP an AI steers the wrong way 6 ticks of every 32 (the weave).
43. **Pools**: shots 48 -> 40 and drops 32 -> 40 to keep the World under
    its cap with the new fields (2,436 B); the KERNEL PANIC packet is the
    last shot slot to be reused.

Taken during M2 (Track B, pickup presentation):

44. **Roulette caption** `FETCHING...` sits right-aligned against the box
    on the row under the rank (BEHIND's row; hidden while looking back);
    the reel shows random cells, never the hidden result, and the landed
    pickup's name replaces the caption for 60 ticks.
45. **Feed lines**: KERNEL PANIC, BIT FLIP, DEADLOCK, DDOS, HONEYPOT and
    SPAGHETTI hits read `PICKUP > VICTIM`, a swap `A <> B`; a wreck line is
    never overwritten by them. `KERNEL PANIC > SYSADMIN` is 23 characters
    and the 8x8 font fits 19, so a long line breaks after the `>` into two
    rows and the pop-up moves down 9 px.
46. **Which badge gets a gag**: the blue screen, BIT FLIP, DDOS, the
    ZERO-DAY flash and the glitch follow whatever car the badge follows
    (the attract demo shows them too); the CAPTCHA board only when that car
    is a human's (an AI gets the tag).
47. **The CAPTCHA card** is x 4..156, y 25..124 (a three-line header, so
    the grid's centre is y 85, not the floor's 80) and covers the bottom
    HUD while it is up; `TRY AGAIN` after a miss, `HUMAN VERIFIED` in the
    bar on a solve (not after the 120-tick timeout).
48. **The blue screen** replaces the frame (no floor, no HUD) for its 30
    ticks and names the sender as a driver file (`KIDDIE.SYS`).
49. **Tints**: KERNEL PANIC blue and SUDO gold are luma-mapped palettes
    (comptime, every sheet: about 1.3 KB); SUDO flashes gold every 4
    frames, the hit flash keeps flat white.
50. **HEISENBUG** flickers every car on it, the badge's own included.
51. **DDOS stutter**: the speed reading cycles real, real, `503` (coral),
    blank, 5 frames each, while any drone orbits the car.
52. **ZERO-DAY flash** only on the user's and the victim's badges (2 white
    frames, then a red frame for 6); everyone sees the red dart.
53. **FORK BOMB telegraph** assumes the sim forks at ages that are
    multiples of 60 (`fork_every` is repeated in sprites.zig as a render
    constant).
54. **Debug writes**: the preview hooks and the stress scene write the
    World (and the stress scene the track's crate cache, rebuilt by the
    next race); they are wasm exports or the `gc_stress` poke only, never
    reached in play.

Taken during M3 (Track A, content and mode simulation; numbered 36 to 50
on gc/spec, renumbered 55 to 69 at the merge with M2 Track B's 44 to 54):

55. **Track data lives in `cart/src/gen/tracks/`**, embedded by
    `track.zig` with `@embedFile`, because `build.zig` (whose `assets`
    list a new track would need) is the presentation track's file; a new
    track is now a `.track` file, a generator run and a line in
    `track.tracks`. The stale `assets/gen` copies wait for build.zig.
56. **RAM is the binding constraint**: merged with the M2 presentation
    the cart has 11.3 KB left. Track A already packed the league art into
    one RAM slot, made the backgrounds a 32-tile wallpaper and shrank the
    samples. Further room, in order of cost: build the cart
    `ReleaseSmall` for the sim only, or mark the big sim paths noinline
    (`sim.simulate` is 32 KB with everything inlined); drop unused tile
    slots (a 128-tile set holds ~100 tiles; the renderer reads 8 bpp);
    the art sheets; the Perimeter league as a pack (SPEC 19). M4 and M5
    should measure before adding.
57. **Hazard numbers SPEC leaves open**: vent warning 40 ticks, lane half
    width 10 px plus half a car, the shove 1.75 px/tick along the lane,
    damage once a firing per car; Sweeper radius 18 px, 1.25 px/tick,
    period 600 (10 s), warning 60, damage once a crossing, a 2 px/tick
    shove plus its velocity, cars pushed out of its body (not into
    walls). Airborne cars pass over both; HEISENBUG does not hide a car
    from them (the machines are not looking); SUDO and respawn immunity
    stop the damage, not the shove.
58. **Hazard placement**: one per segment feature word, across the track
    at the segment's middle on the 45-degree snapped tangent, walls
    required on that segment; options per hazard in the `.track` word
    (`vent:right,phase=120`). Turrets and crust stay reserved.
59. **Service bays are lanes** (`bay:left` / `bay:right`, or the whole
    segment), 1 armor every 4 ticks (SPEC), nothing with combat off.
60. **AI hazard sense** reads the hazards' clocks exactly (no jitter);
    waiting for a vent costs about a second. KIDDIE ignores hazards
    ("read none of the docs"): about a third of all hazard hits in the
    soaks are KIDDIE's.
61. **GC sweep points** follow the race leader over the sector 2 line
    and the start line (SPEC's "half lap": the sectors split the lap in
    thirds, so the sweeps come at 2/3 and 3/3 of each lap); the first only
    marks, so six cars take six sweeps, the leader's third lap.
62. **GC tags**: any weapon hit by the marked car on a car still in the
    race passes the mark (shots, the LANCE, drops it laid, damaging
    pickups, ZERO-DAY), never rams or hazards, and only after the mark has
    been carried 45 ticks (no instant tag-back). A tagging hit that wrecks
    its victim collects the victim at once (the mark passed first).
63. **GC details**: a collected car keeps its drops and shots in play;
    there is no lap limit and no FINAL LAP; the AI's last-lap saves fire
    once three cars are left; crate rolls use the rank among the cars
    left (3rd of 3 rolls as 3rd, not 6th).
64. **Attract's KERNEL PANIC** is launched on the line 12 samples behind
    the leader at lap 2 sample 48, credited to the best-placed car behind
    it, rather than handed to a car as a pickup (from the back of a
    strung-out AI field the packet took 10 s or more and often fizzled on
    a wrecked leader). It froze the leader in 6 of 6 seeded runs.
65. **KERNEL PANIC packet fix** (an M2 bug): a target more than half a lap
    ahead read as already passed, and the packet parked on the line until
    the target lapped round to it.
66. **AI grid truce**: no AI rear drops for 240 ticks after GO. BOTNET's
    BIT ROT wrecked the human on the back row by tick 94 in every race.
    The human autopilot is still wrecked 2.7 to 5.3 times a race (M2's
    balance, left for Adrian's play test).
67. **Pits are drawn**: off-track tiles within `pit_band` tiles (4, or 11
    on Coolant Basin to fill its basins) of an open edge are void, so a
    drop reads as one; walls in the Runoff are rust-orange pipes so the
    edge reads against both the pale pan and the dark road.
68. **Laps**: every built-in track runs 3 (`Track.laps`, `World.laps`).
69. **Cathode Flats' open start straight** costs the AI field about 4
    falls a race (dangerous by design; wall it if the play test says so).

Taken during M3 (Track B, flow and mode presentation):

70. **Quick Race is three presses from the title** (Start, A on QUICK
    RACE, A on the racer), not SPEC 8.1's two: the PLAN puts PRESS START
    on the title and the menu after it. The menu remembers its row.
71. **The cart builds ReleaseSmall** (M3 status: ReleaseFast overflows
    the RAM window by about 9.6 KB once everything is merged). Hot loops
    are hand-tuned instead; the stress worst is 6.15 ms. Alternatives
    if ReleaseFast is wanted back: a 16 KB smaller stack reservation (a
    repo linker script), or the hot paths as a ReleaseFast leaf module.
72. **Main menu**: GARBAGE COLLECTION is 18 characters (144 px), so the
    cursor is a highlight bar, not a `>`; LINK is greyed and A on it
    flashes `NO LINK YET`; SOUND sits in both the main menu and pause.
73. **Track row panel** replaces the bio while the row is selected:
    name, league, `3 LAPS` / `MARK AND SWEEP`, the hazards, the outline;
    the bottom row reads `TRACK n/6`. The track row starts on the track
    last raced.
74. **SWEEP n** counts the next sweep from 1 (the last one, grey, once a
    survivor is left), with a 40 px bar of the leader's way to it (coral,
    red in its last fifth); the rank beside it is the place among the
    cars still running.
75. **MARKED**: the sprite drawn flat red one pixel out each way under
    the car (blinking light and dark red), `MARKED` over it (red and
    white; over the badge's own car it starts at x 62, clear of the speed),
    pickup tags move up over it; red blink on the minimap. The bar notes
    run 90 ticks; there is no bar note for being collected (it would hide
    the claw's lift).
76. **The claw**: 90 ticks (24 down, 10 closed, 56 lifting), 30x40 sprite
    px at the car's scale, a 2 px cable to the top edge; the car flashes
    white as it bites. A collected player watches the leader (at most a
    change every 2 s) with taunt pop-ups, speed, ammo, armor and the
    pickup caption hidden; Start still pauses (Quit leaves), there is no
    skip to the results.
77. **GC results**: `LAST PROCESS` / `RUNNING` on two rows (20
    characters do not fit), sweeps survived; the table's second line is
    `SURVIVOR`, `SWEEP n` (the sweep count when collected, kept
    render-side from the `collect` event) or `WRECKED` (collected for a
    wreck while marked).
78. **Feed lines**: `KIDDIE MARKED` (a sweep), `LEGACY TAGGED KIDDIE`
    (two rows when long), `GC: freed KIDDIE` (lowercase as SPEC writes
    it; the font has it), `VENT > X` and `SWEEPER > X` for hazard hits.
    Wreck, mark and collect lines are never overwritten by pickup, swap
    or hazard lines.
79. **Sweeper look**: the end view within 33.75 degrees of the camera's
    axis either way, else the side view mirrored by direction; 2 x size +
    8 world px wide (its hit radius plus brushes); beacon pixels at the
    sheet's lamp; the minimap shows it as an orange dot (blinking while it
    waits).
80. **Vents** have no sprite: the warning is blinking dashed lane edges
    and steam at the mouth, the blast flame for 40% of the lane then steam,
    puffs every 12 px reaching the end in 6 ticks.
81. **Attract camera**: a cut every 5 s to the next running car, and a cut
    (held 2.5 s) to a car a KERNEL PANIC actually freezes (not to the
    packet's target at launch: a packet can fizzle); the track rotates
    every demo, starting at Landfill Loop; `PRESS START` blinks on the bar
    row whenever the bar is free.
82. **Title**: the backdrop is Landfill Loop's floor turning under the
    Dumps horizon (the menu shares it); the portrait row's lit racer
    changes every 0.75 s.
83. **Pick frame**: the frame A starts a race shows the select once more
    while `track.select` unpacks the art and map (Outflow's start frame
    7.49 -> 5.66 ms); the race draws from the next frame.
84. **Under the CAPTCHA card** nothing of the world is drawn (the 4 px
    edges show bare floor for those frames).
85. **Stress scene** runs in GC mode with its own hazard specs written
    into the track's cache (a debug path, like its crates; the next race's
    select rebuilds it).
86. **Debug exports** added: `debug_start_gc`, `debug_start_attract`,
    `debug_gc_marked`, `debug_gc_sweeps`, `debug_gc_collected`,
    `debug_gc_survivor`, `debug_alive`, `debug_hazard_state`, `debug_me`;
    `debug_screen` 6 is the main menu, `debug_mode` 3 GARBAGE COLLECTION.
Taken during M4 (Track A, lockstep core; lettered L so the numbers of the
M3 tracks running in parallel stay free):

L1. **Hand-over to the AI**: `net.step` itself writes `Car.human =
    world.no_human` for the partner's car before the first solo tick
    (`handed_over` names the car). Only the surviving badge does it and
    the partner is gone, so no tick has to be agreed. A sim-side
    `sim.hand_to_ai(w, slot)` would be the tidier hook if the sim ever
    caches anything per human; today it reads `c.human` every tick.
L2. **API shape**: `step(&w)` calls `simulate` itself (so the hash, the
    pause and the hand-over cannot be forgotten) instead of the planned
    `ready_for(tick)` / `inputs_for(tick)`; `submit(now, byte)` picks the
    tick itself (`submit_local(tick, byte)` in the plan).
L3. **Crews are not in `world.Setup`**: the rules carry them (0..7, GO
    and SETUP), `world_setup()` cannot pass them on. M3 / Track B should
    add `Setup.crews` (sim.reset leaves cars off the grid) or main must
    deactivate the same cars on both badges right after `sim.reset`,
    before tick 0. The net tests race all six cars.
L4. **LINK GC on this base**: main 20e2172a has the M3.0 interface
    (`Mode.gc`, `World.gc`) but not the GC rules, so the GC-mode test runs
    to the lap finish and checks sync only. After the M3 merge it runs the
    real rules; if a GC race ends without `phase == .finished`, adjust the
    test's done condition (`done_finished`).
L5. **The race seed is not sent**: both badges derive it from the two
    link nonces and the race id, so every race of a session differs and
    GO stays 4 bytes. main's frame-counter seed is for single player.
L6. **Pause**: a Start press edge in either human's byte toggles it on
    that tick on both badges; paused ticks still run (the lockstep tick
    and the hashes go on, `simulate` does not), so `net.tick` is not
    `World.tick`. A finished race is never paused. main masks the pause
    menu's presses (submit only the Start bit while paused).
L7. **One tick per frame, no catch-up**: SPEC 13.1 left room for two
    `simulate` calls in a frame, but catching up drains the 2-tick input
    buffer (the badges then stall more); a stalled frame instead retries
    `step` in the waiting loop and drops that frame's buttons.
L8. **DESYNC message**: SPEC 7.2 only has the check byte, but the first
    badge to find a desync stops stepping and so stops sending the pieces
    that would show it to its partner; DESYNC tells it directly.
L9. **Packet details vs SPEC 7.2**: the tick field is 6 bits plus 2 salt
    bits (not the low 8 bits) and the check byte is a 7-bit piece of a
    32-bit field-by-field hash (4 pieces, 28 bits per epoch) rather than a
    CRC8 over the World bytes (padding bytes differ between badges, and a
    CRC8 is one piece). Both make every input packet exactly 8 wire bytes.
L10. **After the finish** both badges keep pumping and submitting until
    their results are dismissed (the partner may still need a late tick);
    `leave` then gives the partner `peer_left` / `.quit`, which main
    ignores once its World is finished.
L11. **Test wiring**: the host tests need `lib/link.zig` and
    `lib/link_virtual.zig` (which imports link.zig by path) in one module,
    so `build.zig` copies the three link files under a generated
    `link_host.zig` root; more than the planned one line, no lib/ change.
L12. **Racer clash**: the host's pick wins: `can_go` needs different
    racers, and the guest adopts the racers in GO whatever its own pick
    says by then. Rules carry track 0..15, crews 0..7, LINK RACE or LINK
    GC (attract is not linkable).
L13. **Nonce tie** (both HELLO nonces equal, 1 in 65536): `Net` restarts
    the link for new nonces rather than inventing a tie-break.
L14. **WAITING** is `step` failing for 500 ms (30 frames) in a row, so it
    needs main to call `step` every frame of the race.

Taken during M4 (Track B, link integration):

L15. **The link runs only on the LINK screens and in a link race**:
    start() makes the `Net` (the link does not touch the pins until its
    first poll); B from the LINK screen stops pumping, and the partner
    sees `SEARCHING...` 2 s later (its link times out). Single player
    never pumps it.
L16. **After the finish each badge runs the World alone** with zero
    inputs (`sim_test`: no input reaches a finished World, race or GC),
    without the lockstep or the hash checks; the `Net` stays `racing` and
    resends its last window until `leave`, so a partner one tick behind
    still gets it. Without this, a badge whose partner left for its
    results would wait for bytes that never come.
L17. **Link pause list**: RESUME, QUIT, SOUND (no RESTART: a restart
    would need both badges to agree; the rematch is in the lobby). Start
    resumes whatever the cursor; B and A on RESUME send a Start edge (a
    frame without Start first if it is still held). Two Starts on
    different ticks inside the input delay pause and resume again.
L18. **Lobby**: A on any row opens the racer select (the guest may pick
    before the rules arrive); the host's rules stay between races; the
    link select has no track row.
L19. **TAKEN** is the partner's racer once it is ready (hovering greys
    nothing); when both are ready on one racer the guest's mark drops
    (L12).
L20. **Pump points** (`render.band_hook`, `render.pump_at`): the floor
    every `tuning.link_pump_rows` (3) rows, the horizon every 16 columns,
    after the tick, after the floor lines, after gathering the sprites
    and between drawn sprites, between the HUD's passes, the CAPTCHA
    card's halves and grid rows, the glitch's bands, the ZERO-DAY flash's
    halves, after the HUD. `simulate` and a single sprite blit are not
    split (purity; the blit loops stay hot); section M4 status has the
    gaps.
L21. **No connected-peer bench**: badge-bench fakes the link with no
    cable, so the probe times the pump points with a searching link (one
    cheap poll) rather than a connected one (about 2 FIFO reads a pump
    and one packet in and out a frame, NET.md section 5). A peer fake in
    badge-bench would make the link race benchable.
L22. **Debug overlay** (`-Ddebug_overlay=true`) in a link race: `W` frames
    without a tick, `C` the link's CRC drops, `G` the worst gap between
    two pumps this race (us), under the lap counter (it overlaps the
    feed; a debug build only).
L23. **Notices**: `WAITING FOR PEER` / `CHECK THE CABLE` while `step` has
    waited 0.5 s; `PEER LEFT,` / `AI DRIVING` / the reason for 3 s (21
    characters do not fit 152 px, so SPEC's one line is two), not after
    the finish; `DESYNC: RACE ENDED` across the top of both results
    cards. The main menu's `NO LINK IN SIMULATOR` is two lines for the
    same reason.
L24. **CREWS off the grid**: the AI cars kept are the first `crews` of
    the seed's grid shuffle (so which racers sit out changes per race);
    the others stay at (0, 0), inactive, rank 0, out of every pool's
    reach and never drawn; the humans move up behind the cars kept.
L25. **CAPTCHA card** drawn as a 1 px outline and two halves of the face
    (the same pixels as the old full fill under the face; it made the
    stress mean 0.1 ms faster in single player too).
L26. **A guest that gets GO on the LINK screen** (not in the select)
    starts the race as well.
L27. **zig fmt** in this Zig rewrote `@intFromEnum` / `@enumFromInt` to
    `@backingInt` / `@fromBackingInt` in the cart's files (the first M4
    Track B commit carries that churn).

Taken during M5 (Circuit and polish):

L28. **No saves** (SPEC 17.6): the SNOUTY GCP lives in RAM for the
    session. B in the garage keeps it (CIRCUIT resumes it in the garage);
    switching the badge off loses it. A new Prix starts only after the
    end card (there is no "abandon"). A flash save would be a small blob
    (`career.Career` is plain data) if Adrian wants one.
L29. **Gun swaps** reset the gun to L1, and the old gun's levels are gone
    (swapping back costs 800 again). AIs never swap; their plans level
    their own guns.
L30. **Weapon levels** are cumulative (L3 keeps L2's ammo) and round up:
    front ammo 40/10/6/3 -> 50/13/8/4, damage PING 4 -> 5, BROADCAST 3 ->
    4, LANCE 25 -> 32, SPEAR PHISH 30 -> 38; rear L3 "+25% effect" is the
    LOGIC BOMB's 35 -> 44, the caltrop's 5 -> 7 and its slow 60 -> 75
    ticks, the MEMORY LEAK's grown radius 18 -> 23, the FIREWALL's half
    width 32 -> 40 (its 1 a tick stays, so ECC ignores it).
L31. **ECC** ignores any hit of 4 or less from anything (shots, walls,
    FIREWALL ticks, DDOS drones, small rams). An ignored hit is no hit: no
    kill credit window, no GC tag, no hit event.
L32. **TRACTION** adds 8/256 (0.03) to the chassis grip multiplier;
    **CLOCK** scales `top_q8` by 1.04 a level, so thrust and terminal
    speed both follow.
L33. **WATCHDOG** L2 and L3 (60 and 40 ticks) are shorter than the hulk's
    90: the hulk burns for the whole delay.
L34. **Cycle chips** are CIRCUIT-only (`Setup.chips`), 8 trails of 3 at
    samples 20 + 32k (+0, 2, 4), left / centre / right at 45% of the half
    width (moved to the line if that is not road); every taken chip comes
    back every 240 ticks. First built as "back on the leader's next lap",
    which left none for the back of the field. AIs take chips too.
L35. **AI budgets** are 75% of what the player has spent in the garage
    (`tuning.ai_follow_pct`; `ai_own_pct` 0). The first try also counted
    each AI's own winnings: race winners maxed their cars by the second
    league and the autopilot never left the Dumps in 18 races. So the
    field follows the player's spending a step behind it, deterministically.
L36. **League rules**: points 9/6/4/3/2/1, ties go to the better place
    in the league's last race; the league win (1500 CYCLES) is 1st in
    points; the top 3 open the next league; a failed league is replayed
    from race 1 with the points reset and the CYCLES and upgrades kept.
L37. **Balance** (SPEC 17.12, dangerous): base tuning is unchanged, as
    the M0-M4 replays must not move. The danger in the CIRCUIT comes from
    the AIs' upgrades: the autopilot (SNOUTY's AI) wrecks about 4.8 times a
    race in the circuit soak and is roughly a 4th-place driver against an
    equal field; it needs 12 races (two failed leagues) as SNOUTY or KIDDIE,
    24 as SYSADMIN, and never clears the Dumps in a MAINFRAME. A human
    using BURST and pickups well should do better; `ai_follow_pct` is the
    knob for Adrian's play test.
L38. **Garage flow**: the cursor starts on FRONT; Start races from any row
    (A on RACE too); B goes to the main menu. The AIs shop when the race
    starts (after the player). Pause RESTART in a CIRCUIT race is the same
    track with a new seed; QUIT goes back to the garage and books nothing.
L39. **CYCLES on screen**: the standings card has the race's breakdown
    (place, kills, chips, total, wallet) rather than the results table,
    whose six rows fill the screen; the results cards are unchanged.
L40. **Quick Race in two presses**: A on the title opens the Quick Race
    select (Start still opens the menu). No title hint was added, as
    `menu.zig`'s title belongs to the gc/menu-fix branch.
L41. **Main menu**: CIRCUIT is the third row (SPEC 8.1 order); the rows'
    pitch went from 13 to 11 px so five rows fit above the hint lines.
    gc/menu-fix's PICKUPS row will need the same room at the merge.
L42. **The Prix**: the new text uses the SNOUTY GCP name (Adrian's rename):
    `THE SNOUTY GCP` under CIRCUIT, `A ENTER THE PRIX`, `THE DUMPS PRIX`,
    `PRIX WON!`, `NEW PRIX UNLOCKED`, `SNOUTY GCP / PRIX COMPLETE` on the
    end card, whose line SPEC 8.2 writes in sentence case and the cart
    in capitals.
L43. **Garage reactions**: ten per racer (swap, level, plating, ECC,
    clock, traction, burst, watchdog, too poor, maxed), at most two rows
    of 19, up for 3 s, in the racer's livery colour; the portrait bobs
    while it talks.
L44. **Debug paths**: `debug_prix_skip` (wasm) books made-up results so
    the preview and check.sh reach the cards without six races; the
    `gc_cards` poke (badge-bench) makes the garage's Start book a 1st place
    instead of racing. Neither is reachable in play.
L45. **HUD**: up to four BURST bolts, packed 6 px apart past two so they
    stay left of the car; every floating tag (`TAGGED!`, `<honey>`, `+10`)
    is clamped to x 2..158.
L46. **Menu layout for 7 rows**: the title lockup stays at 2x; the hint
    panel is one line inside a bar with the footer, so menu-fix's second
    hint lines (MARK AND SWEEP, AND WHO GETS THEM, LINK RACE, LINK GC)
    are gone; rows stay 11 px apart. Alternatives were a 1x title or
    10 px rows with two hint lines.
L47. **Hint words**: CIRCUIT `2 PRIX, A GARAGE` (M5's `2 LEAGUES, A
    GARAGE` is 19 chars); the simulator's LINK `SIMULATOR: NO LINK`
    (one line, flashes coral on A).
L48. **Title hint**: `A  QUICK RACE` blinks in turn with PRESS START
    rather than on a line of its own (the band has no free line above the
    portraits).
L49. **PICKUPS screen number** is 11: M5's garage, standings and card
    keep 8, 9 and 10 (check.sh and RUNNING.md use them).
L50. **RESUME on both badges at once**: pause is a toggle, so if the
    partner's Start resumes and this badge's held Start was already kept
    for a later tick, the race pauses again (as at M4). The hold ends as
    soon as `paused` is off, so it sends no edge it has not already sent.
    Left as is.
L51. **Lobby pumping**: GC's lobby and link select loop only while
    `wants_pump()`; searching and a settled lobby pump once a frame (as
    lockstep's doc says is enough). Untested on two badges.

Taken during M6 (Track A, battle simulation):

L52. **The Sandbox's size**: 704 px square (88 tiles), so a car crosses it
    in about 4 s. The bit bucket is 128 px, about a fifth of the arena
    rather than SPEC 8.3's quarter. A 64-tick kicker jump from 2.2 px/tick
    clears that, and a quarter-arena pit could not be jumped by a
    MAINFRAME (2.7 px/tick top).
L53. **One-way ramps**: the arena's ramps are new attributes, `kicker` (3,
    64 ticks) and `jump` (11, 40 ticks), and they launch only a car moving
    the way the tile faces. Opposite kickers across a pit would otherwise
    relaunch every landing. Race ramps are unchanged.
L54. **Thrust in the air** stays as in the races: a car launched slowly
    speeds up in flight, so a crawl can sometimes clear a 5-tile corner
    gap. Only the bit bucket reliably swallows a slow car.
L55. **Battle damage** is 18% of the race's, with the fraction carried per
    car. STACK SMASH is its own 40. At full race damage, rounds at 3
    lives lasted about 30 s; at 18% they average about 2 minutes, still
    dangerous.
L56. **Eliminations** are `Car.kills`: the race's last-hit credit within
    180 ticks, so a car knocked into a pit scores for whoever hit it.
    About half the wrecks are falls, and most of those are credited.
L57. **SAFE MODE** runs with the race's respawn immunity (the car cannot
    fall either), and it also blocks rams, STACK SMASH and pickup use.
L58. **Out of lives**: the car leaves the round at once (`active = false`,
    so its hulk does not block), and the claw is the presentation's. The
    `out` event's b is the number of cars still in. An out car's standing
    is its `rank`, which can still move until the end.
L59. **Standings with INF lives**: eliminations, then fewer wrecks, then
    time survived. The kill leader's ties go to the better rank.
L60. **KERNEL PANIC with nobody scored** targets rank 1 of the standings,
    which is the tie order then.
L61. **ZERO-DAY's bottom two** are the two worst ranks of the cars that
    started (out ones included). CREWS changes how many that is.
L62. **"Ahead" ranges** in an arena are the race's progress ranges taken
    as straight-line px: BIT FLIP and DEADLOCK 400, RACE CONDITION 300.
    DEADLOCK's one-car wall chain anchors on the nearest waypoint.
L63. **Refill** gives every car in the round full ammo and BURST charges
    every 1200 ticks (wrecked cars included), on one clock for all.
L64. **Spawn pads**: two each on the south, west and east straights, none
    on the north straight (the Sweeper's path). Each faces a fence gap
    into a plaza.
L65. **The navigation field** is 3.6 KB, not SPEC's estimated 1 KB: 34
    nodes, two next-hop tables (with jumps, and ground only for a car too
    slow for the run-up) and 1 KB of cells. The hunter keeps one waypoint
    byte per car (`Car.nav`, bit 7 for a committed jump leg).
L66. **Hunter characters**: a target bias in px per crew (SYSADMIN 260 to
    the human, BOTNET 260 to the kill leader, KIDDIE 120 to the human),
    plus a pull toward hurt targets and the one already aimed at. Retreat
    shares are KIDDIE never, LEGACY 20%, ROOTKIT 40% and the rest 30%;
    a retreating car holds at the bay to 80%. With nobody to hunt, it goes
    to the nearest crate.
L67. **The arena's Sweeper** runs gate to gate along the north straight,
    with a 1200-tick period at 2 px/tick. KIDDIE ignores it, as on the
    tracks.
L68. **RAM**: the arena and the hunter cost about 15 KB of the window, so
    about 32 KB is free for Track B and M7.

Taken during M6 (Track B, BATTLE presentation and LINK BATTLE):

L80. **Battle flow**: menu BATTLE, then the racer select (SPEC 8.1: the
    select is the first screen of every mode; no track row, `A  TO THE
    ARENA`), then the setup screen (arena, LIVES, TIME, CREWS, FIGHT!)
    over the arena's own floor, then the round. The setup's cursor starts
    on FIGHT!, so A, A from the select fights with the last rules; A or
    Start on any row fights, B goes back to the select. Pause QUIT and the
    results go back to the select (then the setup). The options are kept
    for the session (`battle_ui.opts`; default 3 lives, 3 min, 5 AI).
L81. **The KILL -9 card** is drawn over the countdown's READY and 3 steps
    (100 ticks: `$ kill -9 -1` typing itself, KILL -9 at 2x, `no cleanup
    handler` / `no appeal`, the arena, the rules), then 2, 1, GO show as
    in a race. Render only, the same on both badges of a link battle: no
    single-player hold before the countdown, so nothing waits on it.
L82. **Battle HUD layout**: `ELIM n` replaces `LAP n/N` top left (cyan for
    the kill leader); the clock is centred (time left as M:SS rounded up,
    blinking coral in the last 10 s; with TIME NONE the time played in
    grey); the standing (1ST..6TH) sits right of the clock in grey (cyan
    when first); the lives are pips under ELIM on a dark plate (green,
    coral blinking on the last life; `INF` in grey), 5 px apart, 4 px past
    five lives so nine stay left of `FETCHING...`. The speed reading stays.
    The refill sweep is a 1 px line between the front and rear ammo rows,
    filling to the refill and flashing white as it lands.
L83. **Arena minimap**: 32x32 at the race minimap's place, over the
    arena's bounds (the tiles that are not `off`, squared), one kind a
    pixel from the unpacked map at the round's start: wall (a wall tile
    anywhere in the cell), pit (most of the cell open), bay, ramp, floor
    (checkerboard, the race shows through). Waiting crates 1 px yellow,
    the Sweeper 2x2 orange, every car in the round 2x2 in its livery (the
    followed one white on top), a wrecked car blinks, one in SAFE MODE
    flickers, the kill leader has a cyan ring.
L84. **Compat tests after the version bump**: `net.Game` is version 1 with
    five rules bytes; `net.GameV0` keeps the M5.1 game (one byte, version
    0) through the same `NetOf(L, G)` wrapper, and `net_compat_test`
    proves GameV0 is still M4's wire byte for byte and races an M4 badge
    in sync. New: the cart's v1 never races an M4 badge (M4 waits in its
    lobby), and a v0 (M5.1) and a v1 badge, either side, both cable kinds,
    clean and 1% loss, are both `wrong_version` and send no DATA packet
    for 10 s. The old test of a made-up `GameV1` against M4 now runs the
    real `net.Game`.
L85. **The five rules bytes**: mode (0 race, 1 gc, 2 battle), track (or
    arena), CREWS, LIVES, TIME, in every mode (a race carries the battle
    defaults, unused). `Rules.decode` maps bytes off the menus' rows to
    their defaults (an unknown mode is a race), so both badges always
    build a round they can run; `setup_of` wraps the track index into the
    table the mode uses.
L86. **LINK lobby**: the mode row cycles LINK RACE, LINK GC, LINK BATTLE.
    Into LINK BATTLE the track row becomes the arena (THE SANDBOX, index
    0) and LIVES and TIME rows appear (six rows 11 px apart, the title 4 px
    higher); back out, the race track the host had returns. CREWS stays
    4 / 2 / 0. The link select's panel reads the arena with `CREWS n` at
    the right and `3 LIVES, 3 MIN` under it. `debug_link_mode` puts the
    made-up (simulator) lobby on LINK BATTLE.
L87. **Feed and pops**: an `eliminated` line (`SNOUTY kill -9 KIDDIE`,
    two rows when wider than the screen) replaces the wreck line the same
    tick wrote; on a last life (`out`) the victim's name flashes red, and
    a last life nobody was credited with reads `KIDDIE REAPED`. A STACK
    SMASH is a minor feed line (`SNOUTY SMASHED KIDDIE`) with `SMASH!`
    rising over the victim. The bar pops are the badge's own car's:
    `STACK SMASH!` (it landed one), `STACK SMASHED` (it was under one),
    `CLEAN LANDING`; after the wreck note, before SAFE MODE. `SAFE MODE`
    blinks in the bar while `Car.safe` runs (the sprite blinks with the
    respawn immunity it already had). The round's end reads `TIME UP` or
    `LAST ONE STANDING` on every badge.
L88. **Out of lives**: the claw takes the hulk where it went out (the GC
    claw, `fx.claws`); `REAPED` sits where the armor bar was; once the
    claw is done the camera rides with the kill leader (the best-ranked
    car still in while nobody has scored), changing car at most every 2 s.
L89. **Results**: the winner card is the standings' first, titled `TOP
    KILLER`, or `LAST PROCESS UP` when the round ended by lives and it is
    the car left (eliminations rank first, so the top killer can be out
    of lives; then the card's end line names the car left, `LAST UP:
    BOTNET`, else `TIME UP`); its eliminations, lives (or wrecks with INF,
    or `OUT m:ss`), taunt, the player's own standing. The standings: the half portrait, name and
    `LIVES n` / `WRECKS n` / `OUT m:ss` (time survived), the eliminations
    under an `ELIM` heading at the right.
L90. **Debug paths**: the made-up BATTLE row (`debug_menu_battle`,
    `menu.preview_battle`) is gone with the real row, and check.sh's
    `menu7` run with it. `debug_start_battle`, `debug_battle_minutes`,
    `debug_battle_crews` and `debug_battle_kill` return a value so a
    preview's `--call-at` can use them. New: `debug_link_mode`,
    `debug_lobby_rules`, `debug_setup_row`, `debug_battle_arena`,
    `debug_battle_stress`, `debug_me_out`, `debug_safe`, `debug_stunt`.
L91. **check.sh outside Track B's block**: the BATTLE row moved the rows
    the `menu`, `pickups`, `link` and `circuit` previews press through
    (one more Down each, the header comment says so), and
    `tools/scripts/m5_circuit_race.json` got one more Down (A at 18): the
    circuit bench runs the same race as before. Track A owns those lines;
    the edit is the minimum the menu change forces.
L92. **net_test harness**: two M4-era fragilities that the v1 seeds hit
    are fixed in the scripted humans, not the netcode: a random Select tap
    on a frame that holds Start (the OS chord; `submit` clears both, so a
    held Start showed two edges) is dropped, and the desync test also
    flips a PRNG bit (a respawn can put a car back on its pad and erase a
    one-pixel change before the next check).
L93. **Arena stress** (`--poke gc_battle=2`, `debug_battle_stress`): the
    render stress scene keeps BATTLE rules in an arena (so its HUD is the
    one stressed) and adds a `kill -9` line every 90 frames (every other
    one a last life with its claw), a STACK SMASH and a CLEAN LANDING on
    SNOUTY in turn, a rival in SAFE MODE, the kill leader, moving lives,
    eliminations and refill, and the clock in its last 10 s.
