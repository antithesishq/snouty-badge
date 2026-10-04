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
  `(World, inputs)`: auto-throttle driving, walls, wrecks and the WATCHDOG
  respawn, contacts by mass, laps, rank. No cart API, no globals written.
- `ai.zig`: the centerline driver per racer `Crew`; also the autopilot.
- `racers.zig`: roster (names, cars, chassis, placeholder liveries).
- `tuning.zig`: every constant (driving, chassis multipliers, AI).
- `track.zig`: runtime `League`/`Track` structs of slices (the built-in
  ones embed `assets`; a pack in RAM can fill them later, SPEC 19), the map
  unpacker, `map_ram`.
- `render.zig` (row-loop floor, horizon, fog), `camera.zig`, `hills.zig`,
  `sprites.zig`, `hud.zig`, `font.zig`, `menu.zig`, `results.zig`,
  `sound.zig` + `engine.zig` (Zero's tones and drone), `input.zig` (edges,
  the Start+Select chord mask, `race_byte`).
- Host tests: `host_tests.zig` root, `sim_test.zig` (determinism, laps,
  completable, chassis), tests in `track.zig`, `fixed.zig`, `engine.zig`.

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
