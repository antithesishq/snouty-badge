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

## M1 World engine

Goal: the strip becomes a sequence of segments (Bus, Heap, Bus, Sort, ...)
generated on the badge, with the dataflow engine running (palette cycling,
per-frame cell edits), the fog dither, title cards and the caption, the
autopilot flying by default, and the placeholder Snouty. Gate: the 1800
frame attract run (Bus-Heap-Bus-Sort and on) under 22 ms worst on the
calibrated bench, check-float clean, GIF for Adrian's review.

Scope kept for later: Tree, Hash, Stack, Pipeline and water (M2); Select
skip, the Bus packet verb, the 15 s autopilot timeout tuning and the real
Snouty sheet (M3). B works in M1 for the two districts that have a verb
(Heap: collect garbage, Sort: shuffle).

### Tracks

Three Opus agents in this worktree, separate `--prefix` builds, no track
edits another track's files. I write the scaffold first (every interface
below as a compiling stub, `main.zig` wired to all of them), then the
tracks fill in.

- **Track A: light and text** (`palette.zig`, `render.zig`, `text.zig`,
  `sprite.zig`): pulse-range cycling (5.3), the 4x4 Bayer fog dither, cliff
  shading retune for the new structures, the title card and caption, the
  placeholder Snouty.
- **Track B: world and the first districts** (`world.zig`,
  `districts/bus.zig`, `districts/heap.zig`): the segment sequencer, the
  floor with the real palette indices, the live-district tick dispatch, the
  Bus, the Heap with malloc/free and the GC sweep verb.
- **Track C: Sort, autopilot, wiring** (`districts/sort.zig`, `camera.zig`,
  `main.zig`, `input.zig`, `tools/scripts/`, `../../badge-bench/carts/snouty-flyover.toml`,
  `docs/RUNNING.md`): the Sort district with the live quicksort and the
  shuffle verb, the autopilot and manual takeover, Start toggle, B to the
  live verb, debug exports, the attract and manual scripts, docs.

### Fixed interfaces (M1 additions; M0 interfaces stay)

```zig
// world.zig
pub const floor: u8 = 20;                 // noise floor base height; everything builds on floor + n
pub const bus_len = 64;                   // rows
pub const district_len = 192;             // rows; bus + district = 256 = one "pair"
pub const Kind = enum(u8) { bus, heap, sort };  // M2 appends tree, hash, stack, pipeline
pub const order = [_]Kind{ .heap, .sort };      // district cycle; pair p holds order[p % order.len]
pub const Segment = struct { kind: Kind, y0: i32, len: i32, seed: u32, index: u32 };
pub fn segment_at(y: i32) Segment;        // pair = floor(y / 256); bus if y mod 256 < 64
pub fn live() Segment;                    // the district being ticked: the one under the camera, or the next one when the camera is on a bus
pub const Rows = struct { h: *[W]u8, c: *[W]u8 };
pub fn rows(y: i32) ?Rows;                // ring row y, null if not in the ring; districts edit through this
pub fn regen_row(y: i32) void;            // rewrite row y's static content (floor + segment row()) if in the ring
pub fn floor_row(y: i32, h: *[W]u8, c: *[W]u8) void;  // noise floor + grid lines (called by gen_row before the segment's row())
pub fn tick(frame: u32, cam_row: i32, verb: bool) void; // after advance_to: enter() the live district when it changes, tick it, run its verb when `verb`
pub fn entered_segment() ?Segment;        // the segment the camera crossed into this frame (once), for the title card
pub const District = struct {
    title: []const u8,                    // caps, at most 8 chars
    gloss: []const u8,                    // one line, at most 19 chars
    caption: []const u8,                  // "B: ...", at most 19 chars
    alt: i32,                             // autopilot cruise altitude above `floor`, cells
    verb_at: i32,                         // local row where the autopilot presses B, -1 never
    row: *const fn (seed: u32, ly: i32, h: *[W]u8, c: *[W]u8) void,
    enter: *const fn (seg: Segment) void,
    tick: *const fn (frame: u32, cam_row: i32) void,
    verb: *const fn () void,
};
pub fn info(kind: Kind) *const District;  // the table entry (bus included: no verb, caption "NEXT: <name>" is built by caption())
pub fn caption() []const u8;              // caption for the segment under the camera

// districts/<name>.zig: exports exactly the District fields as pub decls
// (title, gloss, caption, alt, verb_at, row, enter, tick, verb); world.zig
// builds the table from them.

// palette.zig
pub var cur: [256]u16;                    // this frame's palette (pulse ranges rotated), DisplayColor bits
pub fn begin_frame(frame: u32) void;      // rotate into cur, rebuild fog from cur
pub const pulse_a = 32; pub const pulse_a_dash = 48; pub const pulse_b = 64; pub const pulse_b_dash = 80;
pub const white = 31; pub const rubble = 20; pub const grid = 16;
pub const bus_road = 96; pub const bus_rim = 98; pub const sort_hue0 = 100; pub const sort_pivot = 148;
pub const heap_alloc = [3]u8{ 196, 198, 200 }; pub const heap_free = 202;

// render.zig: unchanged API; draw(frame) dithers fog on (x, frame). The
// terrain is drawn full screen; sprite and text draw over it afterwards.

// text.zig
pub fn show_card(title: []const u8, gloss: []const u8) void;  // 90 frames, top-left; replaces the current card
pub fn set_caption(s: []const u8) void;   // persistent, bottom-left, row 119
pub fn flash_caption() void;              // 20 frames bright
pub fn draw(frame: u32) void;             // after render.draw and sprite.draw

// sprite.zig
pub const show_avatar = true;             // the one constant that removes Snouty
pub fn draw(roll: i32) void;              // 24x16 at x 68..91, rows 100..115; frame by roll sign past 6 rows

// camera.zig
pub const Stick = struct { steer: i32 = 0, pitch: i32 = 0, boost: bool = false, verb: bool = false }; // steer/pitch Q16 in -1..1
pub var autopilot: bool = true;
pub fn pilot(frame: u32) Stick;           // reads input.zig; Start edge toggles; any stick/A/B input takes manual control; idle_frames without input returns to autopilot
pub fn update(stick: Stick, frame: u32) void;
pub const idle_frames = 450;              // 15 s

// main.zig update() order
//   input.update(read_controls()); const stick = camera.pilot(frame); camera.update(stick, frame);
//   world.advance_to(cam_row); world.tick(frame, cam_row, stick.verb);
//   if (world.entered_segment()) |seg| text.show_card(info(seg.kind).title, info(seg.kind).gloss);
//   text.set_caption(world.caption()); if (stick.verb) text.flash_caption();
//   palette.begin_frame(frame); render.draw(frame); sprite.draw(cam.roll); text.draw(frame);
```

Ring rule for ticks: the ring holds `[cam_row - 8, cam_row + 248)`, so a
live district's rows behind the camera are gone; every dynamic edit goes
through `world.rows(y)` and skips null. `world.tick` only calls a
district's `tick` once its last row is generated, which is true from 56
rows before the end of the preceding bus. A district's `row()` must be a
pure function of `(seed, ly)` (layouts are recomputed from the seed, in a
`gen` slot for the segment being generated and a `live` slot for the
segment being ticked; the two are never the same segment because the ring
is shorter than one bus + district cycle).

### Constants (from `docs/concept/README.md` and `tools/concept.py`)

Floor (Track B): `h = floor + noise2 >> 5` (0..7 over `floor` = 20),
colour `2 * n` (indices 0..14), grid lines every 64 cells in x and y as
`grid + (n >> 1)` (16..19). The M0 test blocks are gone.

Bus (Track B): deck x 110..145 at `floor + 8`, colour `bus_road`; rims
x 110..111 and 144..145 `bus_rim`; four 2-cell lanes at x 116, 124, 131,
139 (cells x+0, x+1) painted `pulse_a_dash + (ly + 5k) % 16` for lanes
0 and 2 and `pulse_b_dash + (ly + 5k) % 16` for lanes 1 and 3 (the B range
rotates the other way, so the lanes alternate direction); pylons 4x4 at
x 104 and 148 every 16 rows from ly 8, `floor + 14`, `bus_rim`. Title
`BUS`, gloss `the address bus`, autopilot alt 40, no verb (M3).

Heap (Track B): rows of blocks from ly 6 to ly 180; a row has depth
10..27 and blocks of width from {8,10,12,14,16,20,24,30} with gaps 3..7
starting at x 0..5; block depth = row depth - 0..4; a block overlapping
x 122..133 (the corridor) or a 22% roll is freed: height `floor + 6..15`,
colour `heap_free`; otherwise allocated: `floor + 20..85`, one of
`heap_alloc`; 40% of allocated blocks are unreferenced (GC victims). Free
list: polyline through freed-block centres in (y, x) order, vertical then
horizontal legs, 2 cells wide, colour `pulse_a + dist % 16` where dist
counts cells along the polyline, raising cells to `floor + 3`, only on
cells at or below `floor + 20`. Tick: every 40 frames pick a block at
least 16 cells from the camera's x: an allocated one frees (sinks to
`floor + 8` over 8 frames, turns `heap_free`) or a freed one mallocs
(rises to `floor + 40` over 8 frames, turns `heap_alloc[0]`). Verb
(`B: collect garbage`, autopilot at local row 30): a 2-row white
(`white`, height `floor + 24`) wall starts 12 rows ahead of the camera and
moves away at 4 rows per frame to the end of the district; every
unreferenced block whose near edge the wall has passed collapses over 10
frames to `floor + 2` and turns `rubble + (x % 3)`; the rows the wall
leaves are restored with `regen_row` then the collapse state re-applied.
Only one sweep at a time. Title `HEAP`, gloss `malloc / free / gc`, alt 40.

Sort (Track C): 64 bars of 4 cells across x; 17 bands, band r at rows
`14 + 10r .. 14 + 10r + 6` (7 deep, 3 gap); band values are a seeded
permutation of 0..63; bar height `floor + 6 + v * 74 / 64`, colour
`sort_hue0 + 2 * (v * 24 / 64)`; pivot bars `sort_pivot`. Tick: the
nearest band at or ahead of `cam_row - 8` that is not sorted runs
quicksort (Lomuto, explicit range stack, last element pivot) at 2 swaps
per frame, rewriting the two bars' cells after each swap and painting the
current pivot `sort_pivot` until its partition ends; a finished band is a
rainbow ramp. Verb (`B: shuffle the band`, autopilot at local row 60): the
running band (or the next unsorted one) is Fisher-Yates shuffled in one
frame, its rows rewritten, and it sorts at 8 swaps per frame until done.
Title `SORT`, gloss `quicksort, live`, alt 90.

Palette (Track A): `cur[32 + j] = rgb565[32 + ((j - frame) & 15)]`,
`cur[48 + j] = rgb565[48 + ((j - 2 frame) & 15)]`, `cur[64 + j] =
rgb565[64 + ((j + frame) & 15)]`, `cur[80 + j] = rgb565[80 + ((j + 2
frame) & 15)]`; everything else copied. Fog is rebuilt from `cur`.

Fog dither (Track A): `fog_q[step]` is the level in Q4 (0..112) on the M0
curve; sixteen `[max_steps]u8` tables `fog_level_t[t][step] = (fog_q +
t) >> 4` (t 0..15), the column picks `t = bayer4[x & 3][frame & 3]`
(SPEC 5.3). If the GIF shows the 4-frame flicker as crawl, switch to
`bayer4[x & 3][(x >> 2) & 3]` (spatial only) and say so in the status.
Cliff shading: `cliff_dh` 12 -> 4 so bus rims, sort bars and heap block
faces shade; the 3-high free-list ridge must not.

Text (Track A): OS 8x8 font via `cart.text`, no background; each glyph
drawn twice, black one pixel down-right first. Card: title at (4, 4) in
`0xFFB040`, gloss at (4, 14) in `0xC8D0E8`, 90 frames, the last 20 fading
by drawing in the dim colour only. Caption at (4, 119) in `0x8090B0`,
flashed `0xE8FFFF` for 20 frames. Boot card: `MEMORY LANE` /
`generated on badge` with a third line `at 30 fps` (from
`build_options.flyover_fps`), shown by main at frame 0; a district card
replaces it.

Sprite (Track A): 24x16, three frames (level, bank left, bank right) as
`[16]u24` literals, two colours (`0xE8D8C0` body, `0x402830` outline), at
x 68..91, rows 100..115, transparent zero bits; frame by `roll` sign when
`|roll| > 6 rows`. `show_avatar = false` compiles it out.

Autopilot (Track C): default on. Target x = 128 in a bus; in a district
`128 + 16 sin(frame / 512 turn)`; steer is a P controller on `(target -
x)` with a lead of 40 frames of the current yaw drift, output clamped to
`+-1/3` (Q16 in `Stick.steer`), so the roll stays gentle; pitch holds
`cruise_alt` at `floor + info(live).alt` (the camera already lifts for
terrain); presses B once per segment when `cam_row` crosses `y0 +
verb_at`. Manual: any stick/A/B input switches to manual and resets the
idle counter; `idle_frames` without input returns to autopilot; Start
toggles (edge). Manual `Stick` is `+-1` per button.

### Scripts and bench

- `tools/scripts/attract.json`: `[]` (no input; the autopilot flies),
  used with `--frames 1800`. The bench toml switches to it (1800 frames,
  `budget_ms = 22.0`).
- `tools/scripts/m1_manual.json`: stick right 60-120 (takes control),
  B at 200 (heap GC), left 400-460, B at 700 (sort shuffle), Start at 900
  (autopilot back on), 1200 frames.
- Debug exports added (Track C): `debug_segment_kind`, `debug_segment_index`,
  `debug_autopilot`, `debug_live_kind`; `debug_world_check` compares only
  rows outside the live district (dynamic edits are legitimate there).

### Done criteria for M1

- `zig build -Dcart=snouty-flyover`, `zig build check-float` pass; `.text
  + .data` under 60 KB, `.bss` under 160 KB (M0 was 141.7 KB; the RAM
  window is 275 KB, `-Dflyover_depth=128` stays the escape).
- Attract run 1800 frames: calibrated bench worst frame under 22 ms;
  `debug_world_check == 0` at frame 1799; the camera never sinks below
  the terrain (`debug_cam_alt` above `debug_map_height` under it, checked
  by the manual script's `--at` lines).
- Preview GIFs in `docs/`: `preview_m1_attract.gif` (1800 frames, every
  3rd) and `preview_m1_manual.gif`; the Heap GC wall and the Sort
  swaps visible in them.
- `docs/RUNNING.md` updated (controls table, scripts, exports), PLAN
  status line with the bench numbers, tag `snouty-flyover/m1`.

### M1 status

- 2026-09-30: started. Contract above; scaffold 225d7cf (sequencer, district
  table, `Stick`, text/sprite stubs); tracks A, B, C as Opus agents.
- 2026-09-30: done, tag `snouty-flyover/m1` (code 00868e0). Calibrated
  badge-bench over the 1800-frame `attract.json` run: worst 11.03 ms
  (frame 1044), mean 6.66, p95 7.21; 50% of the 22 ms budget, 0 frames
  over. Hot: the inlined march 86%, `api.text` 8.6% (the shadowed card and
  caption, about 0.6 ms), memcpy 2.5%, `gen_row` 2.2%; the district ticks
  are under 0.3% together. The worst frame is a hair over the 11 ms line
  of SPEC 10, so 60 fps is not free; M2 decides with the other districts
  in. Sizes: `.text` 37,408 B, `.data` 128 B, `.bss` 151,700 B (Heap
  3.0 KB, Sort 3.0 KB, fog threshold tables 3 KB, fog pulse cache 1 KB).
  check-float passes; `debug_world_check` is 0 at frame 1799 of the
  attract run and at 1199 of `m1_manual.json`; every `--at` check in
  RUNNING.md passes; lowest camera clearance 26 cells (attract) and 7
  (manual, over the Heap). GIFs: `docs/preview_m1_attract.gif` (1800
  frames, every 3rd) and `docs/preview_m1_manual.gif`.
  - Track A (light and text): `palette.init()` builds `fog` once and
    keeps the pulse entries; `begin_frame` rotates the four pulse ranges
    into `cur` and `fog` (about 576 stores a frame instead of the 2048-blend
    rebuild). Fog dither: 16 Q4 threshold tables `fog_level_t`, the column's
    table chosen by `bayer4[x & 3][frame & 3]`; the temporal variant is
    kept (`fog_temporal` knob; the spatial one looked the same, no visible
    crawl). Cliff shading `cliff_dh` 12 -> 4. Shadowed 8x8 text, card 90
    frames with a 20-frame dim tail, caption with a 20-frame flash,
    `show_card3` + `text.fps_line` for the boot card. Placeholder Snouty,
    24x16, three frames as two-layer u24 literals, banks past |roll| > 6.
  - Track B (world, Bus, Heap): the floor uses the real palette (0..14
    shades, one-cell grid in 16..19). `world.tick` restores the old
    district's rows still in the ring when the live district changes, so
    `debug_world_check` stays 0 across switches. Bus per the constants. Heap:
    seeded block layout (at most 144 blocks; 126 seen over 20000 seeds),
    free-list polyline as a pure function of (seed, ly), malloc/free every
    40 frames at least 16 cells off the camera x, GC wall at 4 rows per
    frame turning unreferenced blocks into rubble over 10 frames, re-applying
    dynamic state to the rows it leaves; worst measured tick 4.6K cell
    writes in a frame. Deviations kept: a victim must also reach past the
    wall's start row; the wall cuts through tall blocks like the prototype.
  - Track C (Sort, autopilot, wiring): Sort with a resumable per-band
    quicksort (Lomuto, 2 swaps per frame on the nearest unsorted band past
    `cam_row + 40`, white pivot), B shuffles a band and re-sorts at 8 swaps
    per frame; per-frame writes capped at 2 x swaps + 2 bars (a bar is 28
    cells), 64 + 6 bars on a shuffle frame. Deviations kept: the work line
    is `cam_row + 40` (the band under the camera is off screen from the
    Sort altitude); bands start presorted by r/16 of their partitions
    (`presort` knob) for the concept's staircase; Sort `alt` 110 (90 put
    the camera 11 cells over the tallest bars) and the autopilot looks
    down (horizon row 52) in districts with `alt >= 80`. Autopilot: P
    controller with 40 frames of lead, clamp 1/3; over the attract run x
    stays in 112..144, roll within +-6 rows, 16 roll flips at least 50
    frames apart, Sort altitude 124..129, B once per district at
    `verb_at`; any input takes manual, 450 idle frames or Start return to
    autopilot. New exports `debug_cam_ground`, `debug_cam_clear`,
    `debug_sort_state`, `debug_sort_max_bars`. `m1_manual.json` presses the
    Sort B at frame 600 (at 700 the camera is on the Bus).
  - Integration: the segment the camera starts in is not reported by
    `entered_segment`, so the boot card keeps its 90 frames.
  - For the GIF review: does the Heap read at altitude 40 or should the
    autopilot fly higher; is the Sort's near field too busy; rubble
    (indices 20..22) is dark and reads as footprints, brighten or not; the
    temporal fog dither on the LCD.

## M2 The other districts

Adrian (2026-09-30): "keep building and defer/default any decisions", so
the M1 review questions take their defaults (Heap altitude 40, Sort near
field as is, rubble dark, temporal dither kept) and M2 starts at once.

Goal: the full district cycle Bus, Heap, Sort, Tree, Hash, Stack, Pipeline
with each district's tick dataflow and its B verb where it is cheap, the
water reflection with the mirrored sky and Iris sun, the Stack's scripted
dive through the autopilot altitude track, frame hashes for regression,
and the frame-rate decision. Gate: the full attract run (2400 frames, one
whole cycle and a Bus) under 22 ms worst on the calibrated bench,
`debug_world_check == 0`, check-float clean, GIFs.

Frame rate: decided now. M1's worst frame is 11.03 ms and the reflection
adds a second march on lake columns, so the lock stays at 30 fps for good
(`-Dflyover_fps=60` remains a build knob, unsupported). The 22 ms budget
stands.

Deferred to M3/M4: the Tree rotation on every third insert, the Stack
overflow "canyon unwinds" animation (M2 does the pit and the sky flash),
dam hold/pass of packets (M2 packets are the palette cycling), Select
skip, Bus packet verb, Snouty sheet.

### Tracks

- **Track A: water** (`render.zig`, `palette.zig`): the reflection pass,
  mirrored sky and sun, ripple, the water fog table, `sky_flash`.
- **Track B: Tree and Hash** (`world.zig`, `districts/tree.zig`,
  `districts/hash.zig`).
- **Track C: Stack, Pipeline, tooling** (`districts/stack.zig`,
  `districts/pipeline.zig`, `camera.zig`, `main.zig`, `tools/scripts/`,
  `tools/check_render.sh` + `tools/render_hashes.txt`, `docs/RUNNING.md`,
  bench toml).

### Fixed interfaces (M2 additions)

```zig
// world.zig
pub const Kind = enum(u8) { bus, heap, sort, tree, hash, stack, pipeline };
pub const order = [_]Kind{ .heap, .sort, .tree, .hash, .stack, .pipeline };
pub const water: u8 = floor - 12;         // = 8: a cell with h <= water is water (colour palette.water_idx)
pub const District = struct { ...as M1..., alt_at: *const fn (ly: i32) i32 }; // autopilot altitude above floor at local row ly (ly may be negative on the Bus before; clamp); districts without a track return alt
// districts export alt_at as well (pub fn alt_at(ly: i32) i32).

// palette.zig
pub const water_idx = 24;                 // the map index of water cells
pub var fog_w: [fog_levels][256]u16;      // water-tinted fog table (from `water`), pulses rotated like `fog`
pub const tree_level = [6]u8{ 150, 152, 154, 156, 158, 160 };
pub const hash_bucket = 162; pub const hash_chain = [3]u8{ 164, 166, 168 }; pub const hash_small = 170;
pub const stack_top = 172; pub const stack_band0 = 174 /* + 2j, j 0..9 */; pub const stack_lip = 194;
pub const pipe_dam = 204; pub const pipe_spring = 206;
pub const pit = 28;                        // stack overflow pit (black; Track A darkens 28 to 0x000000)

// render.zig
pub const reflections = true;             // knob: false = flat water colour
pub var sky_flash: u8 = 0;                // frames of white sky left (stack overflow); draw() decrements
```

### Reflection algorithm (Track A)

Per column, pass 1 is the M1 march with one change: a sample with
`h <= world.water` is water and is drawn as an opaque surface at height
`water` with `fog[level][water_idx]`; the rows it fills are recorded in a
128-bit per-column mask `wmask` (4 u32) and `w_first_step` remembers the
first water step. If the column had no water rows the column is done.

Pass 2 (when `reflections`): march again from `w_first_step` to the end
with `occ2` starting at the lowest water row + 1. A land sample (`h >
water`) projects at `row_m = hor + mul(alt - ((2 water - h) << 16),
inv_z[i]) >> 16` plus `ripple[(i + frame) & 15]` (a 16-entry table of
-1, 0, 1); if `row_m < occ2`, fill rows `[max(row_m, 0), occ2)` whose
`wmask` bit is set with `fog_w[level][c]` and set `occ2 = row_m`. A water
sample fills nothing (it is a hole to the mirrored sky). After the march,
every still-water row `r` in `[0, occ2)` (mask set, not yet written; keep a
second mask `wdone` or clear bits as they are written) gets the mirrored
sky: `sky_water_rel[(2 hor - r) - hor + 128]` (the sky table tinted toward
the water colour at init), or the tinted sun (`sun_core_w`/`sun_rim_w`)
where the column is under the sun and the mirrored row is inside the
sun mask. The mirror line is the horizon row of the column (`hor`).
Known approximation, accepted: a far reflection that should show below a
nearer one (a tall skyline behind a low dam) is clipped by `occ2`.

Cost: pass 2 runs only over lake columns and only from the first water
step; a frame over the lake roughly doubles the march. `reflections =
false` skips pass 2 and leaves the water surface colour.

`sky_flash`: while nonzero, the sky copy uses `sky_flash_rel` (the sky
gradient lerped 70% toward white) and decrements once per frame.

### Constants (from `tools/concept.py` and `docs/concept/README.md`)

Tree (Track B): the fixed shape from `gen_tree` stored flipped so the
leaves are near the camera and the root far: levels 0..5 with heights
`floor + {30, 24, 19, 15, 12, 10}`, ridge widths `{12, 9, 7, 6, 5, 4}`,
straight runs `{24, 14, 10, 6, 4, 0}`, fork half-span `dx = 64 >> lvl`
(diagonal branches one row per cell), a fork cap `wid + 4` wide and 6
higher at each fork, leaf mounds 6x6. Root at x 128, local row 40 from
the far end (so the far end of the district holds the root spine).
Colours `palette.tree_level[lvl]`. Search: pulse B comet path 3 wide
along the root-to-leaf trail of the current key, painted interior only
(a cell whose 4 neighbours are all within 2 of its height), so the ridge
faces do not light. Tick: a new key every 120 frames picks a random
leaf (5 bits from the rng); the old trail is repainted with the ridge
colour and the new one lit, spread over 12 frames per level from the
root (the "descent"). Verb (`B: insert a key`, `verb_at` 50): a new leaf
mound 6x6 rises over 10 frames at the end of the lit trail, offset 8
cells outward. Title `TREE`, gloss `binary search`, alt 185 (the
autopilot looks down there).

Hash (Track B): buckets 10x10 at `x = 11 + 32 i` (8 per row), rows every
36 local rows from 10 to 128 (4 rows), height `floor + 40`,
`palette.hash_bucket`; each bucket has a chain of 0..3 terraces (rng
choice from {0,1,1,2,3,3}) behind it: terrace k at rows `y + 11 + 7k`,
width `8 - 2k`, 6 deep, height `floor + 30 - 8k`, colour
`hash_chain[k]`; insert lane per row after the first: pulse A comet 2
wide from the strip edge (alternating sides) along `y - 3` to a target
bucket from {1, 2, 5, 6} then to the bucket, raised to `floor + 2`; the
rehash seam: pulse B dash 3 wide across the strip at local row 150,
raised to `floor + 4`; after it (rows 158 to 182, every 18) 16 small
buckets 6x6 at `x = 5 + 16 i`, height `floor + 20`, `hash_small`. Tick:
every 90 frames a bucket at least 16 cells from the camera x with fewer
than 3 terraces grows one over 8 frames. Verb (`B: rehash the table`,
`verb_at` 40): over 30 frames the terraces of every bucket ahead of the
camera drain to the floor and 8 small buckets per big row rise between
the big ones (`x = 27 + 32 i`, 6x6, to `floor + 20`), one sweep at a
time, restored per row through `regen_row` when animations end is not
needed (the changes are the new state until the ring wraps). Title
`HASH`, gloss `open hashing`, alt 120.

Stack (Track C): from `gen_stack` with `plateau` 90, `band` 8, `F` 10,
`S` 5: depth `d(r)` = `1 + r / 13` for local rows under 130, 10 for 130
to 159, then `10 - (r - 160) / 12`, clamped to 1..10; for a cell at
distance `dx = |x - 128|` (use `|2x - 255| / 2`) the terrace index
`kk = clamp(ceil((dx - F + 1) / S), 0, d)`, height `plateau - band (d -
kk)` above the floor, colour `stack_top` where `kk >= d`, else
`stack_band0 + 2 (j - 1)` with `j = (plateau - h) / band`, and
`stack_lip` on the lip cells `|dx - (F - 1 + (kk - 1) S)| < 1` for `0 <
kk < d`; the call/return signal: pulse B dash 2 wide down x 127..128
along the whole district. `alt_at(ly)` = floor height at that row + 14
(`plateau - band d(ly) + 14`; for negative ly use ly = 0), so the
autopilot dives with the floor and climbs out. Tick: nothing beyond the
cycling in M2 (band-edge pulses on push are part of the verb). Verb
(`B: push a frame`, `verb_at` 20): the canyon ahead of the camera (rows
from `cam_row + 8` to the district end) deepens one band over 10 frames
(`d += 1` for those rows, re-derived by the row function with a
`push_extra` count in the live state); at `d > 10` the floor cells (`kk
== 0`) drop to height 0 with colour `palette.pit` (the overflow pit) and
`render.sky_flash = 6`; the push count resets when the district is left.
Title `STACK`, gloss `call frames`, alt 24 (the track overrides it).

Pipeline (Track C): from `gen_pipeline`. Flow is toward the camera. Local
rows 0..109 are the lake: height `water`, colour `water_idx`, floor
noise removed. Six springs at `x = {28, 70, 108, 148, 186, 228}` on the
far end (rows 170..177: 8x8 towers `floor + 26` `pipe_spring` with a 4x4
`pulse_a` cap at `floor + 28`); channels: from the springs (row 170) the
pairs braid toward three merge points `{49, 128, 207}` at row 150 with
the concept's smoothstep and cosine offsets (integer: smoothstep
`t t (3 - 2 t)` in Q16, `camera.sin` for the cosine), then three
channels 7..13 wide meander (`6 sin`) from row 150 down to the lake at
row 108; channel cells are water (`water`, `water_idx`); packets: pulse
A dash 1 wide along each channel centre raised to `water + 1` (a lit
thread just above the surface); three dams 18 wide, 6 deep at row 116
(`floor + 16`, `pipe_dam`) with a 2-wide notch at `water + 1` carrying
the dash. Tick: nothing beyond the cycling in M2. Verb (`B: burst the
pipe`, `verb_at` 30): the three channel sections between the dams and
the merge point flood: their non-water cells within 12 of the centre
sink to `water` over 20 frames, hold 40, then `regen_row` restores them
over the next 20 frames (one row per frame from the far end). Title
`PIPELINE`, gloss `packets to the lake`, alt 18 (10 over the water; the
spring lifts over the dams).

Autopilot (Track C): `cruise_alt` follows `floor + info(live).alt_at(cam_row
- live.y0)` instead of `.alt`; the look-down rule keeps using `.alt`.
Stack: `alt_at` makes the dive; the clearance spring still wins over
walls.

### Scripts, hashes, bench

- `tools/scripts/attract.json` stays `[]`; the attract run becomes 2400
  frames (`--frames 2400`: a whole cycle of 7 segments is 1536 rows =
  2048 frames at cruise, plus the next Bus and Heap). The bench toml
  moves to 2400 frames.
- `tools/scripts/m2_verbs.json`: manual takeover at 60 (right 60-100),
  then B inside each district once (frames chosen from the row table:
  Tree at rows 576..767, Hash 832..1023, Stack 1088..1279, Pipeline
  1344..1535; at cruise row = 0.75 frame), Start at the end; 2200 frames.
- `tools/check_render.sh`: runs preview over `attract.json` with `--at "T
  debug_pixel_checksum == V"` for the twelve (T, V) pairs in
  `tools/render_hashes.txt` (frames 0, 200, ..., 2200), regenerated by
  `tools/check_render.sh --update`. It is the SPEC 10 regression check.
- Debug exports: `debug_water_cols` (columns that ran pass 2 last frame)
  and `debug_stack_depth`.

### Done criteria for M2

- Build, check-float; `.text + .data` under 70 KB, `.bss` under 165 KB.
- Attract 2400 frames: calibrated bench worst under 22 ms;
  `debug_world_check == 0` at the end; `debug_cam_clear > 0` at every
  60th frame; `check_render.sh` passes on the tagged build.
- GIFs `docs/preview_m2_attract.gif` and `docs/preview_m2_verbs.gif`,
  with the lake reflection of the sun visible.
- RUNNING.md, PLAN status, SPEC status (frame rate decided), tag
  `snouty-flyover/m2`.

### M2 status

- 2026-09-30: started; scaffold 95677c8 (seven-kind cycle, `alt_at`,
  `world.water`, stubs). Tracks A, B, C as Opus agents.
- 2026-09-30: done, tag `snouty-flyover/m2` (code 91b3863, the anteater
  ebc41b4). Calibrated badge-bench over the 2400-frame `attract.json` run:
  worst 12.77 ms (frame 1909, over the lake with pass 2 on all 160
  columns), mean 7.53, p95 12.09; 58% of the 22 ms budget, 0 frames over.
  Hot: the inlined march 89%, `api.text` 7.3%, memcpy 2.5%; every district
  tick is under 0.2%. Sizes: `.text` 66,496 B, `.data` 180 B, `.bss`
  158,728 B (gates 70 KB / 165 KB). check-float passes; `debug_world_check`
  is 0 at the end of the attract and `m2_verbs` runs; every `--at` check
  in RUNNING.md passes (one expectation corrected: the Stack depth is 2
  right after the second push frame); `tools/check_render.sh` passes
  against the regenerated `render_hashes.txt`. Lowest camera clearance 11
  cells (attract, Stack exit), 4 in `m2_verbs` (manual flight into the
  Stack entrance wall, the hard floor lifts it). GIFs
  `docs/preview_m2_attract.gif` (2400 frames, every 3rd) and
  `docs/preview_m2_verbs.gif`; the M1 GIFs are removed as superseded.
  - The flyer: Adrian could not recognise the placeholder blob and asked
    for "a flying anteater ... flapping his lil arms". `sprite.zig` is now
    a 44x28 side-profile anteater (long drooping snout, humped back, dark
    shoulder band, bushy tail, one arm flapping through three phases,
    sheared with the horizon when banking); frames come from
    `tools/anteater.py` as string rows, no comptime.
  - Track A (water): `palette.fog_w` from `water` with rotated pulses; index
    28 (pit) black. Two-pass reflection: pass 1 records `h == water` rows in
    a 128-bit column mask; pass 2 marches mirrored heights from the first
    water step to `refl_z_far` 200 cells with a 16-entry ripple and fills
    each free water row whose mirrored ray lies inside a mirrored column
    (per-row free mask, as the concept did) instead of the planned
    bottom-up `occ2`, which let the far shore cover the whole lake; the
    rest gets the water-tinted mirrored sky and the rippled Iris sun.
    `sky_flash` via `sky_flash_rel`. Worst lake frame runs pass 2 for 18.9k
    steps against pass 1's 22.6k. Water test is `h == water` exactly.
  - Track B (Tree, Hash): the fixed 63-node Tree with its root on local row
    191 (the shape spans 186 rows, so "40 from the far end" did not fit),
    trail painted interior only by the exact neighbour rule, a new key
    every 120 frames descending 12 frames per level, B searches from the
    root and raises a mound 6 rows past the leaf. Hash per the constants;
    a terrace grows every 90 frames; rehash drains the terraces ahead over
    30 frames while 8 small buckets per row rise, then restores the floor
    one row per frame. world.zig gained `floor_cell`, `span`, `x_dist`,
    `leg_row` for M3 to move heap/sort onto. About 13.9 KB `.text`.
  - Track C (Stack, Pipeline, tooling): Stack canyon per `gen_stack` with
    the lip on each tread's inner edge (the concept's lip test never
    matches an integer cell); the autopilot dives 116 -> 44 along floor +
    14 on the centre line with an 8-cell clearance scan; B pushes as a
    10-frame wave of whole-row rewrites from `cam_row + 8`; depth saturates
    at 10 and a push at full depth is the overflow (pit at `water + 1` in
    `palette.pit`, `sky_flash` 6). Pipeline per `gen_pipeline` with integer
    smoothstep and sine; `alt_at` is 10 over the water across the lake, 18
    after; B floods the stream sections over 20 frames, holds 40, restores
    a row per frame (28). `alt_high` 208 (the Tree at 205), `camera.no_verb`
    sentinel, negative `verb_at` allowed. Worst writes: push 4.4K cells,
    burst 1.4K. New exports `debug_water_cols`, `debug_stack_depth`,
    `debug_pipe_state`, `debug_verb_max_cells`, `debug_sky_flash`;
    `m2_verbs.json`; `check_render.sh`; bench at 2400 frames.
  - Integration defaults: Tree `verb_at` -40 (insert fires on the Bus
    approach, where the leaves are still in view), Bus `verb_at` =
    `camera.no_verb`, Pipeline `verb_at` 70 (the flood at 30 was 90 rows
    out of view).
  - Review questions, all defaulted: is the Tree readable from 205 or
    should it be lower; is the lake frame's 12.8 ms worth trading for
    `refl_z_far` 128; Stack pit at height 9 (works) or 0.

## M3 Hands on (outline)

All B verbs (Bus packet, Tree rotation on every third insert), boost fog
pull-in and horizon drop, Select skip to the next Bus, manual flight
clamping review, autopilot timeout tuning, heap/sort onto the world.zig
row helpers. Gate: every verb visible within 2 s of the press; bench
unchanged. Contract to be written at M3 start.
