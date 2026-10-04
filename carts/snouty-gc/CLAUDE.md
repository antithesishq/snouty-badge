# Snouty GC (cart notes)

Mode 7 combat racer (subtitle GARBAGE COLLECTION) forked by copy from the
Snouty Zero engine. `SPEC.md` is the design, `PLAN.md` the milestone
contract and status; read both before changing anything. The repository
rules are in the root `CLAUDE.md`. Never edit `carts/snouty-zero/` from
here: every forked file names its Zero source and commit on its first line.

## Modules (`cart/src/`)

- `main.zig`: `start`, `update`, the state machine, the `World` instance,
  the render-side `follow` (which car this badge draws and hears), wasm
  shims, debug exports.
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
- `ai.zig`: the centerline driver per racer `Crew` with its combat
  character (aim, reaction, drops; `update_aim` is called by `sim`) and
  pickup policy (`want_use`, CAPTCHA solve ticks); also the autopilot.
- `racers.zig`: roster (names, cars, chassis, placeholder liveries).
- `tuning.zig`: every constant (driving, chassis multipliers, AI).
- `track.zig`: runtime `League`/`Track` structs of slices (the built-in
  ones embed `assets`; a pack in RAM can fill them later, SPEC 19), the map
  unpacker, `map_ram`, and the crate spawns `crate_spots` (from the
  centerline samples flagged `flag_crates`, the `.track` word `crates`).
- `sprites.zig`: the runtime `Sheet` (every 4-bit art sheet, with blue
  and gold car tints), one blit with separate width and height (flat
  decals), the race's depth list (cars, projectiles, drops, crates,
  drones, ducks, particles; 64 drawn, cars never culled), the floor lines
  (DEADLOCK chains, duck tethers, SPAGHETTI strands) and the car states.
- `fx.zig`: render-side effects and HUD notices from the World's event
  ring (own cursor, never writes): explosions, sparks, smoke, muzzle
  flashes, lance beams, kill feed, taunt pop-up, ACK, wreck note, shake;
  M2: crate pops, `<honey>` tags, the duck pop, BIT FLIP's ray, the
  ZERO-DAY dart and flash, the RACE CONDITION glitch, pickup feed lines.
- `select.zig` (the racer select, SPEC 8.1), `roster_text.zig` (bios,
  taunts, wrecked lines, weapon and pickup names, HUD liveries, stat
  bars), `stress.zig` (the render stress scene: `gc_stress` /
  `debug_stress`; `force_effect` behind the wasm `debug_effect`).
- `render.zig` (row-loop floor, horizon, fog, BIT FLIP's row jitter),
  `camera.zig` (follow, look back, culling projection), `hills.zig`,
  `hud.zig` (also the pickup box and the gags: blue screen, CAPTCHA,
  BIT FLIP, DDOS), `font.zig`, `menu.zig`, `results.zig`,
  `sound.zig` + `engine.zig` (Zero's tones and drone), `input.zig` (edges,
  the Start+Select chord mask, `race_byte`).
- Host tests: `host_tests.zig` root, `sim_test.zig` (determinism, laps,
  completable with combat off, chassis), `weapons_test.zig` (a scenario
  per weapon on a frozen arena, ramming, wrecks, hulks, kill credit, AI
  combat, the 20-race combat soak), `pickups_test.zig` (roll odds,
  crates, a scenario per pickup, AI policies, the pickup soak), tests in
  `track.zig`, `fixed.zig`, `engine.zig`.

## Data

`assets/gen/*.bin` come from `tools/build_tracks.py` (+ `tools/leagues.py`)
and `cart/src/tracks/*.track`, committed; they reach the cart through the
`assets` module `build.zig` generates (one `@embedFile` per file, no
comptime decoding: the Mac OOM rule). Tilesets are 128 tiles. Engine
sprites: `ASSETS_ENGINE.md`. The art track owns `tools/draw_art.py`,
`assets/gen/art/` and `ASSETS.md`.

## Gates

- `tools/check.sh`: build, `zig build test` (falls back to `zig build
  test-gc` when other carts' runners fail, and says so), check-float,
  generator determinism, headless preview runs, badge-bench plain and
  `--lcd` (worst frame under 8 ms).
- The RAM cart is the shipped artifact; record bench mean/worst and
  `size -A` in `PLAN.md` per milestone.
- Determinism is a gate from M0 (M4 is lockstep netcode): nothing in
  `simulate` may read the clock, `cart.rand`, floats or render state.
- Never bind the joystick click; react to neither Start nor Select while
  both are held. No neopixel code; sound off at boot with a toggle.
