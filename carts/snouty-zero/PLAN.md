# Snouty Zero: plan

`SPEC.md` is the design; this file is the contract for the milestone being
built, in enough detail that parallel tracks (Opus agents) can work without
talking to each other. Status lines are appended at the bottom of each
milestone block. Decisions taken without Adrian are listed under "Deferred
questions" at the end so he can override them in one pass.

## File layout

```
carts/snouty-zero/
  build.zig              pub fn add: RAM + XIP cart, host tests, check-float
  cart/src/main.zig      start/update, state machine, wasm shims, debug exports
  cart/src/fixed.zig     Q16.16 helpers, sin/cos from gen/sin.zig, xorshift Rng
  cart/src/gen/sin.zig   committed 256-entry sine table (tools/gen_sin.py)
  cart/src/tuning.zig    every gameplay and camera constant (SPEC 5)
  cart/src/input.zig     controls with edge detection
  cart/src/camera.zig    camera state and follow/free-fly logic
  cart/src/render.zig    floor tables, column loop, horizon strip, fog banks
  cart/src/track.zig     embedded league art + track data accessors (@embedFile)
  cart/src/tracks/*.track  spline track sources (SPEC 7)
  cart/src/host_tests.zig  root for `zig build test`
  assets/gen/*.bin       generated binary data, committed (formats below)
  tools/build_tracks.py  tileset, horizon strips, map/attr/center rasterizer
  tools/gen_sin.py       writes cart/src/gen/sin.zig
  tools/scripts/*.json   preview.mjs / badge-bench input scripts
  docs/RUNNING.md, docs/preview_m*.gif, docs/<track>_preview.png
```

World: 1024x1024 world pixels (one pixel = one floor texel), wrapping; the
map is 128x128 tiles of 8x8, `map[y][x]`. Angles are `u16` turns (65536 =
one revolution), heading 0 points +x, 16384 points +y (down on the map
image). Positions and velocities are Q16.16.

## Generated data formats (assets/gen/, little-endian, read at run time)

All files are raw bytes read with `@embedFile`; no comptime decoding (the
Mac OOM rule). `<league>` is `edge`, `spine`, `core`; `<track>` is the
`.track` file's stem.

| File | Bytes | Layout |
|---|---|---|
| `<league>_tiles.bin` | 16384 | 256 tiles x 64 bytes, each tile row-major 8x8 palette indices |
| `<league>_pal.bin` | 512 | 256 x u16 RGB565; entry 0 is the league fog/horizon colour and no tile uses index 0 |
| `<league>_horizon.bin` | 12352 | front layer 512x32 4 bpp (8192 bytes, row-major, 2 px per byte, low nibble = left pixel, index 0 transparent); back layer 256x32 4 bpp (4096 bytes, opaque); front palette 16 x u16; back palette 16 x u16 |
| `<track>_map.bin` | 16384 | 128x128 tile indices, `map[y][x]` (RLE comes with M3's six tracks) |
| `<track>_attr.bin` | 256 | attribute per tile index, see below |
| `<track>_center.bin` | 2048 | 256 centerline samples x 8 bytes: x u16, y u16, tangent u16 (turn), half width u8, flags u8 |

Attributes (`attr.bin` values): 0 off-track (a fall when the machine is
wholly on it), 1 surface, 2 rail (solid), 3 overclock pad, 4 throttled,
5 cold aisle, 6 hot spot, 7 hop, 8 start line, 9 sector 1, 10 sector 2.
Values 3..10 are drivable surface. Edge tiles of an `open` segment are
attribute 1 (painted as a glowing edge); beyond them is 0. Centerline
`flags`: bit 0 rail on this segment, bit 1 open edge, bit 2 pad, bit 3
throttled, bit 4 cold, bit 5 hot, bit 6 hop. Sample 0 is the start line
and the samples run in driving order (increasing index = forward).

Edge tileset index map (M0; the generator owns the exact numbers and
writes them as comments in `docs/<league>_tiles.txt`): 1..15 background
pattern (rack-top grid, fans, solar panels, cooling-tower tops, plumes),
16..31 track surface variants (dark aisle floor with seams and faint lane
dots), 32..47 edge pieces (auto-tiled from the 4-neighbour surface mask,
glowing edge strip for open segments), 48..63 rail pieces (same
auto-tiling, metal rail with red/white hazard), 64..95 feature tiles
(pad chevrons, throttled hatching, cold-aisle blue stripes, hot spot,
hop plate, start line checker, sector marks), 96..255 free.

## M0 Floor

Goal: the Mode 7 floor over the generated Cold Aisle map and the Edge
tileset, horizon strip with two-layer parallax, fog banks, a free-flying
camera on the d-pad, registered in the root build with a bench number.
No physics, no sprites, no HUD text beyond the debug overlay. Section 18
of the SPEC is answered here.

### Tracks

- **Track A: generator** (`tools/build_tracks.py`, `tools/gen_sin.py`,
  `cart/src/tracks/cold_aisle.track`, `assets/gen/*`, `docs/cold_aisle_preview.png`,
  `docs/edge_tiles.txt`): the tile vocabulary painter for the Edge league,
  the two horizon layers, the Catmull-Rom centerline rasterizer with
  auto-tiled edges and rails, the attribute and centerline tables, a 1:1
  preview PNG. Pillow + numpy, no other dependencies. `python3
  tools/build_tracks.py` (from the cart directory) rebuilds everything
  under `assets/gen/` from every `.track` file and must be deterministic
  (seeded per track, byte-identical reruns).
- **Track B: cart** (everything else): root build entry, `build.zig`,
  the modules above, the column floor loop (and the row-loop variant
  behind a comptime switch for the section 18 measurement), horizon and
  fog, free camera, debug exports, `docs/RUNNING.md`, bench toml and the
  `m0_fly.json` script.

### Camera and floor constants (tuning.zig, M0 values)

`horizon_y = 32` (floor rows 33..127, 95 rows), `cam_height = 64` world px,
`focal = 128` (half FOV = atan(80/128), about 32 degrees). Row `y`: `dy = y -
horizon_y`, `z = cam_height * focal / dy` world px ahead, lateral scale
`z / focal = cam_height / dy` world px per screen px. Row start `cam +
fwd * z - right * 80 * scale`, per-pixel step `right * scale`. Fog bank
per row by `z`: bank 3 for `z >= 640`, 2 for `z >= 320`, 1 for `z >= 160`,
else 0; bank k blends the palette (k/4) toward palette entry 0. The free
camera: Left/Right yaw 256 turn units per tick, A forward 3 px/tick, B
back, Up/Down change `cam_height` by 1 (clamped 24..160, so the scale
question can be judged live).

### Bench and scripts

`badge-bench/carts/snouty-zero.toml`: `budget_ms = 16.7`, `frames = 600`,
`m0_fly.json`: A held 0-599, Right 100-220, Left 350-470. From the root:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-zero.elf --script carts/snouty-zero/tools/scripts/m0_fly.json --frames 600 --every 60 --symbols
```

### Done criteria

- `zig build -Dcart=snouty-zero` makes uf2, elf, wasm; `zig build
  check-float` and `zig build test` pass.
- preview frames show the track, rails, start line, background pattern,
  horizon parallax and fog; `docs/preview_m0.gif`.
- Calibrated bench worst frame recorded below, for the column loop and
  the row loop (section 18, first two bullets); the faster one stays.
- Section 18 facts answered in the status.

### M0 status

- 2026-10-01: started. Track A (Opus agent): `tools/build_tracks.py` +
  `tools/leagues.py` (league table: palette, tile, background and horizon
  painters), Cold Aisle 14 control points, lap 4135 px, 48 palette
  entries; tile index map in `docs/edge_tiles.txt` (corner pieces 96..103
  added for diagonal contacts). Track B: the modules above.
- 2026-10-02: DONE. `zig build`, `zig build test`, `check-float` pass; ELF
  `.text` 52.9 KB, `.bss` 5.7 KB. Calibrated bench, `m0_fly.json`, 600
  frames: **row loop mean 2.32 ms, worst 2.56 ms** (frame 0); column loop
  mean 2.76 ms, worst 3.00 ms. Row loop is the default (`-Dzero_floor`).
  `docs/preview_m0.gif`. Section 18 answers:
  1. Column vs row: the row loop (incremental adds, strided halfword
     stores) is 16% cheaper in the model than the column loop (sequential
     stores, two multiplies per pixel). The model prices every halfword
     store alike (framebuffer halfword access is unmeasured in
     calibration), so a hardware overlay check could still flip this;
     both loops stay behind the option.
  2. Per-pixel cost: about 17 cycles per floor pixel (row) and 20
     (column), floor + horizon together 347 K / 414 K cycles per frame.
     No tile pointer cache tried; M4 if the budget ever matters.
  3. XIP tile fetch: not measured in M0 (the XIP build is an M4 item).
  4. `d(y)` in 16.16 is enough: z at the row under the horizon is 8192
     world px exactly (height 64), and the per-pixel step at the nearest
     row is 0.67 world px, far above the 1/65536 resolution. No 8.24 table.
  5. Sprite scale against the floor: M1, when the first sprite exists.
  Visible fog banding at the four bank boundaries (SPEC 6.2 accepted
  this); eight banks are a M4 polish item if it bothers Adrian.

## M1 Drive

Goal: a 3-lap solo race on Cold Aisle is drivable in the simulator: the
hover physics of SPEC 5.1, tile attributes (rails bounce, off-track is a
fall that for M1 just resets the machine to the nearest centerline sample),
lap counting with sectors, the Anteater sprite with Snouty in the cockpit,
countdown, basic HUD (lap, clock, speed). Rivals, thermal, Overclock,
pads and the rest are M2; rewind is M3.

### Tracks

- **Track A: sprites** (`tools/prepare_assets.py`, `assets/gen/*.png`,
  `cart/src/sprites.zig`, `ASSETS.md`): the code-drawn Anteater at 40x24
  (straight, lean left, lean right, hop) with a 12x8 Snouty head in the
  cockpit, the 32x6 shadow, the 32x16 rival machine at 5 yaws (M2 uses
  it, drawn now so the palette is settled), 16x16 spark and flame
  effects; the PNGs go through the per-cart `convert_gfx` into a `gfx`
  module (snouty-bugs pattern, 4 bpp, index 0 transparent); the scaled
  blit of SPEC 6.3 (nearest neighbour, 8.8 step, clipped to the floor
  region, per-sprite palette).
- **Track B: simulation** (`world.zig`, `sim.zig`, `tuning.zig`
  additions, `camera.zig` follow mode, `hud.zig`, `main.zig` state
  machine Countdown -> Race -> Results stub, `tools/scripts/m1_*.json`,
  host tests): the `World` struct (plain data, no pointers), `simulate`
  one tick, attributes at the four footprint corners, rail response,
  lap/sector logic, progress along the centerline, the countdown and HUD
  text.

### Fixed interfaces

```zig
// world.zig
pub const Machine = struct {
    x: i32, y: i32,            // Q16.16 world, wrapping
    vx: i32, vy: i32,          // Q16.16 px/tick
    heading: u16,              // turn
    lap: u8, sector: u2,       // sector bits seen since the start line
    progress: u16,             // nearest centerline sample
    thermal: u16,              // 0..1000 (M2)
    hop: u8, overclock: u8, immune: u8, shake: u8,
};
pub const World = struct {
    machines: [11]Machine,     // 0 = player
    tick: u32,                 // race clock in ticks from DEPLOY
    rng: u32,
    phase: enum(u8) { countdown, racing, finished },
    countdown: u16,
    msg: u8, msg_ticks: u8,
};
pub var w: World;
// sim.zig
pub fn reset(track: *const track.Track) void;
pub fn simulate(controls: cart.Controls) void;  // one tick, deterministic
// sprites.zig
pub fn blit_scaled(comptime sheet: type, cell: u32, cx: i32, feet_y: i32, scale_q8: u32, pal: u8) void;
// camera.zig
pub fn follow(m: *const world.Machine) void;    // yaw lag 1/8, behind cam_behind
```

### Done criteria

- `zig build`, `zig build test` (the lap test: a scripted drive around
  the centerline counts 3 laps with sectors; `simulate` twice from one
  state is byte-identical), `check-float`.
- preview: `m1_lap.json` drives one lap by the autopilot-free script or
  the Anteater sprite sits on the floor at the right scale for every
  camera height in 32..96 (SPEC 18, last bullet).
- bench worst frame recorded; `docs/preview_m1.gif`.

## Deferred questions for Adrian

1. (M0) Camera height 64 / focal 128: the near floor shows a 16 px seam
   grid as squares about 24 px wide; F-Zero sits a little higher. The
   knobs are `tuning.cam_height` and `tuning.focal`; Up/Down in the M0
   free camera change the height live for judging it.
2. (M0) Four fog banks band visibly on long straights; eight would cost 1
   KB of palettes and nothing per pixel.
