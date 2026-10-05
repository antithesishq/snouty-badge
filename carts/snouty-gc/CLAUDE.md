# Snouty GC (cart notes)

Mode 7 combat racer (subtitle GARBAGE COLLECTION) forked by copy from the
Snouty Zero engine. `SPEC.md` is the design, `PLAN.md` the milestone
contract and status; read both before changing anything. The repository
rules are in the root `CLAUDE.md`. Never edit `carts/snouty-zero/` from
here: every forked file names its Zero source and commit on its first line.

## Modules (`cart/src/`)

- `main.zig`: `start`, `update`, the state machine (splash, title, main
  menu, select, race, pause, results), the `World` instance, the
  render-side `follow` (which car this badge draws and hears: the
  player's `me`, or in the attract demo the camera's cuts, or the leader
  once GARBAGE COLLECTION has collected the player), wasm shims, debug
  exports.
- `world.zig`: the plain `World` (6 `Car`s, clock, PRNG, countdown, track
  index; no pointers), `Input` (the race byte: bit 0 up, 1 down, 2 left,
  3 right, 4 A, 5 B, 6 Start, 7 Select), `Setup` (track, seed, the two
  humans' racers).
- `sim.zig`: `reset(w, setup)` and `simulate(w, inputs: [2]u8)`, pure in
  `(World, inputs)`: auto-throttle driving, walls, armor and `damage`,
  wrecks with kill credit, hulks and the WATCHDOG respawn, contacts and
  ramming by mass, laps (and the ammo refill), rank. No cart API, no
  globals written.
- `weapons.zig`: the 4 front and 4 rear weapons (SPEC 6.1, 6.2), the
  projectile and drop pools, hits, the SPEAR PHISH lock, the event ring
  writer `emit`; part of `simulate`.
- `pickups.zig` (M2): RMA crates, the roulette and rank-weighted rolls,
  the 15 pickups (SPEC 6.3) and their status effects, the KERNEL PANIC
  packet, DDOS drones, FORK BOMB forking; part of `simulate`, hooked in
  by `sim` and `weapons`. Render helpers `duck_pos`, `chain_anchor`.
- `hazards.zig` (M3): the generic track hazards (a timed blast = the
  Runoff's exhaust vents, a crossing mover = the Dumps' Sweeper; turret
  and crust reserved) driven by `track.hazard_specs`, and the service
  bays; part of `simulate`. `hazards.at(spec, tick)` is the pure cycle.
- `gc_mode.zig` (M3): GARBAGE COLLECTION's mark and sweep (sweeps as the
  leader passes sector 2 and the line, tags on weapon hits, collections,
  the survivor) and the attract demo's scripted KERNEL PANIC.
- `ai.zig`: the centerline driver per racer `Crew` with its combat
  character (aim, reaction, drops; `update_aim` is called by `sim`) and
  pickup policy (`want_use`, CAPTCHA solve ticks), the hazard sense
  (`dodge_hazards`: wait for a firing vent, pass behind the Sweeper);
  also the autopilot.
- `racers.zig`: roster (names, cars, chassis, placeholder liveries).
- `tuning.zig`: every constant (driving, chassis multipliers, AI).
- `track.zig`: runtime `League`/`Track` structs of slices (the built-in
  ones embed `gen/tracks/`; a pack in RAM can fill them later, SPEC 19),
  the track table (`tracks`, `leagues`), the map unpacker, `map_ram`, the
  crate spawns `crate_spots` (from the centerline samples flagged
  `flag_crates`, the `.track` word `crates`) and the hazard specs
  `hazard_specs` (from the track's `feat` records).
- `sprites.zig`: the runtime `Sheet` (every 4-bit art sheet, with blue
  and gold car tints), one blit with separate width and height (flat
  decals), the race's depth list (cars, projectiles, drops, crates,
  drones, ducks, particles; 64 drawn, cars never culled), the floor lines
  (DEADLOCK chains, duck tethers, SPAGHETTI strands) and the car states;
  M3: the MARKED outline, the GC claw, the Sweeper and the vents' blasts
  (and their warning lanes among the floor lines).
- `fx.zig`: render-side effects and HUD notices from the World's event
  ring (own cursor, never writes): explosions, sparks, smoke, muzzle
  flashes, lance beams, kill feed, taunt pop-up, ACK, wreck note, shake;
  M2: crate pops, `<honey>` tags, the duck pop, BIT FLIP's ray, the
  ZERO-DAY dart and flash, the RACE CONDITION glitch, pickup feed lines;
  M3: GC feed lines and bar notes, `TAGGED!`, the claws (`claws`, kept
  here because the World takes a collected car out), each collected car's
  sweep for the results, the vents' blast clocks and warning steam,
  hazard hits, the KERNEL PANIC victim the attract camera cuts to.
- `select.zig` (the racer select, SPEC 8.1; M3 the track row's panel),
  `menu.zig` (splash, title, main menu, the pause list), `roster_text.zig` (bios,
  taunts, wrecked lines, weapon and pickup names, HUD liveries, stat
  bars), `stress.zig` (the render stress scene: `gc_stress` /
  `debug_stress`; `force_effect` behind the wasm `debug_effect`).
- `render.zig` (row-loop floor, horizon, fog, BIT FLIP's row jitter),
  `camera.zig` (follow, look back, culling projection), `hills.zig`,
  `hud.zig` (also the pickup box and the gags: blue screen, CAPTCHA,
  BIT FLIP, DDOS; M3 `SWEEP n`, MARKED tags, the spectator view),
  `font.zig`, `results.zig` (M3 the survivor card and GC table),
  `sound.zig` + `engine.zig` (Zero's tones and drone), `input.zig` (edges,
  the Start+Select chord mask, `race_byte`).
- Host tests: `host_tests.zig` root, `sim_test.zig` (determinism, laps,
  completable with combat off, chassis), `weapons_test.zig` (a scenario
  per weapon on a frozen arena, ramming, wrecks, hulks, kill credit, AI
  combat, the 20-race combat soak), `pickups_test.zig` (roll odds,
  crates, a scenario per pickup, AI policies, the pickup soak),
  `content_test.zig` (M3: hazards, bays, the AI's hazard sense, every
  track's soak, GARBAGE COLLECTION and its soak, attract), tests in
  `track.zig`, `hazards.zig`, `gc_mode.zig`, `fixed.zig`, `engine.zig`.

## Data

The league and track data (`cart/src/gen/tracks/*.bin`) come from
`tools/build_tracks.py` (+ `tools/leagues.py`) and `cart/src/tracks/*.track`,
committed; since M3 `track.zig` embeds them with `@embedFile` (plain
slices, no comptime decoding: the Mac OOM rule), so a new track needs no
`build.zig` entry. `assets/gen/*.bin` (the font, and until build.zig drops
them the M0 copies of the Dumps and Landfill Loop files) reach the cart
through the `assets` module `build.zig` generates. Tilesets are 128 tiles. Engine
sprites: `ASSETS_ENGINE.md`. The art track owns `tools/draw_art.py`,
`assets/gen/art/` and `ASSETS.md` (M3: `tools/art/hazards.py`, the
Sweeper sheet `hazards.png`).

## Gates

- `tools/check.sh`: build, `zig build test` (falls back to `zig build
  test-gc` when other carts' runners fail, and says so), check-float,
  generator determinism, headless preview runs, badge-bench plain and
  `--lcd` (worst frame under 8 ms).
- The RAM cart is the shipped artifact; record bench mean/worst and
  `size -A` in `PLAN.md` per milestone. Since M3 it builds
  **ReleaseSmall** (`build.zig`): ReleaseFast no longer fits the 274 KB
  window (PLAN M3 status). The hot loops are written so ReleaseSmall
  keeps them fast (`inline for`, `inline fn`, a loop specialised per
  case in `sprites.blit_rect`, `hud.fill_rect` instead of the API's
  `rect` for fills); keep new per-pixel code the same way and bench it.
- Determinism is a gate from M0 (M4 is lockstep netcode): nothing in
  `simulate` may read the clock, `cart.rand`, floats or render state.
- Never bind the joystick click; react to neither Start nor Select while
  both are held. No neopixel code; sound off at boot with a toggle.
