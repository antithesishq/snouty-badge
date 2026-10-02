# Snouty Zero: Mode 7 hover racer spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
A new cart in this repository, an F-Zero (SNES, 1990) style racer set on a
planet that is one AI datacenter. "Snouty Zero" is a working title. Status:
spec only, not built; the root `build.zig` does not list this directory yet.
Section 17 lists the decisions taken by default so Adrian can override them;
section 18 lists the facts M0 must check. Before building, M0 adds a
`PLAN.md` with the file layout and the per-milestone status, as the other
carts do.

## 1. One paragraph

A hover racer drawn the way the SNES drew F-Zero: a flat textured floor
transformed per scanline (Mode 7), scaled sprites for the machines, a
parallax horizon strip and a HUD. The badge draws the floor in software,
about 15,000 pixels a frame, which costs roughly 1.5 ms of the 16.7 ms
budget on the 150 MHz core the cart owns; 60 fps is the design point with
large headroom. The setting is an ecumenopolis that is a single
planet-sized AI datacenter: the tracks run through cold aisles between
rack rows, over cooling towers and down fiber backbones, and the
rival machines are named after training jargon. The Antithesis mechanic is
rewind: the race is deterministic, so holding B runs the whole world
backwards (rivals too) while a snapshot bar drains, and a fatal crash
rewinds automatically instead of ending the race. Tracks are generated on
the host from spline descriptions, so content is cheap and consistent with
the code-drawn art policy.

## 2. Hardware and platform facts the design leans on

- 160x128 RGB565, column-major framebuffer (`framebuffer[x][y]`), full
  redraw each frame with `.no_copy_full_frame`.
- One 150 MHz core for the cart; 16.7 ms per `update()`. Integer multiply
  is single cycle, so a multiply-accumulate per floor pixel is fine.
  `fp_dep` stalls (calibrated badge-bench) make dependent float chains
  slow; the whole simulation and renderer are fixed point and the cart
  passes `zig build check-float`.
- Inputs: d-pad, A, B, Start, Select. Start+Select and click belong to
  the OS. No analogue input, so steering is digital with speed-dependent
  rate (the SNES had the same).
- Cart RAM window 307 KB. The cart is a RAM cart (section 13) with an XIP
  build as well, as every cart has.
- Sound: off at boot with a menu toggle (`docs/SOUND.md`); no audio
  development beyond the toggle and a few confirmation tones (Adrian,
  2026-09-30: the speaker sounds bad). Neopixels off, no LED code.

## 3. Setting and theme

The planet is one datacenter; nobody remembers what it computes. The
Grand Prix runs through its infrastructure. Leagues are the layers of the
network fabric, deepest last:

| League | Where | Look (floor art, horizon, sky) |
|---|---|---|
| Edge (3 tracks) | the surface | rack-top grids, cooling towers with white plumes, solar fields; pale sky with a second sun; towers on the horizon |
| Spine (3 tracks) | inside the city | fiber bundles, switch cabinets, rows of green status LEDs, lit floor seams; no sky, the city rises on all sides with light shafts |
| Core (3 tracks, stretch M5) | the hot core | hot-aisle grating over orange glow, coolant pipes, exhaust; red haze horizon |

Track names, per league in order: Edge: **Cold Aisle**, **Substation
Sprint**, **Exhaust Ridge**. Spine: **Fiber Backbone**, **Rack Row 7**,
**Tape Vault**. Core: **Hot Aisle**, **Kernel Ring**, **Weights Loop**.

Track features, each the F-Zero equivalent in datacenter words. Every
feature is a tile attribute (section 7) and a tile look the generator
paints:

| Feature | F-Zero | What it does |
|---|---|---|
| Rail | guard rail | bounce back, lose speed, thermal damage scaled by impact |
| Open edge | no rail | leaving the track is a fall, which is a crash (section 5.4) |
| Overclock pad | dash plate | +speed for 60 ticks, free |
| Throttled zone | rough / magnet | top speed halved while on it (thermal throttling) |
| Cold aisle | pit strip | thermal bar refills while on it |
| Hot spot | mine | thermal damage, knock sideways |
| Hop | jump plate | the machine leaves the floor for 40 ticks (sprite rises, no steering, shadow stays) |

Machines, player first. All hover machines, named in the HUD by the
short name:

| Short | Full name | Role | Character |
|---|---|---|---|
| SNOUTY | Snouty's **Anteater** | player | balanced; Snouty's head shows from the cockpit |
| ARGMAX | Argmax | rival 1 | fastest straight line, slow turning |
| DROPOUT | Dropout | rival 2 | erratic lane changes, average speed |
| BACKPROP | Backprop | rival 3 | best cornering, lower top speed |
| OVERFIT | Overfit | rival 4 | hugs the ideal line exactly, brittle to contact |
| batch | batch jobs | traffic | six grey machines that drive the line at low speed and never rank |

Race flavour text uses the theme sparingly: the countdown is
`PROVISIONING` then `3 2 1` then `DEPLOY`; the finish is `COMMITTED`; a
crash message names the cause as in Snouty vs. the Bugs (`THERMAL
SHUTDOWN`, `SEGMENT FAULT` for a fall off the edge, `COLLISION` for a
machine hit); retiring is `JOB KILLED`. Speed is shown in `Tb/s`.

## 4. Controls

| Input | Race | Menus |
|---|---|---|
| Left / Right | steer | move |
| A (hold) | accelerate | confirm |
| Down | brake; with Left/Right, tight turn (less grip, faster yaw) | |
| Up | Overclock (boost): +speed 90 ticks, costs 25% of the thermal bar, needs 10% left | |
| B (hold) | rewind while the snapshot bar lasts (section 5.4) | back |
| Start | pause menu (resume, restart race, quit to menu, sound) | |
| Select | toggle the minimap size | |

Steering rate scales with speed: full rate below 40% of top speed,
falling to 55% of it at top speed, so straights are stable and corners
need the tight turn or the brake. There is no spin attack; the badge has
no spare button and it is not needed for the show.

## 5. Driving model

Fixed point throughout: positions in 16.16 world pixels (one world pixel
is one floor texel), angles as `u16` turns (65536 per revolution) with a
256-entry sine table, velocities in 16.16 pixels per tick.

### 5.1 Hover physics

The machine has a heading and a velocity vector that are not the same;
the gap is the drift. Per tick:

1. Thrust: `v += heading_dir * accel` while A is held, `accel` 0.04 px/tick^2.
   Brake: `v -= v * 0.03`.
2. Drag toward the top speed: `v *= 1 - drag`, `drag` 0.011 untuned, which
   puts the terminal speed near 3.6 px/tick (216 px/s). Overclock raises
   the thrust and the cap for its duration, terminal near 5.2 px/tick.
3. Grip: decompose `v` into along-heading and lateral parts; the lateral
   part is multiplied by `grip` (0.85 normal, 0.94 in a tight turn, 0.97
   on a throttled zone). This is what makes corners slide.
4. Yaw: Left/Right change the heading by `steer_rate(speed)`, 190 turns
   per tick at low speed; tight turn multiplies by 1.6.
5. Move, then resolve tile attributes under the four corner points of the
   machine's 24x12 world-pixel footprint (section 7), then machine against
   machine (5.3).

Lap length is about 4,000 to 5,000 world pixels, so a clean lap is 20 to
25 s and a 3-lap race about 70 s, which is the right length for a booth.
All constants are knobs in one `tuning.zig`; the values above are the M1
starting point and the Adrian play test is where they are set.

### 5.2 Thermal (the power bar)

A bar from 0 to 1000. Rail hits cost `impact_speed * 40`, a hot spot 150,
a machine collision 60 each, Overclock 250. Cold aisles refill 8 per
tick. At 0 the machine melts down: a crash (5.4). The bar starts full
each race and does not regenerate elsewhere, so Overclock is a bet on
finding a cold aisle.

### 5.3 Rivals and traffic

Rivals follow the centerline table (section 7) with a per-rival lane
offset and a speed target from the curvature of the next 12 samples,
braking into corners and accelerating out. Each has a `Character` struct
(top speed, grip, steer rate, lane wander period, aggression) that gives
the table in section 3. Rubber band: a rival's speed target scales by
`1 + clamp((player_progress - rival_progress) / 1500, -0.08, 0.10)`,
i.e. rivals far ahead ease off a little and rivals behind push a little,
bounded so a good lap still wins. Traffic machines drive the line at 55%
speed, two per lap sector, and are obstacles, not competitors.

Machine against machine: circles of radius 10 world pixels; on overlap
both are pushed apart along the contact normal, exchange 30% of their
relative normal velocity, and take thermal damage. The player pushing a
rival into a rail is allowed and is the one dirty tactic the game has.

Everything above runs from the world's PRNG, so it is deterministic and
rewinds (5.4).

### 5.4 Rewind: the snapshot bar

The Antithesis mechanic, the same design as Snouty vs. the Bugs 5.1 and
5.2 with one resource instead of two:

- The snapshot bar holds 180 ticks (3 s) of rewind. It refills at 1 tick
  of rewind per 10 game ticks and fills completely when the player
  crosses the start line. It is meta-state, outside the world, so a
  rewind cannot refund itself.
- Hold B: the world plays backwards at 2 ticks per frame while the bar
  drains 2 per frame; the frame is dimmed with every other scanline
  black, `<<` blinks in the HUD, inputs other than B are ignored. Release
  B (or empty the bar) and the race resumes from that tick with 30 ticks
  of collision immunity. Rivals, traffic, the clock and the rank all go
  back too; that is the point, and it is honest the same way the bugs
  cart's score rewind is.
- Crash (fall, meltdown, or a hop landing off the track): hit-stop for 20
  ticks with the cause named on a bar, then an automatic rewind of 120
  ticks if the snapshot bar holds at least 90, taking what it holds down
  to 90 ticks' worth; the bar then reads what is left. With less than 90,
  the machine is destroyed, `JOB KILLED`, and the race ends on the
  results screen with `RETIRED` in the rank slot.
- Attract mode records the autopilot's input the same way, so demo races
  show rewinds, which sells the mechanic to passers-by.

## 6. Rendering

### 6.1 Screen layout

```
y   0..31   horizon strip (parallax, league art), HUD text drawn over it
y  32       horizon row (camera pitch is fixed; the row shifts up to 4 px on a hop)
y  33..127  floor: 95 rows of Mode 7, nearest rows at the bottom
            player machine sprite centred on x 80, feet at y 118
            minimap bottom-right 32x32 (Select toggles 48x48), thermal and
            snapshot bars bottom-left, speed above them
```

### 6.2 The floor

Per frame, compute for each floor row `y` the world-space distance
`d(y) = cam_height * focal / (y - horizon)` and from it the row's
start point and per-pixel step in world space, rotated by the camera yaw:
four 16.16 values per row, 95 rows, one small table. The framebuffer is
column-major, so the inner loop runs down a column: for column `x` and
row `y`, `wx = row_x0[y] + x * row_dx[y]` and the same for `wy`, two
multiply-accumulates, then `tile = map[(wy >> 19) & 127][(wx >> 19) & 127]`
(8x8 tiles, 128x128 map, world 1024x1024 wrapping), `index =
tiles[tile][(wy >> 16) & 7][(wx >> 16) & 7]`, `pixel = palette[fog[y]][index]`.
Eight to twelve instructions per pixel, about 15,200 pixels: 1.0 to 1.4 ms.
The alternative (row inner loop, then transpose) is a fallback if column
writes with a 256-byte stride turn out to cost more on this SRAM than
the model says (section 18).

Fog: four palette banks (256 colours x 2 bytes x 4 = 2 KB) blended toward
the league's horizon colour, chosen per row. The 6 rows under the horizon
sample the texture far too sparsely and are drawn from the densest fog
bank, which hides the aliasing the SNES also hid.

Camera: 20 world pixels behind the machine and 12 above the floor, yaw
following the heading with a lag of 1/8 per tick so corners swing. Rail
hits add a 4-tick shake (horizon row and column offset jitter of 1 px).

### 6.3 Sprites

The upstream `blit` has no scaling, so the cart has its own scaled blit:
nearest-neighbour, 4-bit indexed source with colour 0 transparent, source
step in 8.8 fixed point, clipped to the floor region, with a per-sprite
palette (rivals and traffic share one shape set and differ only in
palette). Sprites are depth-sorted back to front; a sprite below the
horizon row is scaled by `d_screen / d_sprite` from the same `d(y)`
table, so sprites sit on the floor at the right size without a Z-buffer.

| Sprite | Base size | Frames |
|---|---|---|
| Anteater (player) | 40x24 | straight, lean left, lean right, hop (shadow separate 32x6) |
| Rival/traffic machine | 32x16 | 5 yaw views (rear, rear-quarter L/R, side L/R), hop |
| Snouty cockpit head | 12x8 | 2 (normal, hit) drawn into the Anteater frames by the asset tool |
| Hot spot, pad glyphs | 8x8 | floor-painted by the generator, not sprites |
| Effects | 16x16 | spark burst 4 frames, exhaust flame 2 frames |

Snouty is the study05 rig from `snouty-art` where a head is needed; the
machines are code-drawn vector shapes rendered by `tools/prepare_assets.py`
at the 5 yaws on the 15-colour palette, counting as final per the art
policy. Rendering at 40x24 keeps a sprite under 1 K pixels; ten machines
on screen is under 0.2 ms.

### 6.4 Horizon and HUD

The horizon strip is a 512x32 4-bit image per league (8 KB), scrolled by
`yaw * 512 / 65536` and drawn with a 2-layer parallax where the back layer
scrolls at half rate (two 256-wide strips, 4 KB each, so the same cost).
LED blink: every 8 ticks the strip's palette entry for "LED green" swaps
with "LED off" for the 2-colour blink without touching pixels.

HUD in the 8x8 font: top-left `LAP 2/3`, top-centre race clock
`1'12"43`, top-right rank `3RD`; bottom-left the speed `287 Tb/s`, the
thermal bar (orange, 40x4) and the snapshot bar (cyan, 40x4) with `<<`
beside it during a rewind; bottom-right the minimap: the track outline
drawn once per race from the centerline table into an off-screen 48x48
1-bit buffer, machines as 2x2 dots, player in white. Messages (crash
cause, `DEPLOY`, `COMMITTED`, `FINAL LAP`) go on a centred bar at y 56,
as in the bugs cart.

## 7. Tracks and the generator

A track is a committed text file in `cart/src/tracks/<name>.track`
describing a closed centerline:

```
league edge          # picks tileset and horizon art
width 64             # default half width in world pixels
# x    y    half   features                    (control points, Catmull-Rom)
 200  512   64
 420  300   48     rail
 700  260   40     rail
 900  500   64     pad          # an overclock pad across the lane here
 820  800   80     open         # no rail on this segment
 500  880   64     cold
 260  760   56     hot:3        # three hot spots scattered on this segment
```

`tools/build_tracks.py` (host, Python, Pillow; same style as the other
carts' `prepare_assets.py`) rasterizes it to:

- `map.bin`: 128x128 tile indices, with the track surface, edges, rails,
  feature tiles and the background pattern of the league (rack rows,
  fans, fiber bundles are procedural pattern painters seeded per track),
  RLE-compressed (the background repeats; expect 3 to 6 KB per track).
- `attr.bin`: 256 bytes, one attribute per tile index: surface, rail,
  open edge, pad, throttled, cold, hot, hop, start line, sector 1, 2.
- `center.bin`: 256 samples along the centerline, each `x, y` (u16),
  tangent (u16 turn), half width (u8), 1.5 KB. Used by the AI, by
  progress and rank (a machine's progress is its nearest sample index
  plus lap times 256), by lap counting (start line crossing with sector
  1 and 2 both seen since the last lap), and by the minimap.
- `preview.png`: the whole map and the centerline, 1:1, for review in
  `docs/`.

The tilesets (one per league, 256 tiles of 8x8 at 8 bpp, 16 KB each) are
also code-drawn by the tool from a tile vocabulary (surface variants,
edge pieces for the 16 edge cases, rail pieces, feature glyphs,
background pattern tiles). Edge and rail tiles are auto-tiled by the
rasterizer from the surface mask. Map, attributes and centerline are
embedded as `[]const u8` via `@embedFile` of the generated files; no
comptime work (the Mac OOM rule).

Collision is a lookup: `attr[map[wy >> 3][wx >> 3]]` at each of the
machine's four corner points, resolved as the strongest attribute found
(rail over edge over surface features). Rails push the machine back along
the surface normal estimated from which corners are inside.

## 8. Game flow

```
Splash (2 s, Snouty face, title)  ->  Title ("Press Start", 10 s idle -> Attract)
Attract: an AI race with the autopilot driving Snouty, any button -> Title
Title -> Menu: Quick Race | Grand Prix | Sound: off | (Core league when built)
Quick Race: pick league + track -> Countdown -> Race -> Results -> Menu
Grand Prix: the league's 3 tracks in order, points 9/6/4/3/2 for the top
            five, standings between tracks, champion screen -> Menu
Race: Start -> Pause (Resume | Restart | Quit | Sound)
```

Races are 3 laps. The results screen shows the rank, the race time, the
best lap, the rewinds used and the thermal remaining, then `COMMITTED`.
The splash is a Snouty face, not the Iris mark (that is for emulators).
Best lap per track is kept in RAM only; there is no save to flash (keep
the cart simple; a decision for Adrian, section 17).

## 9. Audio

The toggle only. With sound on: a countdown beep, the `DEPLOY` tone, a
short rail-hit click and a two-note finish. All through the `tone`
import directly (the simulator tone-shim rule, `docs/SOUND.md`). No
engine sound: the speaker policy and the one-voice limit make it noise.

## 10. Architecture

Modules under `cart/src/`:

- `main.zig`: `start`, `update`, the state machine, wasm shims
  (`present_wasm`, `read_controls`).
- `world.zig`: the one plain `World` struct: 11 machines (position,
  velocity, heading, thermal, hop timer, overclock timer, lap, sector
  flags, progress), race clock, PRNG, hit-stop timer, message state. No
  pointers; a snapshot is a struct copy. About 1 KB.
- `sim.zig`: `simulate(world, controls)` one tick: physics, attributes,
  machine collisions, AI, laps, rank.
- `history.zig`: keyframe ring (8 copies every 60 ticks, 8 KB) and input
  log (512 `u16`), `restore(tick)` as in the bugs cart (newest keyframe
  at or before, replay logged input up to 59 ticks). Rewind of 180 ticks
  needs 240 of coverage, which 5 keyframes give.
- `render.zig`: floor tables and the column loop, scaled blit, horizon,
  shake; `hud.zig`: text, bars, minimap, messages.
- `track.zig`: decompress the selected map into RAM at race start, the
  attribute and centerline accessors; `ai.zig`: rival driving and the
  autopilot (the player's AI for attract mode uses the same code with
  the SNOUTY character).
- `tuning.zig`: every constant from section 5 in one place.
- `assets/gen/`: the generated tracks, tilesets, strips and sprite sheets,
  committed; `tools/build_tracks.py`, `tools/prepare_assets.py`.

Determinism rules as in the bugs and snoutenstein carts: no `rand()`, no
clock, no floats inside `simulate`; rendering reads the world and never
writes it.

## 11. Performance budget

Per `update()` at 150 MHz, raw estimate; badge-bench calibrated numbers
replace these from M0 onwards.

| Piece | Estimate |
|---|---|
| Floor, 160x95, 10 cycles/pixel | 1.0 to 1.4 ms |
| Horizon, 160x32 two layers | 0.1 ms |
| Sprites, 11 machines + effects, under 10 K pixels | 0.2 ms |
| HUD, minimap, text | 0.3 ms |
| `simulate` (physics, 11 machines, AI) | under 0.1 ms |
| Rewind frame (2 simulate ticks, dimmed draw) | +0.1 ms |
| Worst case total | about 2.5 ms, 15% of budget |

Even if the calibrated model lands twice the raw estimate, as it did for
reflections' FP-heavy loops, the cart sits under 30% of budget. The
headroom goes to the polish in M4 (hills, 6.5) and to keeping 60 fps
unconditional.

## 12. Verification

- Host tests (`zig build test`): fixed-point trig and table accuracy;
  attribute lookup at known map points; `simulate` twice from one state
  equals byte-for-byte; `restore(t)` equals the direct state at `t` for
  every `t` in a 600-tick run; lap counting across the start line with
  and without sectors; **every committed track is completable**: the
  autopilot drives 3 laps on each track without a crash and under a
  time bound (this is the content gate that makes generated tracks safe).
- `zig build check-float`: no soft-float calls in the firmware.
- Headless `preview.mjs` runs with input scripts in `tools/scripts/`:
  a title-to-race script, a rewind script, a crash script; the PNGs and
  `frames.json` export checks confirm the HUD values.
- badge-bench before and after every milestone, worst frame recorded in
  `PLAN.md`; the race stress scene is a hop over traffic with four
  rivals on screen on the Spine league's busiest track.
- Review GIFs in `docs/` per milestone; Adrian plays in the simulator and
  on the badge from main (the merge-when-ready rule).

## 13. Memory

RAM cart. `.text` + `.rodata`: code about 60 KB; two tilesets 32 KB; two
league horizon pairs 24 KB; sprites about 12 KB; six compressed maps about
30 KB; centerlines and attributes 11 KB; total about 170 KB. `.bss`: the
decompressed map 16 KB, the history 9 KB, the minimap buffer and world
under 3 KB: about 28 KB. Around 200 KB against the 307 KB window with 32
KB of stack, which leaves room for the Core league (16 KB tiles + 12 KB
horizon + 15 KB maps). If M5 pushes past the window the XIP build is the
route, as for the emulator carts.

## 14. Repo layout

`carts/snouty-zero/` with `cart/src/*.zig`, `cart/src/tracks/*.track`,
`cart/build/convert_gfx.zig` (per-cart copy), `assets/gen/`, `tools/`,
`docs/RUNNING.md`, `PLAN.md`, `SPEC.md`, `ASSETS.md`, `build.zig` with
`pub fn add`; root `build.zig` lists it; `badge-bench/carts/snouty-zero.toml`.
Binary `snouty-zero`.

## 15. What makes it ours

Beyond the theme: the rewind that takes the whole race back, the
thermal economy where Overclock is paid for in cooling, generated tracks
from a ten-line text file, and (M4) a trick Mode 7 hardware could not do:
a per-row vertical offset table that bends the floor into gentle hills
and dips where the track file asks for them, which is the Road Rash
trick applied to an affine floor. Kept out on purpose: replay and ghosts
(parked in `docs/REPLAY.md`), badge-to-badge link, engine audio.

## 16. Milestones

Tags `snouty-zero/mN`, a review GIF in `docs/`, pull-and-run notes, and
badge-bench numbers in `PLAN.md`; Opus agents per track in worktrees with
disjoint files where a milestone splits.

- **M0 Floor**: cart scaffold in the root build, badge-bench toml, the
  floor renderer over a generated test map and the Edge tileset, free
  camera on the d-pad, horizon strip, fog banks. Done when: 60 fps in the
  calibrated bench with the worst frame recorded, GIF, section 18 facts
  answered in `PLAN.md`.
- **M1 Drive**: `build_tracks.py` with Cold Aisle, physics, attributes,
  rails, laps, the Anteater sprite with Snouty, countdown, basic HUD.
  Done when: a 3-lap solo race is drivable in the simulator and the lap
  test passes.
- **M2 Race**: rivals with characters, traffic, machine collisions,
  thermal, Overclock, pads, zones, hot spots, hop, rank, minimap,
  results, attract autopilot, the "every track completable" test. Done
  when: a full race against the four rivals runs start to results.
- **M3 Rewind and content**: `World`/`history`, hold-B rewind, crash
  handling and messages, splash, title, menu, Quick Race and Grand
  Prix, six tracks across Edge and Spine with their league art, pause
  menu, sound toggle. Done when: the determinism and restore tests pass
  and all six tracks pass the completable test.
- **M4 Perf and polish**: bench profile and fast paths, hills, shake,
  effects, tuning pass from Adrian's play notes, XIP build checked in
  the bench. Done when: merged to main, tagged, the review GIF posted.
- **M5 Stretch** (pick with Adrian): the Core league (3 tracks, art,
  haze); a machine select (drive a rival's character); best laps saved
  to badge flash.

## 17. Decisions (taken by default, 2026-10-01)

1. Name: `snouty-zero`, title **SNOUTY ZERO**, subtitle `ECUMENOPOLIS
   GRAND PRIX`. Alternatives: Snouty GP, Snouty Hyperscale.
2. Controls as section 4: A accelerate, Down brake and tight turn, Up
   Overclock, B rewind, Select minimap size. Alternative: B brake and
   rewind on Select, which frees Down for lean but makes the rewind a
   tap-to-toggle.
3. One rewind resource (the snapshot bar) covering both hold-B and crash
   rewinds, rather than the bugs cart's stock plus fuel.
4. 3 laps, 4 named rivals plus 6 traffic, 6 tracks at M3 and the Core
   league as M5 stretch.
5. Overclock costs thermal (F-Zero X style) instead of one boost per lap
   (SNES style).
6. No flash saves; best laps live for the session.
7. RAM cart with compressed maps; XIP build kept in step but not the
   primary.
8. Hover machines are code-drawn vector shapes; Snouty is the study05 rig
   head in the Anteater's cockpit. The Anteater is the flyover anteater's
   cousin, not the same sprite.
9. Speed unit `Tb/s`; countdown `PROVISIONING / 3 / 2 / 1 / DEPLOY`.

## 18. Facts to check in M0

- Column-major floor writes at a 256-byte stride versus a row scratch
  buffer plus transpose: measure both in the calibrated bench (the SRAM
  bank striping and LCD-DMA contention terms are the unknowns).
- The real per-pixel cycle count of the column loop with two MLAs and
  three dependent loads; whether splitting the tile lookup into a per-tile
  pointer cache helps.
- Tile fetch cost in the XIP build (flash reads) to know whether the XIP
  variant needs the tileset copied to RAM at start.
- The `d(y)` table's precision near the horizon in 16.16 and whether the
  far 6 rows need 8.24.
- Confirm the sprite scale from `d(y)` lines up with the floor at the
  machine's footprint for all 95 rows (one visual test map with a grid).

## Status

- 2026-10-01: spec drafted from the F-Zero feasibility discussion and
  Adrian's setting (a planet-sized AI datacenter ecumenopolis). Nothing
  built; `PLAN.md` comes with M0.
