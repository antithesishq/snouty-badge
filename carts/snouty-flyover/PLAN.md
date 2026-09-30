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

## M2 The other districts (outline)

Tree, Hash, Stack (scripted dive), Pipeline with the reflection lake and
mirrored sun; the 30/60 fps decision from the bench with every district
in; `tools/check_render.mjs` frame hashes. Contract written after the M1
GIF review.
