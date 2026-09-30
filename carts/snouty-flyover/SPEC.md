# Snouty Flyover: Memory Lane (spec)

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Tenth cart in this repository (`snouty-scene`, the demoscene cart, is the
ninth). Working title "Memory Lane"; the directory stays `snouty-flyover`
(section 17 question 1). Status and milestones are at the bottom; the
milestone contract is `PLAN.md`; concept renders are in `docs/concept/`
with `tools/concept.py` as the host prototype.

This replaces the 2026-09-30 idea note that lived here (itself lifted from
`carts/snouty-reflections/SPEC.md` section 14). The technique is unchanged;
the art concept is new: Adrian asked (2026-09-30) for something "totally
wild", flying through abstract representations of data structures and
dataflow.

## 1. One paragraph

A Comanche-style voxel flyover ("Voxel Space", NovaLogic 1992: one ray per
screen column marched across a heightmap, vertical spans filled bottom to
top with an occlusion row per column) in which the terrain is the machine.
Snouty flies down an endless 256-cell-wide strip, the address space, whose
districts are data structures built as architecture: the Heap is a
fragmented field of amber mesas that a garbage-collector wall sweeps flat,
the Sort is a rainbow bar field that sorts itself as you fly over it, the
Tree is a forking ridge system with a search descending it as light, the
Hash Table a grid of magenta towers with collision terraces, the Stack a
canyon of red strata that the flight dives into as the recursion deepens,
and the Pipeline a river of packets braiding through filter dams into a
mirror lake that reflects the Antithesis Iris, which hangs on the horizon
as the sun. Between districts runs the Bus, a raised highway of pulses.
Dataflow is what moves: palette cycling runs light along pointers, lanes
and paths, and a few hundred map cells change height every frame as
values are allocated, pushed, swapped, hashed and collected. B makes the
current district do its thing; the stick banks Snouty across the strip.
The whole world is generated on the badge as it comes into view, so the
cart ships no map data and the strip never ends.

## 2. Hardware facts the design leans on

- RP2354B, Cortex-M33 at 150 MHz, Core 1 for the cart alone. Frame budget
  at the 30 fps lock (section 10) is 5.0 M cycles; the column march is
  the only per-frame cost that scales, about 160 columns x 200 steps x
  ~25 cycles = 0.8 M cycles, so the design has 5x headroom and 60 fps is
  a stretch knob rather than a redesign.
- Framebuffer is column-major (`framebuffer[x][y]`), which is exactly how
  a voxel column renderer writes: each column's spans are stride-1 `u16`
  stores from the bottom up.
- All arithmetic is 32-bit fixed point (section 5.1), so the wasm build,
  badge-bench and the badge produce identical framebuffers and
  `tools/preview.mjs` frames are the correctness reference (same rule as
  snoutenstein). The FPU is not needed; `zig build check-float` must stay
  clean anyway.
- Cart RAM 307 KB (32 KB of it stack). The world map lives in `.bss` and
  is generated at run time (section 11), so the binary carries code, a
  palette and a sprite sheet only.
- Inputs: stick 4-way, A, B, Start, Select. Start+Select and the stick
  click belong to the OS.
- Audio: none (`docs/SOUND.md` policy and the speaker verdict of
  2026-09-30). Neopixels: never written (`docs/NEOPIXELS.md`).
- Rendering `.no_copy_full_frame`, full redraw each frame,
  `set_vsync_enabled(1000.0 / 30.0)`.

## 3. Controls

Everything an attendee can do should be discoverable in the first minute
(the "effort goes on the cart" rule). The caption line (section 4) always
names the B verb of the current district.

| Input        | Flight                                                        |
|--------------|---------------------------------------------------------------|
| Left / Right | Bank and steer across the strip (roll shears the horizon)     |
| Up / Down    | Pitch: dive / climb (altitude clamped above the terrain)      |
| A            | Boost while held: 2.5x speed, fog pulls in, horizon drops     |
| B            | The district verb (section 6): GC, sort, search, rehash, push, burst; on the Bus: send a packet |
| Select       | Skip to the next district (the Bus segment before it)         |
| Start        | Toggle autopilot (attract) / manual flight                    |

Autopilot is the default at boot: it flies a slow serpentine, presses B
by itself at scripted moments, and dives in the Stack. Any stick input
takes manual control; 15 s without input returns to autopilot. Manual
flight never lets the camera below the terrain ahead (section 5.5).

## 4. Screen layout

Full-screen 160x128 render, no HUD frame. Two text elements in the OS
8x8 font, both drawn over the sky region only so they never fight the
terrain:

- Title card on entering a district, 90 frames, top-left: the district
  name in caps and a one-line gloss (`HEAP  malloc / free / gc`).
- Caption, bottom-left, persistent and small: the B verb for where you
  are (`B: collect garbage`). It flashes for 20 frames when pressed.

Snouty is a 24x16 sprite (three banking frames: level, left, right) at
bottom-centre, drawn after the terrain, from `snouty-art` in the
code-driven style that counts as final; a two-colour placeholder blob
until the sheet is installed.

A debug overlay (`-Ddebug_overlay=true`) prints `render_us`, the frame,
the camera cell and the district in the top-right.

## 5. Rendering

### 5.1 The column march

Map: a ring of `depth` rows x 256 cells, two `u8` planes: height and
colour index. x wraps at 256 (banking never reaches an edge), y wraps in
the ring (section 5.4 explains generation). Camera `(cx, cy, alt)` in
Q16.16 cell units, yaw in 1/1024 turns, pitch as a horizon row offset,
roll as a per-column horizon shear.

Per frame, for each column `sx` in 0..159:

1. Ray direction from the yaw and the column's offset in a precomputed
   160-entry direction table (rebuilt only when yaw changes).
2. Occlusion row `occ = 128` (bottom). Horizon row for this column
   `hor = horizon + shear[sx]`.
3. March `z` from `z0 = 1.0` to `z_far` (knob, 256 cells) with step
   `dz` multiplied by `lod` (knob, 1.0075) each step: about 200 steps.
   Each step: `mx = (cx + dx * z) >> 16 & 255`, `my = (cy + dy * z) >> 16
   & (depth-1)`, `h = height[my][mx]`, `c = colour[my][mx]`.
4. Project: `row = hor + ((alt - h) * inv_z[step]) >> shift`, using a
   precomputed per-step reciprocal table (`inv_z`, 256 entries, Q16),
   so there is no divide in the loop.
5. If `row < occ`: fill rows `row..occ` with `pal_fog[fog_level[step]][c]`
   and set `occ = row`. Span height above `cliff_min` (knob, 6 rows) and
   a height jump above `cliff_dh` (knob, 12 cells) selects the colour's
   side entry (`c | 1`, section 5.3) so block faces are darker than
   tops. Stop when `occ <= 0`.
6. Rows `0..occ` are sky (section 5.2).

Cost per step is two loads, a multiply, a shift, a compare and a rare
span fill; the fill itself is bounded by 128 stores per column. The
water reflection (section 5.6) adds one compare per step.

### 5.2 Sky and the Iris sun

Sky is a 128-entry column gradient (`sky[row]`, RGB565, rebuilt when
the pitch changes: near-black `0x06040F` at the top through indigo
`0x2A1A5E` to a warm horizon band `0x7A3A2A`), copied per column above
the occlusion row. Over it, the sun: the Antithesis Iris mark
(`lib/iris_mark.zig`, 24x24 one-bit) scaled 3x to 72 px, centred on the
horizon at a fixed yaw so it slides with the camera's heading, amber
`0xFFB040` with a two-step halo. Since the mark is one-bit, the sky
loop is `if (sun_mask[row][sx - sun_x]) sun_colour else sky[row]` for
the 72 columns under it; elsewhere a plain copy. A sparse set of fixed
single-pixel "bit" stars, 40 of them, above row 40.

### 5.3 Palette and fog

256 palette entries, RGB565, with the layout the concept renderer
documents in `docs/concept/README.md`:

| Range   | Use                                                  |
|---------|------------------------------------------------------|
| 0-31    | Substrate: floor shades, grid lines, water, rubble   |
| 32-63   | Pulse gradient A (cyan to white to cyan): pointers, lanes |
| 64-95   | Pulse gradient B (amber to white to amber): bus, search |
| 96-255  | District colours, in top/side pairs (even = top, odd = side) |

Palette cycling is the dataflow engine: each frame the two pulse ranges
rotate by one (range A forwards, range B backwards), so any run of cells
painted with consecutive indices shows light travelling along it. It
costs nothing per cell.

Fog: `pal_fog[8][256]` (4 KB) is the palette blended toward the horizon
colour in eight levels; `fog_level[step]` maps march step to level. The
table is rebuilt every frame after the cycle (2048 lerps, ~30 k cycles).
Between levels a 4x4 Bayer threshold on `(sx, frame)` picks the upper or
lower level per column and step, which is the reflections cart's
temporal dither applied to fog instead of to colour: no bands, a little
grain.

### 5.4 World generation: the strip

The map ring is `depth` rows deep (knob, 256). The world is a sequence
of segments along +y: `bus (64 rows), district (192 rows), bus, district,
...` in a fixed cycle order (section 6) with a seed per visit so no two
Heaps are the same. Each frame, rows entering the far window
(`cy + z_far`) are generated before the march reads them: a district
generator is a function `row(seg_seed, local_y, out_height[256],
out_colour[256])`, plus an optional `tick(frame)` that edits cells of
the live district for its dataflow (section 6). Generating one row is
256 cells of cheap integer work (about 10 k cycles); the camera moves
at most 2 rows per frame, so generation is under 0.5 ms.

Rows behind the camera are overwritten as the ring advances. A district
fits in the ring with room to spare (192 + 64 < 256), so a `tick` that
edits the whole live district (the GC sweep, a sort pass) always finds
its rows present.

Lighting is baked by the generators: a top cell's colour index is the
material's top entry; the renderer picks the side entry for cliffs
(section 5.1). Height-band shading within a material (e.g. lower heap
mesas a shade darker) is the generator's choice of index.

Substrate under everything: the noise floor. Two-octave value noise,
amplitude 6, dark indigo (`0x141833` to `0x1E2450`) with a one-cell
brighter grid line every 64 cells in x and y (cache lines, `0x2C3468`)
so speed reads even over empty ground.

### 5.5 Camera and flight

Speed is in cells per frame: cruise 0.75 (28 s per 192-row district),
boost 1.9. Altitude has a floor of `max terrain in the 24 rows ahead
across the 32 cells around the flight line + 12`, applied with a soft
spring so the camera lifts before a wall rather than clipping it. The
Stack district overrides this with a scripted altitude track (the dive).
Roll follows the stick with a 12-frame ease; yaw is roll-driven (bank to
turn) with a cap of 1/16 turn either side of straight ahead, so the
strip always fills the view. Steering moves `cx` across the 256-cell
strip; the strip wraps, so flying off one edge arrives at the other.

### 5.6 Water and reflections (Pipeline)

Cells whose height is at or below the segment's water level `w` are
water. In the march, once a sample over a water cell projects below the
column's horizon, the column enters reflected mode: subsequent sample
heights are mirrored (`h' = 2w - h`) and spans take the water variant of
the colour (`pal_water[c]`, a darker blue-tinted table, 512 B). A column
that reaches `z_far` still reflected fills its remaining rows with the
mirrored sky gradient (and the mirrored sun, which is the money shot of
`docs/concept/pipeline.png`). A one-row sine offset per step (`ripple`,
amplitude 1 row, phase by `frame`) makes the reflection wobble. Cost:
one compare per step plus a second table lookup on water columns. Knob:
`reflections` off falls back to flat water colour.

## 6. Districts and their dataflow

Cycle order, one B verb each. Each district is `generate` (the static
architecture) plus `tick` (its dataflow, running whether or not anyone
presses B; B triggers the big event). Palette indices per district are
fixed in `palette.zig`.

| District  | Architecture (generate)                                                   | Dataflow (tick)                                                                   | B verb                                              |
|-----------|---------------------------------------------------------------------------|-----------------------------------------------------------------------------------|-----------------------------------------------------|
| Bus       | Raised highway, 32 cells wide, 8 tall, 4 lanes painted with pulse chains  | Lanes flow (cycling), alternate directions                                        | Send a packet: a bright 3-cell block races ahead    |
| Heap      | Mesas 8-30 cells wide, 20-90 tall, amber tops/orange sides; freed blocks teal and low; a free-list chain (pulse A) snaking between them | A block mallocs (rises over 8 frames) or frees (sinks, turns teal) every ~40 frames | Collect garbage: a white full-height wall sweeps away from the camera; unmarked mesas collapse behind it over 10 frames, leaving rubble; the free list re-threads |
| Sort      | 256 bars (one per x), 8 rows deep, hue by value; the field repeats along y | Quicksort runs live on the nearest unsorted band: a pivot bar goes white, partitions swap two bars per frame; sorted bands are rainbow ramps | Shuffle: the band ahead scrambles and the sort restarts fast (8 swaps per frame) |
| Tree      | Balanced binary tree from above: root spine on the centre line (height 96), forks at 45 degrees, height falling per level to leaf mounds at the edges; green by level | A search descends: pulse B lights one root-to-leaf path, 12 frames per level, a new key every 4 s | Insert: a new leaf mound rises at the end of the lit path; every third insert triggers a rotation (a ridge lifts and swings 90 degrees over 20 frames) |
| Hash      | Grid of magenta towers 6x6 cells, 40 tall, 16 apart; collision chains as terraces stepping down beside the buckets; insert lanes (pulse A) from both edges | Inserts arrive along lanes; the target bucket grows a terrace | Rehash: the whole table doubles: new rows of towers rise between the old ones, terraces drain to zero, over 30 frames |
| Stack     | Canyon on the centre line, 48 cells wide; plateau 90 high; terraced walls of red strata, 8 cells per frame band; floor steps down toward the far end | The camera follows the floor: a scripted dive as frames push, climb as they pop; band edges pulse (B gradient) on each push | Push: the floor drops another 8 and the walls gain a band; past 10 frames deep the floor falls out (stack overflow: black pit, sky flashes) and the whole canyon unwinds |
| Pipeline  | Springs at the far end, channels cut 12 below the floor braiding toward the camera, filter dams with notches, the last 80 rows a mirror lake | Packets (pulse A) flow down the channels; a dam holds a packet 10 frames then passes it; the lake reflects | Burst: 20 packets at once, the channel above the slowest dam floods (water level rises 6 over 20 frames), then drains |

The Sort, Hash and Pipeline districts are read best from altitude; the
Heap, Tree and Stack from low. Autopilot's altitude track per district
is a knob table.

## 7. Composition and palette notes

- Dark ground, bright structures. The floor and sky together are 70% of
  most frames and stay under 20% brightness so the pulses and tops carry
  the image; the fog colour is the horizon band, so distant structures
  sink into warm haze rather than grey.
- The Iris sun is always the brightest thing on screen except pulses.
  It sits at a fixed world yaw, so banking swings it across the sky.
- Every district has one dominant hue (amber, spectrum, green, magenta,
  red, cyan) and shares the two pulse gradients, which is what makes the
  strip read as one machine rather than six demos.
- Blocks over hills: generators produce flat tops and vertical faces
  only. The noise floor is the one smooth surface, and it is dark.

## 8. Audio

None. The badge speaker is out of the picture for every cart
(2026-09-30), and there is no sound toggle to build.

## 9. Architecture

```
cart/src/
  main.zig       start/update, vsync, input, debug overlay, wasm shims
  camera.zig     flight model (section 5.5), autopilot track
  render.zig     column march, sky, sun, fog dither, water (5.1-5.3, 5.6)
  palette.zig    fixed palette, pulse ranges, per-frame cycle, fog and water tables
  world.zig      map ring, segment sequencer, row generation, tick dispatch (5.4)
  districts/
    bus.zig heap.zig sort.zig tree.zig hash.zig stack.zig pipeline.zig
  text.zig       title card and caption
  sprite.zig     Snouty banking frames (from assets/gen via convert_gfx)
  fixed.zig      Q16 helpers, value noise, xorshift rng
tools/
  concept.py     host prototype and later the reference renderer (numpy)
  scripts/       badge-bench and preview input scripts
docs/
  RUNNING.md, concept/, milestone GIFs
```

`world.zig` is the only module that knows the district list;
`render.zig` reads the map and palette only. Each district module
exports `row(...)`, `tick(...)`, `verb(...)` and its `title`/`caption`
strings, so adding a district is one file and one table entry.

## 10. Performance and verification

Target: locked 30 fps, calibrated badge-bench worst frame at most 22 ms
across the attract run (a full cycle of every district with autopilot's
scripted B presses, `tools/scripts/attract.json`, 1800 frames). If M1
lands under 11 ms worst, the lock goes to 60 fps (`target_fps` knob)
and the budget becomes 11 ms; the decision is made once, in M2, from the
bench.

Knobs, in one block in `render.zig` and `world.zig`, in cut order if the
budget is missed: `z_far` (256 -> 192), `lod` (1.0075 -> 1.012),
`reflections`, `depth` (256 -> 128 rows, also halves the map memory),
`cliff shading`, `fog levels` (8 -> 4).

Correctness: all-integer rendering means `tools/preview.mjs` frames are
bit-exact with the badge. `tools/check_render.mjs` compares a dozen
scripted frames against committed PNG hashes; `tools/concept.py` is a
visual reference only (it is float, not a bit reference).

## 11. Memory budget

| Item                                  | Size            | Where   |
|---------------------------------------|-----------------|---------|
| Map ring, height + colour, 256x256    | 128 KB          | `.bss`  |
| Fog table `pal_fog[8][256]` u16       | 4 KB            | `.bss`  |
| Water table, sky column, inv_z, dirs  | 2 KB            | `.bss`  |
| Palette, sun mask (72x72 bits), stars | 1.5 KB          | `.data` |
| Snouty sheet 3 x 24x16, 4 bpp         | 0.6 KB          | `.data` |
| Code                                  | 30-50 KB        | `.text` |

Total well under the 275 KB usable window as a RAM cart; no XIP needed.
The `depth` knob halves the map if `.bss` pressure appears. Nothing
heavy runs at comptime: the sun mask and direction tables are built at
`start()` and the palette is a literal table (Mac comptime rule).

## 12. Asset manifest

- `assets/gen/snouty_fly.png`: 3 frames 24x16 from the `snouty-art`
  pipeline (a new `fly` cycle: level, bank left, bank right) on its
  15-colour palette; placeholder blob until then.
- Iris mark: shared `lib/iris_mark.zig`.
- Everything else is procedural.

## 13. Milestones

- **M0 Scaffold.** Cart registered in the root build; column march over
  a procedural noise-floor map with the sky and sun; fly forward with
  stick steering; bench toml and script; preview GIF; RUNNING.md. Gate:
  bench number for the bare march, check-float clean.
- **M1 World engine.** Map ring and segment sequencer, palette cycling,
  fog dither, cliff shading, Bus and Heap (with GC) and Sort districts,
  title cards and captions, autopilot, placeholder Snouty. Gate: attract
  loop of Bus-Heap-Bus-Sort under 22 ms worst; GIF review.
- **M2 The other districts.** Tree, Hash, Stack (scripted dive), Pipeline
  with the reflection lake and mirrored sun. Frame-rate decision (30 or
  60). Gate: full attract script under budget; check_render hashes.
- **M3 Hands on.** All B verbs, boost, Select skip, manual flight
  clamping, autopilot timeouts, Snouty sheet from `snouty-art`. Gate:
  every verb visible within 2 s of the press; bench unchanged.
- **M4 Polish.** Palette and fog pass from the GIF review, easter eggs
  (stack overflow, the free list spelling something), dist artifacts.

## 14. Relation to other carts

- `snouty-reflections` stays the per-pixel feat (ray tracing); this is
  the scale feat (kilometres of structure). They share the Iris and the
  ordered-dither idea, not code.
- `carts/snouty-scene/NOTES.md` lists a 15-second voxel part for a
  future demo; if that cart happens it takes this renderer as a module,
  not the other way round.
- `snoutenstein` and `snouty-maze` are the fixed-point and rasterizer
  precedents; the fixed-point rule here is theirs.

## 15. Risks

- **Legibility at 160 columns.** Structures narrower than about 8 cells
  vanish past 40 cells of depth. Mitigation: generators use big blocks;
  the concept renderer exists to catch this before Zig is written.
- **Palette cycling looks like noise** if too many cells pulse.
  Mitigation: pulses only on one-cell-wide paths and lanes; the
  reflection lake stays calm.
- **The march is cheaper than the fill on close flyovers**: a column
  facing a near wall fills 128 rows in one span, fine, but a staircase
  of near terraces can fill 128 rows in 20 spans of 6, also fine. The
  worst case is bounded by the screen, not the map.
- **Camera clipping into a rising block** (malloc under the flight
  line). Mitigation: generators never raise a cell within 16 cells of
  the flight line's current x; the altitude spring covers the rest.
- **Taste.** A machine landscape can read as a spreadsheet. Mitigation:
  the concept stills are reviewed before M1 and the palette is one file.

## 16. Verification of the claim

The title card at boot says "generated on the badge, 30 fps". Both must
stay true: no map data in the binary (the `.rodata` check in
`tools/check_size.sh`) and the lock at the bench-decided rate.

## 17. Open questions for Adrian

1. Title: "Memory Lane" (flying down memory lane), "Core Dump",
   "Dataflight", or something else? The directory stays `snouty-flyover`.
2. District order and count for v1: the six above plus the Bus, or cut
   to four for M1+M2 and add later?
3. Snouty as a banking sprite at the bottom (Comanche cockpit style), or
   no avatar at all and a pure first-person flight?
4. B verbs as the only interaction, or add a light goal (fly through
   the free list's rings, catch packets) later?
5. Iris as the sun: yes, or keep the Iris only in the lake as a
   reflected mark?
6. 30 fps locked with 5x headroom, or spend the headroom on 60 fps
   first and cut view distance to fit?

## Status

- 2026-09-30: idea note replaced by this spec at Adrian's request
  ("comanche style flyover technical flex cart", art concept: flying
  through abstract data structures and dataflow). Concept renders in
  `docs/concept/` (seven stills, `montage.png`, `concept.gif`) from the
  numpy prototype `tools/concept.py`. Nothing built; the root `build.zig`
  does not list this cart until M0.
- 2026-09-30 concept findings that amend the sections above (the
  prototype's README has the exact values): the Sort uses 64 bars of 4
  cells, not 256 of 1 (1-cell bars are confetti past 40 cells); the Tree
  only reads as a tree when low (10 to 30 cells) and seen from high
  altitude (185) with the horizon raised, so section 6's tree heights are
  wrong and the autopilot altitude table matters more than planned; the
  Pipeline lake needs about 110 rows so the far shore is distant enough
  for a low sun to reflect; pulse indices may only be painted on cells
  that are not the top of a tall block, or the whole block face lights up
  (rule for the generators, section 5.3); the Hash district is too dense
  up close and needs a wider grid or a taller camera; the white GC wall
  goes grey under fog and needs the emissive half-fog treatment.
