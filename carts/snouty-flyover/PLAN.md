# Snouty Flyover: plan

`SPEC.md` is the design; this file is the contract for the milestone being
built, in enough detail that parallel tracks (Opus agents) can work without
talking to each other. Status lines are appended at the bottom of each
milestone block. Nothing is built yet; M0 starts when Adrian has read the
spec and the concept renders in `docs/concept/`.

## Concept pass (2026-09-30, done)

`tools/concept.py` is a numpy prototype of the renderer and the seven
segment generators (bus, heap, sort, tree, hash, stack, pipeline). It
exists to settle the look before any Zig: palette, structure sizes, camera
height, fog strength, the Iris sun, the lake reflection. Its README under
`docs/concept/` records the parameter values that M0 and M1 copy. It is
not a bit reference (float math); `tools/preview.mjs` frames are.

Status: done. Seven stills, `montage.png` and a 6 s `concept.gif`
(bus, heap with the GC sweep, bus, pipeline lake). The prototype found
four rules the Zig generators must copy (SPEC status, 2026-09-30):
pulse indices only on cells that are not tall block tops; 64 sort bars of
4 cells; a low tree seen from high; a 110-row lake. Hash density and the
grey GC wall are open for M2.

Review questions for the stills, in order of how much they change the
plan: does the machine-landscape idea read at 160x128 at all; which
districts read best; is the Iris sun right; is the palette too dark on
the simulator.

## M0 Scaffold

Goal: a flying camera over a generated noise-floor strip with the sky and
the Iris sun, at the 30 fps lock, registered in the root build, with a
bench number. No districts, no palette cycling, no text. This is the
renderer's core loop and the camera, done once and measured, so M1 builds
districts on known cost.

### Tracks

- **Track A: renderer** (`render.zig`, `palette.zig`, `fixed.zig`): the
  column march of SPEC 5.1, sky and sun of 5.2, the fog table of 5.3
  without the temporal dither (M1), cliff shading. Reads the map and
  camera through the interfaces below.
- **Track B: world and flight** (`world.zig`, `camera.zig`, `main.zig`,
  `build.zig`, root `build.zig` entry, `docs/RUNNING.md`, bench toml and
  scripts): map ring with the noise-floor generator only, the flight model
  of 5.5 (stick, roll shear, altitude spring), vsync lock, debug overlay,
  the `-Dflyover_*` knobs threaded from the root build.

Tracks do not edit each other's files. Both compile against the fixed
interfaces; I integrate, run the bench and tag `snouty-flyover/m0`.

### Fixed interfaces

```zig
// fixed.zig
pub const Q = 16;                       // Q16.16 everywhere
pub inline fn mul(a: i32, b: i32) i32;  // (a*b) >> 16 via i64
pub fn noise2(x: i32, y: i32, seed: u32) u8; // value noise 0..255, 2 octaves
pub const Rng = struct { s: u32, pub fn next(self: *Rng) u32 }; // xorshift32

// world.zig
pub const W = 256;                      // strip width, cells; x wraps
pub const DEPTH = 256;                  // ring rows; power of two
pub var height: [DEPTH][W]u8;           // .bss
pub var colour: [DEPTH][W]u8;           // .bss, palette index
pub fn advance_to(cam_row: i32) void;   // generate rows up to cam_row + z_far
pub fn generated_row(y: i32) bool;      // for the debug overlay only

// palette.zig
pub const rgb565: [256]u16;             // the literal table, layout SPEC 5.3
pub var fog: [8][256]u16;               // rebuilt by begin_frame
pub const water: [256]u16;              // M2, present but unused in M0
pub fn begin_frame(frame: u32) void;    // cycle pulses (M1), rebuild fog

// camera.zig
pub const Cam = struct {
    x: i32, y: i32, alt: i32,           // Q16 cells
    yaw: i32,                            // 1/1024 turn, 0 = +y
    horizon: i32,                        // screen row, 64 level
    roll: i32,                           // Q16 rows of shear across the screen
};
pub var cam: Cam;
pub fn update(controls: Controls, frame: u32) void;

// render.zig
pub const z_far: i32 = 256 << 16;       // knob
pub const lod_mul: i32 = 0x1_01EC;      // 1.0075 in Q16, knob
pub fn init() void;                     // inv_z, direction table, sun mask
pub fn draw(frame: u32) void;           // whole frame into cart.framebuffer
```

Map addressing: `height[y & (DEPTH-1)][x & (W-1)]`. The camera's `y`
increases forever; `advance_to` keeps `[cam_row - 8, cam_row + gen_ahead)`
generated, with `gen_ahead = DEPTH - 8`, and remembers the highest
generated row. (Amended during M0: the ring cannot hold `z_far + 8` rows,
so the march's far limit is `min(256, gen_ahead)` cells: 248 at depth 256,
120 at depth 128.)

M0 noise floor (Track B): `h = 8 + noise2(x, y, seed) / 32` (amplitude
8), colour index `0..7` by `h`, index `8` on grid lines (`x % 64 == 0 or
y % 64 == 0`), plus a test pattern so the renderer can be judged: a row
of eight blocks 16x16 cells, heights 16, 32, ..., 128, colours 96, 98,
..., 110, every 128 rows. The test blocks are removed in M1.

Camera constants (Track B): cruise 0.75 cells per frame, boost 1.9,
altitude 48 above the floor at start, spring 1/16 per frame toward
`ahead_max + 12`, roll ease 12 frames, max roll 20 rows of shear, yaw
cap 64 (1/16 turn), yaw rate 1 per frame per 4 rows of roll. Level
horizon row 64; pitch moves it by up to 24 rows.

Renderer constants (Track A): `shift` chosen so a cell of height 64 at
z = 64 cells subtends 32 rows (the view scale); sun 72 px at yaw 0
centred on the horizon; sky gradient per SPEC 5.2; fog levels by step:
level = `min(7, step / 32)` for the 8-level table; cliff shading with
`cliff_min` 6 rows and `cliff_dh` 12 cells.

### Knobs in the root build

`-Dflyover_fps=30|60` (vsync lock, default 30) and
`-Dflyover_depth=128|256` (ring depth, default 256). Both land in
`build_options` like the reflections variant option does; no other build
options for this cart in M0.

### Bench and scripts

`badge-bench/carts/snouty-flyover.toml`: `budget_ms = 22.0`, `frames =
600`. `tools/scripts/m0_fly.json`: 600 frames, stick right for frames
120-200, left 300-380, A held 450-540. Bench command from the root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-flyover.elf --script carts/snouty-flyover/tools/scripts/m0_fly.json --frames 600 --every 60 --symbols
```

### Done criteria for M0

- `zig build -Dcart=snouty-flyover` produces uf2, elf and wasm; `zig build
  check-float` passes; ELF `.text + .data` under 40 KB, `.bss` under 140 KB.
- `../../tools/preview.mjs` frames show the floor, grid, test blocks with
  darker sides, the sun, and the horizon shearing when banking; a 600-frame
  GIF in `docs/preview_m0.gif`.
- Calibrated bench worst frame recorded in the status line; if above 11 ms
  the 60 fps question is closed at 30.
- `docs/RUNNING.md` written in the same shape as the reflections one.

### M0 status

- 2026-09-30: started. Scaffold commit 14c9145 (root build entry, knobs,
  main.zig, stub modules with the fixed interfaces; builds, check-float
  passes). Tracks A and B running as Opus agents in this worktree.
- 2026-09-30: done, tag `snouty-flyover/m0`. Calibrated badge-bench over
  the 600-frame `m0_fly.json` run: worst 7.01 ms (frame 454, boosting),
  mean 6.35, p95 6.83; 32% of the 22 ms budget, so the 60 fps lock stays
  possible (decide in M2 with districts and the fog dither in, SPEC 10).
  Hot: the inlined march 91%, fog rebuild 4%, sky memcpy 3%, world 2%.
  Sizes: `.text` 14,492 B, `.data` 44 B, `.bss` 141,672 B (map 128 KB, fog
  4 KB, renderer tables; little `.bss` headroom left under the 140 KB gate,
  `-Dflyover_depth=128` halves the map if M1 needs room). check-float
  passes; `debug_world_check` is 0 across the run. Deviations from this
  plan, both kept: the ring window is `[cam_row - 8, cam_row + DEPTH - 8)`
  and the march far limit is `min(256, gen_ahead)` = 248 cells; the fog
  level per step follows the concept's curve (level 0 to 60 cells, then
  f^1.4 to level 7 at z_far) instead of `step / 32`, which topped out at
  level 4. Camera additions: pitch sets a cruise altitude that the terrain
  clearance only raises, and the heading returns to straight ahead when
  the stick is centred. GIF: `docs/preview_m0.gif`. The M0 test blocks use
  bus/sort palette indices; M1 removes them.

## M1 World engine (outline, planned after M0's bench number)

Tracks: A palette cycling + temporal fog dither + text; B segment
sequencer + Bus + Heap (with the GC sweep); C Sort district + autopilot
track + placeholder Snouty. Attract script `tools/scripts/attract.json`.
Gate: Bus-Heap-Bus-Sort loop under 22 ms worst, GIF review.
