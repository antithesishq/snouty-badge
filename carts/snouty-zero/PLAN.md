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
| `<track>_map.bin` | 3.0 to 4.7 KB (M5, packed) | an LZ stream that unpacks to the 128x128 tile indices `map[y][x]`: op byte 0x00..0x7F = literal run of op+1 bytes; 0x80..0xFF = back-reference of (op&0x7F)+3 bytes at distance d+1 (one byte d < 0x80) or ((d&0x7F)<<8 | d2)+1 (two bytes), copies may overlap; `track.select` unpacks into `track.map_ram` at race start |
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

### M1 status

- 2026-10-02: DONE. Track A (Opus agent): `tools/prepare_assets.py` draws
  the Anteater (ray-cast mini model, 4 frames), the rival machine at 5
  yaws, shadow, fx and the Snouty head; `ASSETS.md`. Track B: `world.zig`,
  `sim.zig` (physics, rails by tile-crossing normal, fall and meltdown
  hit-stop with a centerline reset, laps with sectors), `ai.zig` (the
  centerline autopilot with a curvature speed target; the rivals' base),
  `camera.zig` follow + projection, `sprites.zig` scaled blit, `hud.zig`.
  Host tests: determinism, terminal speed, laps need both sectors, and
  the autopilot drives 3 laps of Cold Aisle without a crash (best lap
  1837 ticks, 30.6 s; the AI is conservative, a player is faster).
  Fixes on the way: `speed()` was off by 256; Cold Aisle's bottom-right
  kinks had a 17 px radius and were softened in the `.track` file (now 33
  px at the sharpest control points); `steer_rate` raised from 190 to
  300 so those corners are drivable at a third of top speed. Bench
  (`m1_drive.json`, 1200 frames): **mean 3.05 ms, worst 3.51 ms** (21%
  of budget). ELF `.text` 81.3 KB (sprites + sim). `check-float` passes.
  `--call debug_set_autopilot:1` lets the preview drive itself (the M2
  attract mode uses the same path). SPEC 18 last bullet: the Anteater's
  shadow sits on the floor row of its footprint at every camera height
  tried (48..96), scale from the same `d(y)` table.

## M2 Race

Goal: a full race against the four named rivals and six traffic machines
runs from the countdown to a results screen: characters, rubber band,
machine collisions, thermal, Overclock (Up), pads, throttled zones, hot
spots, hops, rank, the minimap, the results screen, the attract autopilot
and the "every committed track is completable" test.

### Tracks

- **Track A: rivals and traffic** (`ai.zig` characters, `sim.zig`
  machine-machine collisions and rank, rubber band, host tests): the
  `Character` table of SPEC 3 (ARGMAX fast/slow turning, DROPOUT lane
  wander, BACKPROP corners, OVERFIT exact line; batch traffic at 55% on
  the line, two per sector), circle collisions of radius 10 with 30%
  normal exchange and 60 thermal each, rank from `lap * 256 + progress`
  plus the fraction to the next sample, the player's finish freezing the
  others' order.
- **Track B: screens** (`hud.zig` rank + minimap + Overclock bar,
  `results.zig`, `main.zig` Overclock input and results flow, scripts,
  bench toml, RUNNING.md): the 32x32 minimap (Select toggles 48x48) drawn
  once per race from the centerline into a 1-bit buffer, machines as 2x2
  dots; `3RD` top-right; the results screen (rank, time, best lap,
  rewinds 0, thermal left, `COMMITTED`); Up = Overclock when thermal >=
  100 (costs 250, 90 ticks of boost).

### Done criteria

- host tests: determinism with 11 machines; the completable test drives
  the SNOUTY character 3 laps on every track in `track.tracks` with the
  rivals present and no crash; rank is a permutation.
- preview: `m2_race.json` reaches the results screen; `docs/preview_m2.gif`.
- bench: the stress scene (four rivals and traffic on screen) worst frame
  recorded; still under 50% of budget.

### M2 status

- 2026-10-02: DONE. Track A (Opus agent): `ai.characters` (SNOUTY,
  ARGMAX 1.08x top / 0.85x steer, DROPOUT lane wander +-22 px / 240
  ticks, BACKPROP 0.94x top / 1.17x steer / 1.25x grip, OVERFIT 1.03x top
  / 2x damage / loses 15% speed per contact; traffic at 55% on +-8 px
  lanes), rubber band in permille from `sim.progress_px`, passing logic
  `ai.avoid` (without it the rivals melted each other down), circle
  collisions (radius 10, 30% exchange, 60 thermal, COLLISION crash for
  the player above 4 px/tick closing), Overclock on the Up edge (cannot
  take thermal below 1), rank from `fine_progress`, traffic spread two
  per third of the lap. Track B: liveries by body-colour match, rank,
  minimap (32/48 on Select, 1-bit buffers built per race), results
  screen 150 ticks after the finish, Overclock-ready mark. Tests: 11
  machines deterministic over 600 ticks; completable Cold Aisle with the
  field present: SNOUTY finishes at tick 5676, 0 crashes, rank 2 (BACKPROP
  wins by 30 ticks); grid, collision, Overclock, rank-permutation tests.
  Preview `m2_race.json` + autopilot reaches the results screen at frame
  ~5830 (`debug_screen` 1). Bench (`m2_player.json`, 1500 frames, grid
  start with the whole field on screen): **mean 3.45 ms, worst 3.86 ms**
  (23%). `api.text` is 19% of the frame (10 drop-shadowed HUD strings):
  an own font blit is the first M4 fast path. ELF `.text` 91.1 KB, `.bss`
  10.5 KB. `docs/preview_m2.gif`.

## M3 Rewind and content

Goal: the Antithesis mechanic and the game around the race: hold-B rewind
on the snapshot bar, crash auto-rewind with the cause named, splash,
title, attract, menu (Quick Race, Grand Prix, Sound), pause menu, six
tracks across Edge and Spine with the Spine league art, the sound toggle
with its few tones.

### Tracks

- **Track A: content** (`tools/leagues.py` Spine painters + horizon,
  five new `.track` files: Substation Sprint, Exhaust Ridge (Edge); Fiber
  Backbone, Rack Row 7, Tape Vault (Spine); `assets/gen/*`, `build.zig`
  data_files list, `track.zig` table, RLE for the maps if the RAM figure
  needs it): every track passes the completable test with 11 machines.
- **Track B: rewind and screens** (`history.zig`, `rewind.zig` overlay,
  `main.zig` state machine Splash -> Title -> Attract/Menu -> Race ->
  Results -> Menu / Grand Prix standings, `menu.zig`, `sound.zig`,
  `hud.zig` snapshot bar, scripts, docs): SPEC 5.4 exactly: 180-tick bar,
  refill 1 per 10 ticks and full at the start line, 2 ticks per frame
  back while B is held with the dimmed frame and `<<`, resume with 30
  immune ticks; crash = 20-tick hit-stop then auto rewind of 120 ticks
  if the bar holds 90, otherwise `JOB KILLED` and RETIRED.

### Fixed interfaces

```zig
// history.zig (meta-state, never rewound)
pub fn reset() void;                 // new race
pub fn record() void;                // top of each live tick: log buttons, keyframe every 60
pub fn restore(tick: u32) bool;      // rebuild world.w at `tick`
pub fn earliest_tick() u32;
// sim.zig gains: pub fn simulate_logged(buttons) (live) and the silent replay path
```

### Done criteria

- tests: `restore(t)` equals the direct state for every t in a 600-tick
  run (11 machines); all six tracks completable; RAM figure recorded.
- preview: `m3_rewind.json` shows a hold-B rewind and a crash auto-rewind
  (`debug_rewinds`, `debug_tick` going backwards); `docs/preview_m3.gif`.
- bench: the rewind frame (2 simulate ticks + dimmed draw) recorded.

### M3 status

- 2026-10-02: DONE. Track A (Opus agent): Spine league (55-entry palette,
  cabinets, fiber, light shafts), five new tracks, `open:left|right`,
  the hop gap (32 px of void after the plate; a machine that does not hop
  falls), generator checks for lap length 3800..5000 and corner radius
  >= 30 px; all six tracks completable with the field of 11 (finish
  5234..6463 ticks, 0 crashes, SNOUTY ranks 2..4). Maps stay raw (plain
  RLE grows them; PackBits plus seam folding would save only ~35 KB net).
  Track B: `history.zig` (16 keyframes every 30 ticks, 512-entry log;
  the restore test checks 400+ ticks against direct states), hold-B at 2
  ticks a frame, crash hit-stop 20 frames then a 120-tick auto rewind for
  90 of the bar (else JOB KILLED, RETIRED on the results), splash, title
  with the attract demo after 10 s (autopilot, a 20-frame B hold every
  9 s), menus, pickers, pause, Grand Prix with 9/6/4/3/2 points and
  standings, sound toggle with four tones. Preview scripts assert the
  screen flow (`m3_menus.json`), the rewind tick for tick and the forced
  crash's auto rewind (`m3_rewind.json`), and the attract start. ELF
  `.text` 225.1 KB, `.bss` 20.3 KB: 246 KB + 32 KB stack of the 307 KB
  window, so Core (M5) needs the XIP build. Bench (`m3_bench.json`, 1700
  frames): **mean 2.77 ms, worst 9.05 ms** (54%): the worst frame is a
  rewind frame whose restore replays up to 29 ticks of 11 machines from
  the last keyframe (as predicted; the bugs cart has the same shape),
  `api.text` is 36% of the mean frame. M4 fast paths, in order: an own
  8x8 font blit, keyframes every 15 ticks or an incremental replay, the
  AI's per-tick cost.

## M4 Perf and polish

Goal: the M3 bench profile's fast paths, the hills trick, shake, effects,
the LED blink, the XIP build measured, tuning defaults confirmed; merged
to main and tagged with the review GIF.

### Tracks

- **Track A: generator and XIP** (`tools/build_tracks.py`, `.track`
  files, `assets/gen/*`, docs previews; a `-Dcart-mode=xip` build in a
  separate prefix and its bench run): the `hill` segment feature sets
  centerline flag bit 7 on the segment's samples (SPEC 15; the cart
  turns a run of hill samples into a smooth rise and dip, so a run of 20
  to 40 samples reads well); hills on Exhaust Ridge (the ridge), Fiber
  Backbone (the long sweepers) and Substation Sprint (one straight);
  the XIP ELF benched with the same script to answer SPEC 18.3 (tile
  fetch from flash).
- **Track B: cart** (everything in `cart/src/` and the bench toml):
  `font.zig` (own 8x8 blit from `assets/gen/font.bin`, `tools/gen_font.py`
  extracts the SDK font) replacing `cart.text` in the HUD and menus;
  `history.zig` window cache (states every 2 ticks of the current
  30-tick window, the previous window prefilled at the rewind rate, so a
  rewind frame replays at most 4 ticks instead of 29); hills in
  `render.zig`/`camera.zig` (a per-row z table from a forward march over
  the height profile, sprites projected with the same profile); shake
  (rail hits jitter the horizon row and a column offset for 4 ticks);
  effects (spark burst on rail hits and collisions, exhaust flame while
  boosting); the horizon LED blink (front palette entry 15 takes entry
  14's colour every 8 ticks).

### Done criteria

- bench worst frame under 6 ms on `m3_bench.json` (the rewind frame) and
  the mean under 2.5 ms; XIP numbers recorded.
- tests still green (restore equality with the window cache; the six
  tracks completable; hills do not change the simulation).
- `docs/preview_m4.gif`; merged to main; tag `snouty-zero/m4`.

### M4 status

- 2026-10-02: DONE. Track A (Opus agent): `hill` feature (flag bit 7,
  validation: runs >= 12 samples, clear of hops and seams) on Exhaust
  Ridge (samples 37..67), Fiber Backbone (17..46), Substation Sprint
  (198..223); XIP measured (SPEC 18.3): with badge-bench's XIP default
  (`--flash-cycles 0`) the XIP ELF counts the same cycles as the RAM ELF
  frame for frame, and the bench never charges data loads from the flash
  window, so the tile-fetch cost is only answerable on hardware; the XIP
  `.text` fits the 256 KB window with 37 KB spare. Track B: `font.zig`
  (the SDK font extracted by `tools/gen_font.py`, noinline blit: inlined,
  ReleaseFast copied the unrolled loops into every call site, +40 KB),
  `history.zig` window cache (states every 3 ticks; three windows: the
  live one plus two prefilled below it, 8 ticks of prefill per rewind
  frame; 8 periodic keyframes + 4 checkpoint slots, since a checkpoint
  in the periodic ring evicted its window's keyframe and forced a replay
  from tick 0), hills (forward march over the height profile for the row
  tables, same profile in the sprite projection), shake, spark bursts
  and exhaust flames, the LED blink. Bench (`m3_bench.json`, 1700 frames,
  two crash auto-rewinds in the run): **mean 2.03 ms, worst 4.72 ms**
  (28%; M3 was 2.77 / 9.05). `debug_rebuilds` stays 0 and
  `debug_replay_max` 10 over both rewind scripts. ELF `.text` 224.9 KB,
  `.bss` 35.4 KB: 261 KB + 32 KB stack of the 307 KB window, 14 KB left;
  the Core league (M5) goes XIP as SPEC 13 says. `docs/preview_m4.gif`
  (Exhaust Ridge: the hill, the open ridge, the field).

## M5 Stretch: the Core league

Picked by default (SPEC 16 says "pick with Adrian"; the Core league is the
first item and completes the three-league structure; machine select comes
with it, flash saves stay out per decision 17.6). Two structural moves
come first because the cart is at the RAM wall (261 KB + 32 KB stack of
307 KB) and the Core data (three maps 48 KB, tiles 16 KB, horizon 12 KB)
would overflow the 256 KB XIP window too:

1. **Compressed maps**: the generator packs every `<track>_map.bin`
   (target under 8 KB each; the maps are 128x128 tile indices with long
   runs and repeated rows) and `track.zig` unpacks the selected track into
   one 16 KB RAM buffer at race start (`track.select`). Every tile lookup
   (sim attributes, floor renderer) reads that buffer.
2. **XIP as the only build** (SPEC 13, the Genesis pattern): code and
   read-only data execute from the 256 KB flash window, the whole RAM
   window is data. The active league's tileset, palette and horizon are
   copied into RAM at race start too, so the per-pixel floor loop never
   reads flash (the XIP cache is 16 KB and the tileset alone is 16 KB;
   Genesis' rule: the flash hit rate must stay above 99.5%). The artifact
   is `zig-out/firmware/snouty-zero-xip.uf2`.

### Tracks

- **Track A: content and compression** (`tools/leagues.py` Core painters
  and horizon, `tools/build_tracks.py` map packer, three `.track` files:
  Hot Aisle, Kernel Ring, Weights Loop; `assets/gen/*`, `build.zig`
  `data_files`, `track.zig`: packed maps, `pub var map_ram`, `select(t)`,
  the decoder and its tests, `leagues` with CORE).
- **Track B: cart** (`build.zig` XIP-only, `render.zig` RAM copies of the
  league art, `sim.zig` select call + machine select multipliers,
  `menu.zig`/`main.zig` machine row, docs, bench toml for the XIP ELF).

### Done criteria

- all nine tracks completable (host test); decoder round-trip test.
- XIP ELF under 256 KB `.text` with headroom; RAM figure recorded.
- bench on the XIP ELF (same model numbers as RAM; recorded) under the
  M4 figures plus the unpack at race start.
- `docs/preview_m5.gif` on a Core track; merged; tag `snouty-zero/m5`.

### M5 status

- 2026-10-02: DONE. Track A (Opus agent): Core league (53-entry palette,
  grating over orange glow, coolant pipes, exhaust vents, red haze with
  reactor towers), Hot Aisle (3835 px), Kernel Ring (3838, hop, hill
  126..158), Weights Loop (4509, two hops, hill 40..69, four hairpins);
  the LZ map packer (greedy LZ77 with one lazy step; nine maps 32.8 KB
  against 147 KB raw) and the 25-line decoder in `track.zig`
  (`select`, `map_ram`, `unpack_map`, round-trip tests); all nine tracks
  completable with the field of 11, 0 crashes (finish 5022..6626 ticks).
  Track B: XIP-only build (Genesis pattern; `snouty-zero-xip.uf2`), the
  active league's tiles and horizon copied to RAM at race start
  (`render.set_track`, 28 KB), the machine select row (the player drives
  a rival's physics multipliers; sprite stays the Anteater), docs. Found
  on the way: every floor palette up to M4 had red and blue swapped (a
  bitcast of the generator's RGB565 into the packed DisplayColor, whose
  first field is the low bits); fixed in `render.color565`, so the Edge
  sky is now pale blue-grey and the Core league orange; the M4 GIF was
  regenerated. XIP ELF `.text` 196.5 KB of 256 KB (59 KB spare), `.bss`
  80.6 KB of the 307 KB RAM window. Bench on the XIP ELF (`m3_bench.json`,
  the unpack at frame 200 included): **mean 2.05 ms, worst 4.74 ms**,
  the same as the M4 RAM build; the model never charges flash data loads
  (the RAM copies make that moot for the per-pixel loops; code fetches
  remain the hardware unknown, as for Genesis). `docs/preview_m5.gif`
  (Weights Loop, the BACKPROP character).

## M5.1 RAM cart again

2026-10-04: the SYCL organizers told Adrian that XIP carts will not
perform on the badge (execution from flash thrashes with the OS; Adrian
will confirm on hardware that they meant this feature). The M5 XIP ELF
was 196.5 KB `.text` + 80.6 KB `.bss`, 2.4 KB over the RAM window less
the 32 KB stack, and 28.7 KB of that `.bss` was the XIP-only RAM copy of
the active league's tiles and horizon. M5.1 builds both variants
(`build_options.xip`, `os_cart.Options.xip_custom_builder`): the RAM
cart reads the league's own arrays, the XIP cart keeps the copy.

### M5.1 status

- 2026-10-04: DONE. RAM ELF `.text` 196,244 + `.data` 636 + `.bss`
  51,816 B: 24.9 KB free below the 32 KB stack. Bench (`m3_bench.json`,
  1700 frames) RAM and XIP alike: **mean 2.09 ms, worst 4.81 ms** (29%).
  Host tests and check-float (both ELFs) pass. Nothing else changed: all
  nine tracks, three leagues and the machine select are in both carts.

## M5.2 Screen edges

2026-10-04, Adrian: some of the UI is cut off at the display edges. The
title drew `SNOUTY ZERO` from x -8, the subtitle `ECUMENOPOLIS GRAND
PRIX` is 184 px wide (now two lines on the splash and the title), and the
17-character rows `MACHINE: ANTEATER` / `SUBSTATION SPRINT` ran off the
right from the fixed x 44 (menu lists now centre the marker and items as
one block on the longest row, never left of 44; the machine rows are
space-padded to one length so the menu holds still). The race HUD moved
from 1-2 px to a 4 px margin (`hud.margin`: lap, clock, rank, speed,
bars, minimap). Bench unchanged: mean 2.09 ms, worst 4.81 ms.

## M5.3 Machine select you can feel

2026-10-04, Adrian on the badge: switching machines does not do anything.
It did, but invisibly: the player was always drawn as the Anteater, DROPOUT's
traits were all AI style (lane wander) so its physics equalled the
Anteater's, and the rest were the rivals' 0.94x-1.17x multipliers. Now the
player drives `ai.player_machines` (stronger multipliers, kept apart from
the rivals' characters so the AI tuning does not move), a picked rival's
machine is drawn as the player in its livery (rear-quarter views for the
lean), and a line under the main menu names the handling. Host test: every
pick finishes all nine tracks under the autopilot with at most one crash,
ARGMAX ahead of ANTEATER and BACKPROP. Bench with the default script:
worst frame 28-29% of budget, unchanged.

## M5.4 Engine sound

2026-10-04, Adrian: "Can we add engine noises to snouty zero?" The badge
renders its own stream now, so `lib/tone_stream.zig` gained a drone: a
held background voice (two sawtooths 1/64 apart, pitch and level gliding
over ~12 ms) mixed under the one-shot tones; carts that never call it
render as before. `cart/src/engine.zig` maps the player's state to pitch
and level (SPEC 9), `main.zig` `engine_cue` feeds it every frame, the
simulator gets a re-struck channel-1 pulse. Host tests: the drone (holds
the ring, mixes in range, glides, fades off) and the pitch model. Bench
(`m3_bench.json`): sound off unchanged (mean 2.07, worst 4.78 ms); with
`-Dsound=true` mean 2.24, worst 5.16 ms, and the `--wav` shows the grid
idle and rev, the climb with speed, silence in each hit-stop and the
warble through the auto rewinds, no gaps while racing.

## M5.5 Knockouts

2026-10-04, Adrian: "Can you destroy enemies? Like by smashing into them at
high speeds or knocking them off the track?" Before this, no: a rival that
melted down or fell reset on the centerline after the hit-stop, and contact
did a flat 60 thermal. SPEC 5.5 is the design. Work, one track (small):

- `world.zig`: `Machine.ko` (wrecking, then out) and `Machine.hit_by_player`
  (credit countdown, ticks), `World.kos` and `World.msg_who`, `Message.ko`;
  World stays under the 640-byte keyframe bound.
- `sim.zig`: ram damage in `contact` when the player is the rammer;
  credit; `crash` on a credited non-player machine sets `ko`; the
  hit-stop end takes a KO'd machine out (`active = false`) instead of
  `recover`; traffic starts at `tuning.traffic_thermal`.
- `sprites.zig`: wreck flash and a spark burst every few ticks while `ko`;
  `hud.zig`: the KO message; `results.zig`: a KOS row; `sound.zig`: `ko`.
- Host tests: a rear-end ram damages the victim more than a side bump and
  more than the rammer; a credited meltdown and a credited fall knock out
  (rank 0, inactive after the wreck, the player ranks up, GP points 0); an
  uncredited rival meltdown still recovers; the completable races allow
  KO'd rivals; determinism with KOs.

Done when `zig build`, `zig build test`, `zig build check-float` pass, the
bench worst frame stays within the M5.4 figure, and a scripted KO shows the
wreck in the headless preview.

### M5.5 status

- 2026-10-04: DONE. Host tests: ram damage (rear-end 380 on a batch job,
  Overclocked more, a side bump less, the player only 60 when rammed), a
  credited meltdown knocks out (wreck, then inactive, rank 0, the player
  ranks up), uncredited crashes still recover, credit runs out after 120
  ticks, a credited fall knocks out, a finished machine never does, and a
  test driver that rams the field on Cold Aisle gets 2+ KOs in 60 s
  deterministically. A probe with that driver over a whole race: 5 to 9
  KOs on most tracks, the driver melting itself down once or twice doing
  it; the plain autopilot knocks out one rival in nine races (Weights
  Loop), so attract demos rarely show one. Preview
  (`--call debug_start_race:0 --call debug_set_autopilot:1 --call-at "330
  debug_force_ko"`): BACKPROP KILLED, the wreck flashes and sparks, rank 5TH
  to 4TH. Bench (`m3_bench.json`, 1700 frames): **mean 2.08 ms, worst 4.81
  ms** (29%), M5.4 was 2.07 / 4.78. RAM ELF 199,604 + 5,300 + 53,952 B,
  about 15 KB free below the stack. `zig build test` (all carts) and
  check-float pass.

## M6 Link race (two badges)

2026-10-05. Adrian asked for two-player Snouty Zero over the badge link
cable (root `docs/LINK.md` M2; the Game Boy link in Snouty Boy is verified
on two badges). Lockstep comes from the shared `lib/lockstep.zig`
(extracted from Snouty GC's M4 net code, also used by Snouty Cycles; root
`docs/LOCKSTEP.md`). Zero's app id is 'Z'. Defaults taken:

- **Menu.** A LINK RACE row in the main menu. In the simulator it is
  greyed, "NO LINK IN SIMULATOR". The lockstep's common wording is
  "PLUG IN THE CABLE", "WRONG CART: <name>", "WAITING FOR PEER" and
  "PEER LEFT, AI DRIVING".
- **Lobby.** The host (higher link nonce) picks the track: any track of
  any league, one rules byte. Both pick a machine (`ai.player_machines`,
  3 bits; both may pick the same one) and ready up. The host's Start goes.
  The guest sees the host's track live.
- **Race.** One race on that track: the usual rivals and traffic, with the
  host's human in machine 0 and the guest's in machine 1 (a rival slot),
  side by side in the back grid row. Each badge follows and shows the HUD
  for its own machine. KOs, overclock and thermal work as in solo play,
  and credit goes to whichever human did it. The results show both
  humans' places and times. No GP points. A then returns both badges to
  the lobby.
- **Lockstep.** The input byte has A, B, Up, Down, Left, Right and Start
  (bits 0-6, never 0xC0/0xDB). Start is the lockstep pause bit, so both
  badges pause on the same tick. There is no rewind, scrub or attract in
  a link race. The hash is `lockstep.hash_fields` over the World. If the
  partner leaves, the AI drives its machine to the finish. A desync ends
  the race with a DESYNC band, then the lobby.
- **Pumping.** At the top of `update`, then loop to 14 ms into the frame
  while `busy()`. Zero's worst frame is 4.8 ms, so no in-draw hooks.
  Solo play never touches the link (it starts when LINK RACE opens), so
  solo frames are unchanged.

Work, one track:

- `world.zig`, `sim.zig`: a second human. `World.humans: [2]u8` holds
  machine indices, or none. `simulate(w, inputs: [2]Buttons-or-byte)`
  stays pure. Every `world.player` use that means "a human" or "the
  credited human" becomes per-human. The renderer, HUD, camera and sound
  take a `view` machine index instead of the constant. Solo play is
  bit-identical: existing tests, rewind and history unchanged, keyframe
  World still under 640 B.
- `net` glue (`link_race.zig`): `Lockstep(link.Badge, G)` with G = Zero's
  World/simulate/hash/hand_over, the lobby screens and the race loop as
  in `docs/LOCKSTEP.md`.
- Host tests: two Worlds over `lib/link_virtual.zig` with loss race a
  whole track to the finish in sync; peer left (AI takes over, both
  finish); desync detected; pause on the same tick; solo determinism and
  the old tests unchanged.

Done when `zig build`, `zig build test` and `zig build check-float` pass,
the solo bench worst frame stays within M5.5 (4.81 ms), RAM still fits,
and a preview shows the lobby (debug view) and a two-human race from each
badge's view.

## Hand-off

All milestones are built, tested and on `origin/main` (tags
`snouty-zero/m0` .. `m5`, `m5.1` .. `m5.5`). What only Adrian can do: flash
`zig-out/firmware/snouty-zero.uf2` from main and play (the feel of the
tuning constants is what the emulated bench cannot answer), and, to check
the organizers' XIP verdict, the same game as `snouty-zero-xip.uf2`
beside it (RUNNING.md section 6); the deferred questions below are the
decisions taken by default.

## Deferred questions for Adrian

1. (M0) Camera height 64 / focal 128: the near floor shows a 16 px seam
   grid as squares about 24 px wide; F-Zero sits a little higher. The
   knobs are `tuning.cam_height` and `tuning.focal`; Up/Down in the M0
   free camera change the height live for judging it.
2. (M0) Four fog banks band visibly on long straights; eight would cost 1
   KB of palettes and nothing per pixel.
3. (M1) `steer_rate` 300 instead of the SPEC's 190, and Cold Aisle's
   sharpest corners at a 33 px centerline radius (slow-down corners).
   The alternative is a generator that rounds control-point corners
   (more spline points) and the SPEC rate; a play test decides.
4. (M1) A crash (fall, meltdown) resets to the centerline after the
   hit-stop until M3 brings the rewind.
8. (M5) The stretch pick: the Core league plus a machine select, no flash
   saves. M5 made the cart XIP-only; M5.1 made the RAM cart the default
   again, with the XIP cart beside it.
7. (M4) Hills are visual only (the simulation stays flat); crest height
   26 world px; the horizon strip does not move with them. The tuning
   pass used the defaults (no play notes yet); the autopilot's 30 s laps
   stand.
6. (M3) The auto rewind costs 90 ticks of the bar and goes back 120 (SPEC
   5.4's wording was ambiguous); the attract demo holds B for 20 frames
   every 9 s; the title shows Cold Aisle turning under it; the sound
   tones are a countdown beep, DEPLOY, a rail click and a two-note
   finish, nothing else.
5. (M2) The player starts 5th, alone on the back row (F-Zero style);
   rivals keep driving after they finish; Overclock leaves at least 1
   thermal rather than melting the machine on the spot; the autopilot's
   laps are 30 s (SPEC hoped for 20-25): top speed / drag are the knobs
   if the race should feel faster.
9. (M5.5) Knockouts are the player's alone: ram damage only when the
   player is the rammer, and a crash only knocks out a machine the player
   touched in the last 2 s, so rivals never vanish on their own and the
   AI tuning is unchanged. A determined rammer can clear most of the
   field; the knobs are `tuning.ram_damage_per_px` (200),
   `ram_overclock_q8` (1.5x), `ko_credit_ticks` (120) and
   `traffic_thermal` (400). A rewind brings knocked-out machines back.
