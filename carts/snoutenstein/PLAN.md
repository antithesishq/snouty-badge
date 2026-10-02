# Plan: Snoutenstein 3D

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
`SPEC.md` is the design; this file is the execution plan per milestone and
the contracts the parallel tracks build against. Status at the bottom.

## M0 Scaffold (2026-09-26)

Toolchain copied from `snouty-bugs` (`build.zig`, converter, preview
harness, simulator shims). Contract modules written by the lead so every
track compiles from minute one: `fixed.zig` (16.16, u16 angles, comptime
sin table), `state.zig` (`GameState`, 1,368 bytes), `levels.zig` (comptime
ASCII parser, cell encoding below), `sim.zig` stub (turn/walk, no
collision), `render/view.zig` stub (horizon fill), `render/hud.zig` (title
card, debug bar), `main.zig` (modes TITLE/PLAYING/PAUSED, render timing
via `micros_since_boot`, debug exports). Stand-in sheets at manifest sizes
from `tools/placeholders_m0.py`. `zig build` works; ELF text 10.7 KB.

### Cell encoding (`levels.zig`, final)

`Level.cells[y][x]`, 64x64, row-major, y down, everything outside the
drawn map is wall:

| Value    | Meaning                                                   |
|----------|-----------------------------------------------------------|
| 0        | floor                                                     |
| 1..8     | wall, `walls.png` cell `value - 1`                        |
| 9..63    | reserved for more wall textures                           |
| 64..127  | door number `value - 64` into `level.doors[]`             |

`DoorDef { x, y, kind (plain/coral/iris/gold/exit), vertical }`. `vertical`
means the panel runs north-south (the passage is east-west); it is derived
from the neighbours at parse time. Door runtime state is
`GameState.doors[i]` (`open` 0..255, `timer`, `phase`), same index.
Pickups and enemies are `level.pickups[]` / `level.enemies[]`; pickup `i`
is present while bit `i` of `GameState.pickups` is set; enemy `i` occupies
`GameState.enemies[i]`.

Coordinates: cell `(x, y)` spans `[x, x+1) x [y, y+1)`; the player starts
at the cell centre. Angle 0 faces +x (east on the map as drawn), angles
increase toward +y (south on the map), so 16,384 faces down the page.

## M1 Raycaster on hardware (started 2026-09-26)

Goal: textured, shaded walls and doors at 60 Hz on the badge, with the
render time visible in the debug bar so the gate is one photo. The sim
track brings real movement and doors so the view has something to show.
Enemies, weapons, sprites and the real HUD are M2/M3.

### Tracks (parallel, disjoint files; agents do not commit)

| Track | Owner       | Files                                                                                  |
|-------|-------------|----------------------------------------------------------------------------------------|
| A render | Opus agent | `cart/src/render/view.zig`, new `render/raycast.zig`, `render/floor.zig`, `render/textures.zig` |
| B sim    | Opus agent | `cart/src/sim.zig`, `cart/src/fixed.zig` (additions only), `cart/src/state.zig` (additions only) |
| C art+tools | Opus agent | `tools/prepare_assets.py`, `assets/gen/*.png` (same sizes), `ASSETS.md`, `tools/scripts/m1_*.json`, `docs/RUNNING.md` section 5 |
| D import | Opus agent | `tools/import_wolf.py`, `tools/test_import_wolf.py`, `cart/src/levels/wolf_walls.json`, `cart/src/levels/wolf_*.txt` |
| lead     | this session | `main.zig`, `levels.zig`, `render/hud.zig`, `build.zig`, `PLAN.md`, `SPEC.md` status, `docs/*.gif`, commits, tag |

### Contract: render (track A)

- `view.init()` is called once from `start()`: unpack `gfx.walls` (8 cells
  of 32x32) and `gfx.doors` (5 cells) into column-major `u8` arrays
  (`tex[id][x][y]`), and build the shade palettes.
- `view.draw(s: *const GameState, level: *const Level)` fully overwrites
  y 0..103 of every column. Reads only `s.player.{x,y,angle}`,
  `s.doors[i].open`, `level.cell(x, y)`, `Level.is_wall/is_door/door_index`,
  `level.doors[i]`. Converts fixed to f32 with `fixed.to_f32`.
- FOV 66 degrees, 160 rays, DDA over the grid, perpendicular distance,
  slice height `104 / dist`, range cap 24 cells (fill the slice with the
  darkest shade beyond it). Wall `x` faces use palette set 0 (lit), `y`
  faces set 1 (dark); distance > 6 cells goes to set 2, > 10 to set 3.
  Sets 4 (rewind: Iris tint) and 5 (hurt: red tint) are built too but
  unused until M4; `pub var shade_override: ?u8` selects one for the
  whole frame when set.
- Doors: the panel lies on the cell midline (x + 0.5 for `vertical`,
  y + 0.5 otherwise) and slides along its own axis by `open / 255` cells
  toward +y (vertical) or +x (horizontal); a ray that hits the midline in
  the open part continues the DDA. Door texture = `doors.png` cell
  `@intFromEnum(kind)`; doors use the wall shading rules.
- Floor y 52..103 and ceiling y 0..51 are filled per column from two
  comptime 52-entry `Pixel` tables (darker toward the horizon).
- Exports `pub var depth: [160]f32` (perpendicular wall distance per
  column, for M2 sprites) and `pub const view_h = 104`.
- Hot loop rules: no `PackedIntSlice.get`, no per-pixel division or
  branch on texture bits; one table lookup and one 16-bit store per pixel.
  Aim for under 3,000 us on hardware for the full view (the debug bar shows
  the measured number; on wasm the number is meaningless but must exist).
- Textures may be read from `gfx` only in `init()`.

### Contract: sim (track B)

`sim.step(s, level, buttons)` in 16.16 fixed point, host-testable
(`zig test cart/src/sim.zig`), covering:

- Turn 455 units/tick (left/right), walk 0.045 cells/tick forward,
  0.03 back. Player radius 0.25. Axis-separated movement with sliding:
  move x, resolve against solid cells overlapping the circle's bounding
  box, then y. Solid: walls, and doors with `open < 255`... except that a
  door counts as passable once `open >= 192` (Wolf3D lets you through
  a three-quarter-open door).
- Doors: when a move is blocked by a door cell and the door is closed or
  closing, it starts opening if unlocked (`phase` 1). Opening takes 30
  ticks (`open` += 9 per tick, clamp 255), then `phase` 2 with `timer`
  180; when the timer hits 0 and no player/enemy circle overlaps the
  cell, `phase` 3 closes at the same rate, back to 0. Locked doors
  (coral/iris/gold) need bit 0/1/2 of `player.keys`; a blocked attempt
  without the key sets `s.last_locked = kind` (new field, u8, 0 = none,
  cleared each tick) so the HUD can flash. Exit door: opens like plain;
  when the player's centre enters the cell, `s.finished = true`.
- Pickups: on the tick the player's centre enters a pickup's cell and the
  bit is set: keys set `player.keys` bits; hotfix hp +25 (max 100);
  charge `ammo_zapper` +8 (max 99); spray can `ammo_spray` +5 (max 30)
  and switches `weapon` to `.spray` on first pickup; battery
  `rewind_meter` += 180 (max 600). Clear the bit.
- Rewind meter regen: `rewind_regen` counts ticks; every 6 ticks
  `rewind_meter` += 1 up to 600 (that is 1 s per 6 s).
- `pub fn hash(s: *const GameState) u32`: FNV-1a over `std.mem.asBytes(s)`.
  `GameState` must therefore have no padding garbage: give every field a
  default and `init` must assign the whole struct (it does).
- Enemies, projectiles, weapons: untouched in M1 (leave the fields).
- Tests: walking into a wall stops at radius; sliding along a wall keeps
  the tangential speed; a door opens over 30 ticks and is passable at
  192; a locked door does not open without the key and does with it;
  pickups toggle bits and clamp; 600 ticks of scripted input produce the
  same `hash` twice.

New `state.zig` fields are allowed (append, with defaults). `fixed.zig`
may gain helpers (`floor`, `ceil`, `hypot`-free distance compare, etc.).

### Contract: art and tools (track C)

- `tools/prepare_assets.py --placeholders` draws every sheet in SPEC.md
  section 14 at its exact size as readable stand-ins (walls: eight
  clearly different 32x32 patterns in the server-room theme with a
  Wolf3D-like light/dark structure baked into the design, not the
  palette; doors: five variants with a visible colored lock plate; bugs
  as silhouettes per kind; weapons; face; pickups; hud; title), and
  `--study DIR` ingests a delivered art study (mirror the `snouty-bugs`
  script's structure and validation: exact sizes, cell grid, <= 15
  opaque colors + key, 1 px border, no #FF00FF in source).
  `walls.png` and `doors.png` are opaque (16 colors allowed, no key).
- `ASSETS.md`: the brief for the pixel-art agent, same structure as
  `../snouty-bugs/ASSETS.md` (attachments, style, palette rules, cells
  and anchors, readability rules, animation notes, the order, delivery
  format, what not to do), adapted to first-person art: sprites always
  face the camera; textures must tile vertically and horizontally only
  where noted; weapon sprites are seen from behind/below; the portrait
  has nine named frames; the 32x32 texel-to-pixel argument from SPEC.md
  section 5 explained so the artist draws at native size.
- `tools/scripts/m1_walk.json` (start, walk the long corridor, turn),
  `m1_doors.json` (walk into the plain door at (7,4), wait, pass),
  `m1_pause.json`. `docs/RUNNING.md` section 5 lists them.

### Contract: Wolf3D import (track D)

`tools/import_wolf.py MAPHEAD GAMEMAPS --level N [--difficulty easy|medium|hard]
--walls cart/src/levels/wolf_walls.json --out FILE.txt` per SPEC.md 6.1:
RLEW + Carmack decompression, plane 0/1 code tables from `WL_GAME.C`,
mapping table in SPEC.md 6.1, output in our ASCII format (the `S` start
is followed by its facing arrow, which occupies the next cell; the
importer must make sure that cell is floor or move the start). Enemy
letters: `a` gnat, `w` wasp, `b` beetle, `s` spider, `H` boss. Pool
limits from `state.zig` (40 enemies, 64 doors, 256 pickups): warn and
thin. `tools/test_import_wolf.py`: builds a tiny synthetic
MAPHEAD/GAMEMAPS pair (Carmack- and RLEW-compressed by a reference
encoder in the test) and checks the ASCII output. If the shareware
`wolf3d14.zip` can be fetched from a public mirror, convert E1M1 to
`cart/src/levels/wolf_e1m1.txt` and report the dimensions and counts;
never add `.WL1` files to the repo (they are gitignored).

### Verification for M1

```
zig build && size -A zig-out/firmware/snoutenstein.elf | grep -E "^\.text|^\.data|^\.bss"
zig test cart/src/sim.zig && zig test cart/src/levels.zig
node ../../tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 900 --every 6 --out out/ \
  --script tools/scripts/m1_walk.json \
  --dump-exports debug_mode,debug_tick,debug_px,debug_py,debug_angle,debug_render_us \
  --expect "debug_mode == 1" --expect "debug_px > 393216"
python3 ../../tools/make_gif.py out/ docs/preview_m1.gif --scale 3 --ms 100
```

Gate (Adrian, on hardware): flash the UF2, press A, walk the long
corridor at the bottom of the test level, photograph the debug bar. FPS
overlay (joystick click) must read 60 and RENDER must stay under 8,000 us.

## M2 World (started 2026-09-27)

Goal: the game loop without enemies that fight back. Sprites (pickups,
standing enemies, projectiles) drawn as depth-clipped billboards, the real
status bar with the portrait, the first-person weapon, swatter and zapper
(and spray, since it is the same hitscan code) that hurt and kill the
standing bugs, exit door -> intermission -> next level -> victory. The
rewind core (`rewind.zig`) starts early as a host-tested module because it
is pure sim-side code; wiring B-hold into `main.zig` stays M4. Nothing here
depends on the M1 hardware gate: if the gate forces the 80-ray fallback,
only `view.zig`'s column loop changes.

### Tracks (parallel, disjoint files; agents do not commit)

| Track | Owner       | Files                                                                                  |
|-------|-------------|----------------------------------------------------------------------------------------|
| A sprites | Opus agent | new `cart/src/render/sprites.zig`, `render/view.zig` (call sprites after walls), `render/textures.zig` (additions: sprite palettes) |
| B combat  | Opus agent | `cart/src/sim.zig`, `state.zig` (append only), `fixed.zig` (additions), new `cart/src/combat.zig` if wanted |
| C hud     | Opus agent | `cart/src/render/hud.zig`, new `render/blit.zig`, new `render/weapon.zig`, new `render/portrait.zig` if wanted |
| D rewind  | Opus agent | new `cart/src/rewind.zig` (pure, host tests), `tools/check_determinism.mjs` stub is M4 |
| lead      | this session | `main.zig`, `levels.zig`, `levels/test.txt`, `tools/scripts/m2_*.json`, `tools/check.sh`, `PLAN.md`, `SPEC.md` status, `docs/*.gif`, commits, tag |

Concurrency note: all tracks share one working tree. A `zig build` may
fail in another track's half-edited file; wait and retry, and lean on
`zig test` for the sim-side modules. `zig test cart/src/sim.zig` and
`zig test cart/src/rewind.zig` never need cart-api.

### Contract: sprites (track A)

- `sprites.draw(s: *const GameState, level: *const Level, px: f32, py: f32,
  dx: f32, dy: f32)` is called by `view.draw` after the wall pass; it reads
  `view.depth` (perpendicular wall distance per column) and clips every
  sprite column where `z >= depth[x]`. `view.draw`'s signature is unchanged.
- Camera transform as in Lode's tutorial: `rel = (sx - px, sy - py)`,
  `z = rel . dir` (perpendicular distance), `tx = rel . plane / tan(fov/2)`
  normalised so screen x = `80 * (1 + tx / z)`. Skip sprites with `z < 0.2`
  or `z > raycast.range` or fully off-screen. Sort visible sprites back to
  front (insertion sort over a fixed 64-slot scratch array; drop the
  farthest when over).
- Screen height of a sprite with world size `size` (cells) is
  `104 * size / z`; width the same. Anchors (confirms ASSETS.md section 10):
  enemies size 1.0, bottom on the floor line (`52 + 52 / z`), so they fill
  floor to ceiling like walls; boss size 1.5, bottom-anchored (its top
  clips); spider size 1.0 top-anchored at the ceiling line (`52 - 52 / z`);
  pickups size 0.5, bottom on the floor; projectiles size 0.25, centred on
  the horizon (y 52).
- Sources: enemies `gfx.bug_<kind>` cell `e.frame` (the sim owns `frame`;
  sheet order walk, walk, attack, pain, death x3, boss +1 flicker); every
  enemy is drawn whatever its `state`, including `.dead` (corpse frame is
  whatever `frame` says) but not when `hp == 0 and state == .dead and
  frame == 0` (an unused slot: `level.enemies.len` bounds the loop anyway,
  use that). Pickups `gfx.pickups` cell `@intFromEnum(kind)` for each
  `level.pickups[i]` with the present bit set. Projectiles `gfx.projectiles`
  cell `0/1` (spit, alternate every 4 ticks) or `2/3` (web) for `kind 1/2`.
- Texels: never `PackedIntSlice.get` per pixel. Read nibbles straight from
  `sheet.indices.bytes` (`bytes[i >> 1]`, low nibble = even index; verify
  the order once against `indices.get` in a test or comptime assert).
  Per column: fixed source column `u`, step `v` in 16.16. Index 0 is
  transparent. `e.flash > 0` draws every opaque texel Anti-White.
- Palettes: per sheet `[16]Pixel` normal plus rewind and hurt tints built
  in `textures.init()` with its existing `tint` helper; pick by
  `view.shade_override` (null/0..3 -> normal, 4 -> rewind, 5 -> hurt).
  Sprites are not distance-shaded (Wolf3D did not either).
- Budget: no new `.bss` beyond palettes and the 64-slot scratch; the sheets
  stay packed in `.text`.
- Verification: `zig build`, then `preview.mjs --script tools/scripts/m1_walk.json`
  frames show the pickups in the corridor rooms; a frame looking at the gnat
  from the start (lead adds one at (6,3), see below) shows a 32 px-ish sprite
  scaled down with distance and correctly hidden behind a wall when walking
  past the doorway. Export `pub var drawn: u32` (sprites drawn last frame)
  for `debug_sprites`.

### Contract: combat (track B)

- Enemy stats table `pub const enemy_stats: [5]EnemyStats` (hp per SPEC.md
  section 8, `radius` 0.3 cells for hit tests) in `state.zig` or `sim.zig`.
  `init` gives enemies their real `hp` and state `.idle` (M2: standing
  targets; no AI). The sim owns `Enemy.frame` at all times: idle/alert/chase
  frame 0 (M3 animates), pain 3, dying 4 -> 5 -> 6 over 8 ticks each, dead 6.
- Hit reaction: damage -> `hp -= d`, `flash = 2`, `state = .pain`, `timer = 12`
  (then back to `.idle`); `hp <= 0` -> `.dying` (`timer` drives the three
  frames), then `.dead`; `s.kills += 1` on the dying transition. Dead
  enemies are not targets and do not hold doors open (check
  `door_occupied`).
- Weapons (SPEC.md section 7). `A` held fires when `fire_cooldown == 0`;
  cooldown = rate (swatter 24, zapper 12, spray 36); `pub fn fire_rate(w) u8`.
  Zapper costs 1 charge, spray 1 can; with no ammo A does nothing. Select
  (edge on `p.prev`) cycles swatter -> zapper -> spray -> swatter skipping
  weapons with zero ammo (swatter never skipped; spray also needs `has_spray`).
- Hitscan: `pub fn wall_distance(s, level, x, y, angle) Fixed`: fixed-point
  DDA along the angle until a solid cell (walls; doors count solid while
  `open < door_passable`), capped at 24 cells. Zapper: for each living
  enemy compute the along-ray distance `t` and lateral offset; hit if
  `t > 0`, `|lateral| < radius`, `t < wall_distance`; the smallest `t` takes
  3 damage. Swatter: nearest living enemy with centre distance <= 1.2 and
  within +-15 degrees of the facing (angle compare via `Angle` wrap), LOS by
  the same wall check, 4 damage. Spray: 5 pellets, each at facing +
  `rng` jitter in +-10 degrees (xorshift32 on `s.rng`), reach 6, 2 damage
  each, same hit test. Nothing new uses f32.
- Add to `Player`: nothing required beyond the existing fields; append new
  fields with defaults only, keep `assert_no_padding` green, keep
  `GameState` under 1.5 KB (say the new size in your report).
- Tests (host): zapper kills a gnat in one shot and spends a charge;
  cooldown blocks the next shot for 12 ticks; a wall between blocks the
  shot; swatter hits at 1.0 cells and misses at 1.5 or 30 degrees off;
  Select cycles and skips empty; spray spends one can and hits a beetle
  at 3 cells for at least 2 damage; dying takes 24 ticks and increments
  `kills`; the 600-tick script hash test still passes with firing added.

### Contract: HUD, weapon overlay, blit (track C)

- `blit.zig`: `pub fn cell(comptime sheet: type, comptime cw: u32,
  comptime ch: u32, index: u32, x: i32, y: i32, opts: Opts) void`, palette
  index 0 transparent, clipped, `Opts { dim: bool, white: bool }` (dim =
  half brightness palette for missing keys). Nibble reads from
  `indices.bytes` as in track A; the palette `[16]Pixel` per sheet at
  comptime.
- `hud.draw_bar(s: *const GameState)`: SPEC.md section 4 exactly, y 104..127
  Anti-Black. x 0..31 HP `"{d}%"` in the 8x8 font over a 30x4 bar (green >
  60, Coral > 25, red below); x 32..63 ammo icon (`hud.png` cell 3 zapper,
  4 spray; swatter shows a dash) and number; x 64..95 portrait 24x24 with
  a 2 px frame; x 96..119 three key slots (`hud.png` cells 0..2, dim when
  missing); x 120..159 rewind meter 36x6 Iris fill over a dark trough,
  `hud.png` cell 5 clock glyph left of it.
- Portrait (`face.png`, SPEC.md section 10) frames: 0 healthy, 1 hurt (< 60),
  2 critical (< 25), 3 ouch, 4 grin, 5 glance left, 6 glance right,
  7 rewind, 8 dead. `hud.tick(s: *const GameState)` once per displayed
  tick advances render-only state: hp dropped since last tick -> ouch 30
  ticks; keys grew or `has_spray` flipped -> grin 45 ticks; idle glance
  every 180..300 ticks for 40 ticks (own tiny LCG, not `s.rng`). Ouch beats
  grin beats glance beats health tier. `hp <= 0` -> dead frame.
- `hud.draw_title(tick)`: `title.png` (128x40) at (16, 16), tag line
  "powered by deterministic replay" in Iris, blinking "PRESS A", small
  "B: E1M1 demo" line while the M1 debug shortcut exists.
- `hud.draw_intermission(s, level_name: []const u8, ticks: u32)`: full-screen
  Anti-Black card: "LEVEL CLEAR", the level name, kills `x/y` (y from
  `level.enemies.len`, passed in), time `mm:ss` from `s.tick / 60`, "PRESS A"
  after 60 ticks. `hud.draw_victory(s, ticks)`: same shape, "ALL BUGS FIXED".
- `hud.draw_render_us(us: u32)`: the M1 gate readout, 8x8 Coral text at the
  top-left of the view (kept until the gate passes).
- `weapon.draw(s: *const GameState, moving: bool)`: `weapons.png` 48x32 cell
  `weapon * 3 + frame`, drawn before the status bar at x 56, bottom at
  y 104 (+ bob). Fire frame: `fire_cooldown > rate * 2 / 3` -> frame 1,
  `> rate / 3` -> frame 2, else 0, with `rate = sim.fire_rate(w)`. Bob:
  render-only phase advanced while `moving`, y offset `+-2` on a 32-tick
  cycle; never lifts the sleeve off the bottom edge (see ASSETS.md 10).
- Verification: build, `preview.mjs` with the walk script shows the bar,
  the weapon bobbing while walking and still when not, the portrait
  glancing; with the combat script (lead) the zapper fire frames appear
  and the ammo count drops.

### Contract: rewind core (track D)

`cart/src/rewind.zig`, pure (imports `state.zig`, `sim.zig`, `levels.zig`
only; `zig test cart/src/rewind.zig` on the host). SPEC.md 9.2:

- Constants `keyframe_every = 30`, `keyframe_count = 21`, `input_len = 640`,
  `span = keyframe_every`. Storage: `[keyframe_count]GameState` ring keyed
  by tick, `[input_len]Buttons` ring indexed by `tick % input_len`,
  `[span]GameState` span cache. Comptime assert the total is <= 80 KB and
  report the exact bytes.
- Forward play API: `reset(s: *const GameState)` clears everything and
  stores `s` as the first keyframe; `log_input(tick: u32, b: Buttons)`
  before each `step` (the input applied at `tick`); `after_step(s)` stores
  a keyframe when `s.tick % keyframe_every == 0`. `earliest() u32` is the
  oldest tick still reachable (bounded by both rings).
- Rewind API: `begin(s: *const GameState, level) void` enters rewind at
  `s.tick` (fills the span cache by replaying from the keyframe at or
  before `s.tick` with the logged inputs); `back(level) ?*const GameState`
  returns the state one tick earlier, refilling the cache across keyframe
  boundaries, `null` once `earliest()` is reached (caller then stays on the
  last returned state); `current() *const GameState`; `commit(s: *GameState)`
  copies the current cached state into `s` and drops keyframes and inputs
  after it so forward play continues cleanly.
- Self-check (SPEC.md 9.3): `check(s: *const GameState, level) bool` at a
  keyframe tick re-simulates from the previous keyframe with the logged
  inputs and compares `sim.hash`; `pub var desyncs: u32` counts failures.
- Tests: 300 scripted ticks, rewind 100, commit, replay the same inputs
  forward and match the hash of a straight 300-tick run; rewind across at
  least two keyframe boundaries; `back` returns null exactly at
  `earliest()`; a run of 700 ticks (ring wrap) still rewinds 600 and no
  further; `check` is true on a clean run and false after poking a byte.

### Lead work

- `levels/test.txt`: one gnat at (6,3) in the start room so the combat
  script is "press A". Update the parse test.
- `main.zig`: modes `title, playing, paused, intermission, victory`;
  `finished` -> intermission (5 s or A) -> `new_game(level + 1)` or victory
  -> title. Calls `hud.tick`, `view.draw`, `weapon.draw`, `hud.draw_bar`,
  `hud.draw_render_us` in that order. Debug exports add `debug_hp`,
  `debug_kills`, `debug_weapon`, `debug_ammo`, `debug_level`,
  `debug_sprites`, `debug_state_hash`.
- Scripts: `m2_combat.json` (A from the start kills the gnat, Select
  cycles, fire again), `m2_exit.json` (walk to the exit at the east side,
  through the intermission into E1M1). `tools/check.sh` runs both with
  `--expect "debug_kills == 1"` and `--expect "debug_level == 1"`.
- GIF `docs/preview_m2.gif`, tag `m2`, pull-and-run note.

### Verification for M2

```
tools/check.sh
zig test cart/src/rewind.zig
```
plus the two new scripted runs inside `check.sh`.


## M3 Bugs (started 2026-09-27)

Goal: the bugs fight back and the campaign exists. Enemy AI for all five
kinds, projectiles, damage to the player, the death freeze (placeholder
exit until M4 rewinds), three hand-made levels, audio and neopixels, and
the first half of the determinism harness. Adrian's policy (2026-09-27):
placeholder art is final for now; build everything that does not need
hardware tuning; tune what does against `badge-bench` with adjustable
constants and headroom. Baseline (M2, modelled): mean 2.5 ms, worst 3.0 ms
of 16.7 ms per frame; `api.text` and `api.rect` are a quarter of that.

Pre-work landed in `2313930` so the tracks are disjoint: `sim.move_circle`
(sliding move for any circle; enemies open plain doors only),
`sim.damage_player` (HP floors at 0, sets `s.hurt`), `sim.line_of_sight`,
`sim.next_rand`/`sim.living` public, web freeze skips movement,
`s.last_shot` records zapper/spray shots, `Enemy.aux[3]` and
`Projectile.aux[2]` scratch bytes, and stub `ai.zig` / `projectiles.zig`
called from `step` (enemies, then projectiles, then the weapon).

### Tracks (parallel, disjoint files; agents do not commit)

| Track | Owner       | Files                                                                                  |
|-------|-------------|----------------------------------------------------------------------------------------|
| A ai       | Opus agent | `cart/src/ai.zig` (replace the stub)                                                 |
| B shots    | Opus agent | `cart/src/projectiles.zig` (replace the stub)                                        |
| C levels   | Opus agent | new `cart/src/levels/build_farm.txt`, `staging.txt`, `production.txt`, `cart/src/gen_levels.zig` (manifest), `cart/src/levels/gen.zig` (regenerated), `cart/src/levels.zig` (index consts), `cart/src/level_parse.zig` (freshness test rows), new `tools/check_level.py` |
| D audio+harness | Opus agent | new `cart/src/audio.zig`, new `tools/check_determinism.mjs`, `docs/RUNNING.md` section 5 additions |
| lead       | this session | `main.zig`, `render/hud.zig` (death overlay, title lines), `render/sprites.zig` (spider range), `tools/scripts/*.json`, `tools/check.sh`, `PLAN.md`, `SPEC.md` status, GIF, bench, commits, tag |

Concurrency: one working tree; a `zig build` failing in a file you do not
own is another track mid-edit, wait and retry. `zig test cart/src/ai.zig`,
`projectiles.zig`, `sim.zig`, `level_parse.zig` need no cart-api.

### Contract: enemy AI (track A)

`ai.update(s, level)` is called once per tick from `sim.step` (after doors
and pickups, before the player's weapon). It owns every `Enemy` field
once the level starts; `sim.damage_enemy` (pain/dying/flash) is the only
outside writer. Fixed point, `sim.next_rand` only, no f32, no cart-api.

- Per-kind constant table at the top of the file, every number named
  (speeds, ranges, damages, cooldowns), so they can be tuned later:
  SPEC.md section 8 values. Wake radius 8 cells (`sim.gunfire_radius`).
- States (`state.EnemyState`): `dormant` (never seen anything) checks
  line of sight once every 8 ticks, staggered by `index % 8`, and also
  wakes when `s.tick - s.last_shot < 8` and the player is within 8 cells.
  `alert` is a short 12-tick startle (frame 0), then `chase`. `chase`
  moves toward the player with `sim.move_circle(.., radius 0.3, .enemy)`;
  when blocked, try the eight compass directions in a deterministic order
  and keep the chosen one in `aux[0]` for 16 ticks (Wolf3D-style). Walk
  frames 0/1 alternate every 8 ticks while moving. `attack` plays frame 2
  for its windup then applies the attack; `pain` and `dying` as in the
  stub (keep those transitions exactly: tests in sim.zig depend on them).
- Behaviours: **gnat** zig-zags (heading = toward player +- 30 degrees,
  flipping every 20 ticks), bites 5 every 30 ticks within 0.8 cells.
  **wasp** waits in `idle`; on sight charges in a straight line at 0.07
  for up to 40 ticks or until it overshoots the player's position by 1.5
  cells or hits a wall, then turns (12 ticks) and charges again; contact
  (< 0.5 cells) during a charge deals 10 once per charge. **beetle**
  walks straight at the player at 0.02, spits (`projectiles.spawn(s, x, y,
  angle_to_player, projectiles.kind_spit)`) every 90 ticks when it has
  line of sight within 8 cells. **spider** never moves; when the player is
  within 6 cells with line of sight it webs (`kind_web`) every 120 ticks;
  attack frame 2 for 10 ticks first. **boss** (Heisenbug) chases at 0.04,
  melee 15 within 0.9 cells every 45 ticks, spit fan of three (angle
  -12/0/+12 degrees) every 100 ticks when it has line of sight; if the
  player has faced it (|angle_diff(facing, angle to boss)| < 20 degrees
  with line of sight) for 90 consecutive ticks (`aux[1]` counts), it shows
  frame 7 (flicker) for 8 ticks then teleports to a floor cell 3 to 5
  cells behind the player (search the cell ring around the player's
  position minus 4 cells along the facing, first free cell in a
  deterministic spiral; stay put if none), resets the counter.
- Damage to the player goes through `sim.damage_player`; webs through
  projectiles (track B sets `player.frozen`).
- Enemies do not collide with each other in M3 (noted for M5 polish).
  Dead and dying enemies do nothing. Dormant enemies cost one LOS check
  per 8 ticks, nothing else.
- Tests (host, in ai.zig, mini-levels via `level_parse.parse_level`): a
  gnat 5 cells away in an open room wakes within 8 ticks and reaches
  biting range in under 120 ticks, and the player's HP drops by 5 then by
  5 again 30 ticks later; a gnat behind a wall stays dormant for 300
  ticks; a shot within 8 cells wakes a gnat with no line of sight; a wasp
  charge covers ground at 0.07 and deals 10 once; a beetle spits (the
  projectile pool gains an entry); a spider at 4 cells webs, at 7 does
  not; the boss teleports after 90 ticks of being faced and not before;
  a 600-tick scripted run with 6 enemies produces the same `sim.hash`
  twice.

### Contract: projectiles (track B)

`projectiles.update(s, level)` after `ai.update`; `spawn(s, x, y, angle,
kind) bool` for the AI. Pool `s.projectiles[12]`, `kind` 0 free.

- Speeds: spit 0.08 cells/tick, web 0.06. `vx/vy` set at spawn from the
  angle; `ttl` 180 ticks. Start the projectile 0.4 cells ahead of the
  spawner so it does not hit the enemy's own cell.
- Each tick: move; if the new cell is solid (`sim.is_solid`) the
  projectile dies; if within 0.35 cells of the player centre: spit deals
  8 via `sim.damage_player`; web deals 4 and sets `player.frozen = 45`
  (turning still works, `step` already skips movement); then it dies.
- Tests: spawn fills a slot and returns false when 12 are live; a spit
  flying at a wall dies on the wall cell; a spit aimed at the player from
  3 cells hits within the expected tick count and takes 8 HP; a web freezes
  for 45 ticks (`frozen` counts down in `step`); ttl expiry frees the slot.

### Contract: levels (track C)

Three campaign levels in the ASCII format (CLAUDE.md legend), designed
per SPEC.md section 6, compact (Build Farm about 24x20, Staging about
32x28, Production about 40x36, all within 64x64), each 2 to 4 minutes:

- **Build Farm**: teach walking, doors, one Coral key (`c`) behind a plain
  door, gnats only (8 to 10), a hotfix and two charges, exit behind the
  Coral door. Start facing a short safe corridor.
- **Staging**: Coral and Iris keys, wasps (5 to 7) in open rooms, spiders
  (4 to 6) guarding corridors (their 6-cell range matters: put them where
  the player must pass within range), the first spray can (`$`) plus 2
  more, two rewind batteries (`*`) as a small hunt, a few gnats.
- **Production**: all three keys, all enemy kinds (about 22 total), the
  Heisenbug (`H`) alone in a large room behind the Gold door with the exit
  beyond it, batteries and hotfixes rationed. Rooms of 6 to 10 cells so
  the boss teleport has floor behind the player.

Rules: every wall texture 1-8 used somewhere per level with a theme per
area; doors only between two walls (the parser derives orientation);
enemies never inside a door cell; no more than 40 enemies, 64 doors,
256 pickups per level (tunable caps: keep enemies at or below 25 so the
sprite pass stays cheap; the benchmark says we have room, but leave it).
Level order in `gen_levels.zig`'s manifest and `levels.all`: build_farm,
staging, production, test, wolf_e1m1; add to `levels.zig`
`pub const campaign_len = 3; pub const test_index = 3; pub const e1m1_index = 4;`.
Extend the freshness test in `level_parse.zig` to all five. New
`tools/check_level.py FILE.txt`: parses the same legend in Python and
runs a key-aware flood fill from the start (collect reachable keys, open
their doors, repeat) and reports unreachable cells, pickups, enemies and
whether the exit is reachable; counts per kind; exits 1 on any
unreachable item. Run it on all five levels (the imported E1M1 may report
unreachable secrets: print, do not fail, for `wolf_*`).

### Contract: audio, neopixels, determinism harness (track D)

- `cart/src/audio.zig` (cart-api user, render-side, never touched by the
  sim): `pub var enabled: bool = false` (Adrian: sound defaults off,
  Select on the title toggles it; the LED effects are also gated by it); `reset(s)` takes a baseline;
  `tick(s: *const GameState, level: *const Level)` once per displayed
  tick while playing: derives events by diffing against the last state
  (hp dropped -> hurt; kills grew -> enemy death; an enemy's `flash`
  became 2 -> enemy hit; keys grew, `ammo_*` grew or hp grew -> pickup;
  a door `phase` went 0 -> 1 -> door; `last_locked != 0` -> locked buzz;
  `fire_cooldown` jumped to `sim.fire_rate(weapon)` -> weapon sound by
  weapon) and plays the highest-priority one through the cart's tone API
  (read `../../sycl-badge/src/os/cart/api.zig` for the exact call; SPEC.md
  section 12 has shapes, frequencies, durations and the priority order).
  `play(event: Event)` for main-driven events (`death_freeze`; `rewind`
  loop retrigger comes in M4). Neopixels (dormant: neopixels are off,
  the cart never writes non-zero values; the effects are compiled out and
  `-Dneopixels=true` re-enables them for development, docs/NEOPIXELS.md):
  HP as a green-to-red bar over the five LEDs, a white flash for 6 ticks
  on key pickup, all off when disabled. Diffing must survive a jump
  backwards in `s.tick` or a level change (take a fresh baseline, play
  nothing), like the portrait does.
- `tools/check_determinism.mjs <cart.wasm> --script FILE.json --frames N
  [--exports debug_state_hash,debug_tick]`: runs `tools/preview.mjs` twice
  (`--quiet`, `--dump-exports`) via child_process, parses both
  `frames.json`, asserts every listed export equal, prints them, exits 0/3.
  Reserve and document `--rewind-at T --rewind-for N` for M4 (parse it,
  print "not implemented until M4", exit 2). Document in
  `docs/RUNNING.md` section 5.

### Lead work

- `main.zig`: mode `.dead` when `hp == 0` after a step: view drawn with
  `shade_override = 5`, "HOLD B TO REWIND" overlay (`hud.draw_dead`),
  holding B for 60 ticks restarts the level (M4 replaces this with the
  real rewind); `s.hurt > 0` also sets `shade_override = 5`. Title: A
  starts the campaign (level 0), B starts E1M1, Start starts the test
  level (debug, for the scripts), Select toggles `audio.enabled` and the
  title shows "SOUND ON/OFF". Calls `audio.reset` / `audio.tick`.
  Campaign end after `levels.campaign_len` -> victory. Debug exports add
  `debug_frozen`, `debug_projectiles`.
- `hud.zig`: `draw_dead(ticks_held)`, title sound line and "START: test
  level" hint; `sprites.zig`: spiders are skipped beyond 6 cells.
- Scripts: all existing scripts start the test level with START instead
  of A; `m3_gnat.json` (stand still, get bitten, HP drops), `m3_death.json`
  (die to gnats, hold B, level restarts, `debug_hp == 100`),
  `m3_buildfarm.json` (walk the first corridor of Build Farm from A on the
  title). `check.sh` adds them, `check_level.py` on all levels, and
  `check_determinism.mjs` on the combat script.
- Bench after integration on `m3_gnat.json` and `m3_buildfarm.json`; record
  mean/worst in the status line. GIF, tag `m3`, pull-and-run note.


## M4 Rewind (started 2026-09-29)

Goal: the headline mechanic. Hold B and time runs backwards through the
whole `GameState` (SPEC.md 9); the death freeze becomes the real rewind;
Iris tint, scanlines, `<<` marker, descending sweep and purple neopixels
(dormant, behind `-Dneopixels`) while rewinding; the determinism self-check runs at every keyframe on the
wasm and Debug builds and `check_determinism.mjs --rewind-at/--rewind-for`
proves a rewound state is bit-identical to the state that was live back
then. The rewind core (`rewind.zig`, 7 host tests, m2) is used as is.

Work happens in the worktree `/home/exedev/snouty-badge-snoutenstein`
(branch `snoutenstein-m4`) because other carts are mid-edit in the main
working tree; the branch merges into `main` at the tag.

### Tracks (parallel, disjoint files; agents do not commit)

| Track | Owner | Files |
|-------|-------|-------|
| A presentation | Opus agent | `cart/src/render/hud.zig`, `cart/src/render/view.zig` (scanline pass only), `cart/src/audio.zig` |
| B harness | Opus agent | `tools/check_determinism.mjs`, `docs/RUNNING.md` ("Determinism check" section) |
| lead | this session | `cart/src/main.zig`, `cart/src/sim.zig` (`hash_gameplay` only), `tools/scripts/*.json`, `tools/check.sh`, `PLAN.md`, `SPEC.md` status, GIF, bench, commits, tag |

### Rewind semantics (lead, `main.zig`)

Tick conventions are `rewind.zig`'s: `log_input(game.tick, b)` before
each forward `sim.step`, `after_step(&game)` after it, `reset(&game)` in
`new_game` after `sim.init`. Pausing steps nothing and logs nothing.

- New mode `.rewinding = 6`. Entered from `.playing` or `.dead` on a B
  press (`pressed`, not held: a B still held after a forced commit must
  not re-enter). `budget` = the live meter, or `max(meter, 180)` when
  entering from `.dead` (the once-per-death reserve, SPEC.md 9.1). The
  reserve is *not* written into `GameState` (that would make the live
  state disagree with its replay); `commit` writes the result. `drained`
  starts at 0. `rewind.begin(&game, level)`, `hud.set_rewinding(true)`.
- Each tick while B is held and `drained < budget`: `rewind.back(level)`;
  on success `drained += 1`. `back` returning null means the history is
  exhausted (level start): hold there.
- Release, or `drained == budget` (meter empty): if the shown state has
  `hp > 0`, `rewind.commit(&game)`, then `game.player.rewind_meter =
  budget - drained`, `game.rewinds += 1` if `drained > 0`, mode
  `.playing`. The release tick does not step; forward play resumes the
  next tick. If the shown state still has `hp <= 0` (B tapped at the
  death tick without stepping back) the mode returns to `.dead`.
- Safety net for SPEC.md 9.1's "meter empties while still dead": with the
  reserve, one tick back always reaches `hp > 0`, so the restart can only
  happen when there is no history at all (death at tick 0, impossible in
  practice). Kept as: in `.dead`, holding B for 60 ticks while `back`
  fails restarts the level. Noted as a deviation.
- Display while rewinding: `view.shade_override = 4` (Iris set), the
  shown state is `rewind.current()`, `hud.meter_override = budget -
  drained` so the clock counts down, `view.scanlines()` after
  `view.draw`, `hud.draw_rewind_marker()`, `audio.rewind_tick(shown)`
  instead of `audio.tick` (the next `audio.tick` re-baselines on the tick
  jump; `portrait.rewinding` already suppresses face events).
- Self-check (SPEC.md 9.3): `const self_check = cart.is_wasm or
  builtin.mode == .Debug`; when set and `game.tick % rewind.keyframe_every
  == 0` after `after_step`, call `rewind.check(&game, level)`. Export
  `debug_desync = rewind.desyncs`. Hardware ReleaseSmall skips it (30
  `step`s in one frame every half second is not free).
- `sim.hash_gameplay(s)`: FNV over a copy with `player.rewind_meter`,
  `player.rewind_regen` and `rewinds` zeroed. A committed state differs
  from the state that was live at that tick only in those fields, so this
  is what the harness compares. Exported as `debug_gameplay_hash`.
- New exports: `debug_rewinds`, `debug_meter` (the displayed meter,
  override included), `debug_desync`, `debug_gameplay_hash`.

### Contract: presentation (track A)

`hud.zig`:
- `pub var meter_override: ?u16 = null`; when set, `draw_bar` draws the
  clock and meter from it instead of `s.player.rewind_meter`.
- `pub fn draw_rewind_marker() void`: a `<<` at the top left of the view
  (x 0, y 0) in Iris on anti-black, as `draw_render_us` draws its text.
- `draw_render_us` moves to the top right (right-aligned at x 159) so the
  marker and the readout never overlap.
- `draw_dead()` loses the hold bar: "HOLD B TO REWIND" plus a second line
  with the seconds available (`meter_override` if set, else the meter,
  floored to the 3 s reserve, i.e. `max(m, 180)`), e.g. "3s OF REWIND".
  Signature `draw_dead(meter_ticks: u16)`; the lead passes the budget.

`view.zig`:
- `pub fn scanlines() void`: darkens rows `y % 4 == 3` for `y < view_h`
  in `cart.framebuffer` (column-major, `[x][y]`): halve r, g, b via
  `to_color` / `from_color`, or a precomputed 16-bit trick; whichever is
  cheaper, note the choice. 160 x 26 pixels, budget well under 0.2 ms on
  the M33 (count the instructions in the inner loop and say so).

`audio.zig`:
- `pub fn rewind_tick(s: *const state.GameState) void`: advances the
  voice, retriggers `.rewind` every 10 ticks (the table entry exists),
  and writes all five neopixels Iris purple pulsing between 3/255 and
  8/255 over a 30-tick triangle (now dormant: neopixels are off, the
  effect is compiled out unless built with `-Dneopixels=true`). No
  event detection. Own counter, reset by `reset`. When `!enabled`,
  silence and LEDs off as `tick` does.
- Confirm `tick` re-baselines when it next runs after a rewind
  (`s.tick < last_tick`) so no hurt/pickup sounds fire from the tick
  jump; add a host test if audio.zig can be tested without cart-api,
  otherwise say it cannot.

Verify with `zig build -Dcart=snoutenstein` at the repository root
(`../..`) and `zig build test`-free checks: hud/view/audio import
cart-api so there are no host tests; make sure the wasm and firmware
both build.

### Contract: harness (track B)

`tools/check_determinism.mjs --rewind-at T --rewind-for N` (T, N in
update indices, 0-based, like preview's `--at`/`--call-at`):

- Run 1: the script unchanged, `--frames F`, plus `--call-at f debug_tick`
  and `--call-at f debug_gameplay_hash` for every f in `[max(0, T-1-N),
  T-1]` (read from frames.json `calls`).
- Run 2: the script with `{"from": T, "to": T+N-1, "hold": ["B"]}`
  appended to a temp copy (fail with exit 2 if the script already holds B
  in that range), same `F`, plus `--call-at T+N debug_tick`,
  `debug_gameplay_hash`, `debug_mode`, `debug_rewinds`, `debug_desync`
  (the release frame commits; nothing steps that frame). Requires
  `T + N < F`.
- Assert: run 2 at `T+N` has `debug_mode == 1` (playing) and
  `debug_rewinds >= 1`; its `debug_tick` equals some run-1 sample's tick
  in the window; the two `debug_gameplay_hash` values agree; `debug_desync
  == 0` at the end of both runs (always add it to the compared exports
  when the cart exports it). Report the ticks (`rewound from tick X to
  tick Y, N' ticks`) on the PASS line; a tick not found in the window is
  a FAIL explaining that the rewind was shorter than asked (meter or
  history bound) and how far it got.
- Without `--rewind-*` the tool behaves exactly as today (and still
  compares `debug_desync` when exported).
- Exit codes unchanged: 0 pass, 2 usage, 3 mismatch or failed run.
- `docs/RUNNING.md` "Determinism check": replace the "reserved for M4"
  sentence with the real usage and one example line.

The exports `debug_gameplay_hash`, `debug_rewinds`, `debug_desync`,
`debug_meter` and mode 6 are the lead's and land in `main.zig` early in
the milestone; until they build, develop against the option parsing and
script rewriting, then run the real thing.

### Lead work

- `main.zig` as above; `sim.hash_gameplay`; `rewind.reset` in `new_game`.
- Scripts: `m4_rewind.json` (test level, walk 150 ticks, hold B 60,
  expect playing, `debug_rewinds == 1`, `debug_px` back near the tick-90
  position), `m4_death.json` (from `m3_death.json`: die, hold B a while,
  release alive, expect playing and `debug_hp > 0` with `debug_tick` below
  the death tick), `m4_empty.json` (walk the corridor back and forth for
  700 ticks, hold B 700: the meter runs dry at 600 ticks back, forced
  commit, `debug_meter == 0`, still playing). `m3_death.json`'s
  expectations updated for the new death rule. `check.sh` adds the M4
  runs, `check_determinism.mjs --rewind-at 200 --rewind-for 90` on the
  walk script and `--expect "debug_desync == 0"` on every run.
- Bench the rewind-entry burst (`rewind.begin` replays up to 29 steps in
  one frame) on badge-bench with the rewind script; record mean/worst.
- SPEC.md 9.1 note (restart is a fallback), status lines, GIF
  `docs/preview_m4.gif` from the rewind script, tag `m4`, merge to main,
  pull-and-run note.

### Verification for M4

`tools/check.sh` green including the new runs; `zig test rewind.zig` and
`sim.zig` unchanged; `debug_desync == 0` on every scripted run; the
rewind determinism check passes on the walk script; GIF shows the Iris
tint, scanlines and the clock counting down.

## M5 Attract and polish (started 2026-09-29)

Goal: the cart is a finished conference build. The title idles into a
recorded demo of Build Farm that anybody can take over mid-run (SPEC.md
11), the gnats stop being lethal, enemies stop stacking, and the demo
doubles as the hardware determinism test that SPEC.md 9.3 asks for: the
badge replays the log recorded in the simulator and compares the final
hash. Adrian's rules apply: placeholder art is final; anything that needs
a physical badge is deferred or gets a conservative default (listed at the
end). Work happens in the worktree `/home/exedev/snouty-badge-snoutenstein`
on branch `snoutenstein-m5`; it merges into `main` at the tag.

### Demo = seed + input log (lead)

A demo is exactly what SPEC.md 9.2 says: a keyframe plus an input log.
The keyframe is `sim.init` of Build Farm with a fixed seed, the log is a
run-length list of button words. Nothing is recorded on the badge; the log
is authored in the simulator and baked into `.text`.

- `tools/scripts/demo_build_farm.json`: the authored playthrough in the
  usual script format (a JSON array of `{from, to, hold}` entries, so
  `preview.mjs --script` runs it as is; tick 0 is the first `sim.step`
  of the level, no title press; an entry with an empty `hold` pads idle
  ticks). The demo ends after tick `max(to)`: total ticks `T = max(to) + 1`.
- `tools/gen_demo.py IN.json --out cart/src/demos/build_farm.zig
  [--hash 0x...]`: runs the script through the same button-bit layout as
  `preview.mjs`, merges consecutive identical ticks into `Run { buttons:
  u16, ticks: u16 }`, and writes a plain literal data file:
  `pub const level_index: u8 = 0; pub const seed: u32 = demo_seed;
  pub const total_ticks: u32 = T; pub const final_hash: u32 = H;
  pub const runs = [_]Run{...};` (`final_hash` 0 = unrecorded). No
  comptime work in the cart (Mac rule).
- `tools/record_demo.sh`: builds nothing; runs `preview.mjs` on the wasm
  with `--call debug_new_game_seeded` (see exports) and the JSON as the
  script for `T` frames, reads `debug_gameplay_hash` after update `T-1`
  from `frames.json`, and regenerates the data file with `--hash`. After a
  rebuild, `check.sh` proves the embedded demo reproduces that hash in
  demo mode.
- `cart/src/demo.zig` (pure, host tests): cursor over `demos/build_farm.zig`:
  `reset()`, `next() ?Buttons` (null once `total_ticks` inputs were
  handed out), `finished() bool`, `ticks_played() u32`. Test: the runs sum
  to `total_ticks`; `next` returns exactly `total_ticks` values and
  decodes a two-run fixture correctly.
- `main.zig`: `demo_active`, `title_ticks`, `demo_result: enum { none,
  ok, desync }`.
  - Title: `title_ticks` counts up; at `attract_after = 600` (10 s)
    `start_demo()`: `new_game(demo.level_index)` with `demo.seed` instead
    of the clock, `demo.reset()`, `demo_active = true`. Any title button
    press still starts a game and resets the counter.
  - While `demo_active`, the mode machine runs unchanged (`playing`,
    `rewinding`, `dead`, `intermission` all reachable) with `b =
    demo.next()` instead of the pad. The pad is only watched for a
    takeover: an edge on A, B, Start, up, down, left or right (`pressed`)
    ends the demo *this* tick without stepping: `demo_active = false`,
    `rewind.set_meter(&game, sim.max_rewind)` (refill, recorded as a
    patch so the keyframe self-check keeps agreeing), if `mode ==
    .rewinding` first `end_rewind()`. Controls are live from the next
    tick (SPEC.md 11 "hands the controls over on the next tick"). Select
    is ignored during the demo (weapon key in game, sound toggle only on
    the title).
  - Demo ends and returns to the title (`title_ticks = 0`) when: the log
    is exhausted (`next` returned null: then `demo_result = if
    (sim.hash_gameplay(&game) == demo.final_hash) .ok else .desync`, only
    when `final_hash != 0`), or `demo_ticks >= demo_max = 3 * 3600`, or
    the demo sits in `.dead` for 120 ticks, or it reaches `.intermission`
    or `.victory` and the card has shown for `card_min` ticks. The 3 min
    cap and the death exit set no result.
  - HUD: `hud.draw_demo_marker(tick_total)` after the bar while
    `demo_active` in a view mode; `hud.draw_title(.., demo_result)`.
  - `rewind.set_meter(s, meter)`: new, tiny: records `{meter,
    count_rewind = existing or false}` as the patch of `s.tick` and
    applies it (only valid when not rewinding and `s.tick == head`).
  - Exports: `debug_demo` (1 while the demo drives), `debug_demo_result`
    (0 none, 1 ok, 2 desync), `debug_title_ticks`; setup calls
    `debug_start_demo` (start the demo at update 0, for scripts and the
    bench) and `debug_new_game_seeded` (Build Farm with `demo.seed` in
    normal play, for authoring and `record_demo.sh`).
- Scripts and checks: `m5_attract.json` (no input at all; `--at 598
  debug_mode == 0`, `--at 599 debug_demo == 1`: the 600th title tick
  starts the demo, `--at 600 debug_tick == 1`, back on the title with
  `debug_demo_result == 1` once the log ends), `m5_takeover.json` (idle into the demo, UP edge at update 700:
  `--at 700 debug_demo == 0`, `--at 700 debug_mode == 1`, `--at 700
  debug_meter == 600`, the tick does not advance on the takeover update,
  `debug_desync == 0` at the end), the demo replay
  itself (`--call debug_start_demo --frames T+5`, expect
  `debug_demo_result == 1`, `debug_mode == 0`, `debug_desync == 0`), and
  `check_determinism.mjs` on the takeover script. Every M3/M4 expectation
  that encodes a death tick is re-derived after track B lands.

### Tracks (parallel, disjoint files; agents do not commit)

| Track | Owner | Files |
|-------|-------|-------|
| A demo author | Opus agent, after B lands | `tools/scripts/demo_build_farm.json`, `cart/src/demos/build_farm.zig` (regenerated), `docs/RUNNING.md` demo paragraph |
| B balance | Opus agent | `cart/src/ai.zig`, `cart/src/sim.zig` (enemy separation helper only, if needed), tests in those files |
| C presentation | Opus agent | `cart/src/render/hud.zig`, `cart/src/audio.zig`, `docs/RUNNING.md` ("Attract mode" section skeleton), `SPEC.md` section 12 wording |
| lead | this session | `main.zig`, `demo.zig`, `rewind.zig` (`set_meter`), `tools/gen_demo.py`, `tools/record_demo.sh`, `tools/scripts/m5_*.json`, `tools/check.sh`, `PLAN.md`, GIF, bench, commits, tag, merge |

### Contract: balance and enemy separation (track B)

Everything through the named constants at the top of `ai.zig`; report
the before/after numbers, do not touch `main.zig` or the scripts.

- Gnats: today three gnats take 65 HP in 7 s from a player standing in
  the Build Farm opening (M3 status). Target, measured with a host test
  that parses the Build Farm text and stands still at the start facing
  east from tick 0: HP after 420 ticks between 55 and 75; the same player
  holding A (zapper, facing east) for 420 ticks ends above 85 HP. Turn
  `melee_damage`, `melee_every`, `melee_windup`, `speed` and
  `gnat_zig*`; keep SPEC.md section 8's shape (zig-zag, bite). Update the
  table in SPEC.md 8 to the values chosen with "(tuned M5)" once.
- Wasps, beetles, spiders: unchanged unless a test shows something
  absurd; say so.
- Heisenbug: write a host test on a 12x12 open room: a player 4 cells
  away with 99 charges who holds A and turns to face the boss every tick
  (LOS always) kills it; report the ticks it takes and the HP the player
  has left with the current numbers (spit fan, melee, teleport). If the
  player dies before the boss, lower `melee_damage` or lengthen
  `shot_every` until they win with 20+ HP; a hardware balance pass is
  deferred (see the deferred list), so leave headroom, not a knife edge.
- Enemy separation (M3 left it): a chasing or charging enemy does not
  end a move within `separation = 0.5` cells (centre to centre) of
  another enemy that is alive and not dormant; treat it like a wall hit
  (fallback direction for chasers, end of charge for wasps). Spiders and
  dying/dead enemies do not block or get blocked. Fixed point,
  deterministic, O(n) per moving enemy over `level.enemies.len` (the
  bench has room; note the cost). Test: two gnats released from adjacent
  cells toward the player never end a tick closer than 0.5 to each other
  over 300 ticks; the six-enemy 600-tick hash test still passes twice.
- Keep every existing test in `ai.zig`, `projectiles.zig`, `sim.zig`
  green (numbers inside tests may move with the tuning; say which).

### Contract: presentation, neopixels, docs (track C)

`hud.zig`:
- `pub fn draw_demo_marker(tick_n: u32) void`: "DEMO" centred at the top
  of the view (x 64..95, y 0) in Anti-White on Anti-Black, on for 40 of
  every 60 ticks; must not touch x < 16 (the `<<` marker) or x >= 104
  (the render readout).
- `draw_title(tick_n, sound_on, demo_result: DemoResult)` where `pub
  const DemoResult = enum(u8) { none = 0, ok = 1, desync = 2 }` lives in
  `hud.zig` (main re-exports or converts). `.ok` prints "DEMO OK" in grey
  at the top left (x 2, y 2), `.desync` prints "DEMO DESYNC" in Coral
  there; `.none` prints nothing. Keep every existing title line.
- Nothing else in `draw_bar` changes.

`audio.zig` (docs/NEOPIXELS.md at the repository root, approved by Adrian
2026-09-29: carts never write a non-zero neopixel value):
- One function `write_pixels(c: [5]cart.NeopixelColor)` is the only
  writer of `cart.neopixels`; `write_leds` and `rewind_tick` go through
  it. It returns at once unless `const neopixels_allowed = false` is
  flipped (since replaced by the shared `-Dneopixels` build option) (comment: the shared `-Dneopixels` build option from
  docs/NEOPIXELS.md replaces this constant when that change lands; the
  effects stay dormant behind it). No LED byte is ever written in the
  shipped build. Sound is untouched.
- Update the module doc comment and the "10/255" remark accordingly.

Docs:
- `docs/RUNNING.md`: new section "Attract mode and the recorded demo"
  after "Determinism check": the title idles 10 s into the demo, takeover
  keys, what "DEMO OK / DEMO DESYNC" on the title means (the badge
  replayed the log recorded in the simulator and compared
  `sim.hash_gameplay`), the setup calls `--call debug_start_demo` and
  `--call debug_new_game_seeded`, `tools/record_demo.sh` and
  `tools/gen_demo.py` usage as specified above, and a placeholder line
  "Demo content: (track A fills in)". Also mention that neopixels are
  off in every build.
- `SPEC.md` section 12: replace the neopixel sentences with "Neopixels
  are off (docs/NEOPIXELS.md); the HP bar, purple pulse and key flash are
  dormant behind `neopixels_allowed`", and section 3/CLAUDE.md line about
  "at or below 10/255" in this cart's CLAUDE.md becomes "never lit".

Verify with `zig build -Dcart=snoutenstein` at the repository root (both
wasm and firmware) and `tools/check.sh` minus the new M5 runs.

### Contract: demo content (track A, after B lands)

Author `tools/scripts/demo_build_farm.json` against the wasm with
`--call debug_new_game_seeded` (no rebuild per iteration: the game is
Build Farm with the demo seed in normal play, tick 0 = update 0, so
`--call-at N debug_px` etc. sample the run). Turns are 36 ticks per 90
degrees (455 units/tick), walking 0.045 cells/tick, backing 0.03. Aim for
60 to 90 s (3,600 to 5,400 ticks) that shows, in order: the corridor
walk, the plain door, the cable-tray room with gnats zapped, a bite or
two taken, the vent closet and Coral key (portrait grin), the Coral door,
then deliberately taking damage (HP under 40) and holding B for about 3 s
so the Iris rewind is on screen, zapping the gnats on the second try,
and ending in the pipe hall in sight of the exit strip with HP above 50.
Do not enter the exit (the log end returns to the title). Weapon: zapper
throughout; a Select cycle to the swatter and back is a nice touch, not
required. Death mid-demo is fine only if the log rewinds out of it.
Then `tools/record_demo.sh`, rebuild, `tools/check.sh` green (the lead
adds the demo replay run; you may extend its `--at` samples), a GIF via
`preview.mjs --call debug_start_demo --every 6` +
`tools/make_gif.py` to `docs/preview_m5.gif`, and the "Demo content"
paragraph in `docs/RUNNING.md` (route, length, where the rewind is).
Report the final hash, `T`, the ELF `.text` delta from the runs.

### Deferred or defaulted (needs a badge)

- Hardware balance pass and Heisenbug feel: conservative defaults from
  the host tests above; the `tuning` table is the knob.
- Optional fourth weapon ("the Debugger", SPEC.md 7): not built.
- Final art drop-in: placeholders are final (Adrian, 2026-09-27).
- M1 render readout stays on screen (`show_render_us`) until the gate.
- Demo hash on the badge: the cart shows DEMO OK / DEMO DESYNC on the
  title after the demo has run once; Adrian reads it off the badge.
- Neopixels: off; dormant code behind `-Dneopixels` (was `neopixels_allowed`).

### M5.1 Balance follow-up (2026-09-29)

Adrian on the M5 numbers: "we can make the enemies do more damage, it'd
be basically impossible to lose as is." Values now (all in `ai.zig`'s
`tuning` table and `projectiles.zig`):

| Enemy   | M5 default          | M5.1                                   |
|---------|---------------------|----------------------------------------|
| gnat    | 2 every 60, speed 0.04 | 4 every 40 (windup 8), speed 0.05   |
| beetle  | spit 8              | spit 10                                |
| spider  | web 4               | web 6                                  |
| boss    | melee 10 every 60   | melee 15 every 45 (no flinch and the 2.5-cell spit minimum stay) |
| wasp    | 10 on contact       | unchanged                              |

Host measurements: standing among the three cable-tray gnats for 7 s
leaves 4 HP (was 68), zapping without turning 60 HP (was 88); the
stand-and-shoot Heisenbug duel ends at 15 HP (was 52). The test bands in
`ai.zig` encode these. Death scripts die at tick 1034 (was 3028). The
demo was re-recorded because gnat timing changed (3,627 ticks on Build
Farm, hash 0x093CA09A), then again on Production at Adrian's request
("the most interesting level", dying in the demo is fine, it loops back
to the title): 4,108 ticks (68.5 s), hash 0x10A0860C: plain doors, the
cable-tray gnats, the beetle (a spit lands), the vent hall (webbed,
charged by wasps, down to 34 HP), a 210-tick rewind (tick 1221 back to
1011, 90 HP), the vent hall cleared, Coral key, hotfix, the brick room, out
of charges so the swatter, the Iris key, ends alive at 74 HP with 12 kills
in front of the Iris door. The Heisenbug is behind all three keys and out
of a 90 s demo's reach. `record_demo.sh` keeps the level
from the data file and accepts a log that ends dead; `main.zig` compares
the hash when the log ends alive or dead. The file names still say
`build_farm` (the data file is per cart, not per level).

### M5.2 Secret doors (2026-09-29)

Adrian: "put a single can in the first level, hidden behind a secret
door." New door kind `secret` (legend `X`), a bump-activated Wolf3D
pushwall: `DoorDef.tex` carries the neighbouring wall's texture (parser:
the cell above for a north-south panel, the cell to the left otherwise);
the raycaster draws a fully closed secret door as a flush wall with that
texture (`secret_shut`) and as a sliding wall chunk once it moves;
`sim.bump` opens it for the player only (enemies never), `update_doors`
skips the hold/close phases for it; `check_level.py` treats `X` as an
unlocked door. Build Farm grew two rows: a one-cell nook under the Iris
mural at (11,20) with the level's one spray can behind `X` at (11,19).
Production is untouched, so the attract demo's hash is unaffected. Tests:
parse (`tex`, orientation), sim (opens for the player, stays open 3x the
hold time, an enemy bump does nothing).

## M6 The Debugger (planned 2026-09-29, done 2026-09-29)

Adrian: "plan to implement the debugger weapon and put it behind a
secret door in levels 2 and 3." SPEC.md 7 calls it a slow splash
projectile. Confirmed 2026-09-29 ("Let's build the debugger gun");
the proposal below stands with these contract corrections found at
pre-work time:

- `Player` grows by 4 bytes, not 2: `ammo_debugger: u8`,
  `has_debugger: bool` and an explicit `_pad: [2]u8` (24 + 2 bytes would
  leave compiler padding, which `assert_no_padding` rejects). GameState
  is 1,372 bytes; the attract demo is re-recorded at the end.
- `projectiles.png` cells are 8x8 (not 16x16): cell 4 the bolt, cell 5 the
  burst, six cells. The burst is a display-only projectile
  `kind_burst = 4` (no movement, no damage, ttl 6) that sprites.zig draws
  as cell 5 at 1.0 cell, centre anchored; the bolt `kind_debug = 3` is
  cell 4 at 0.25 like the enemy shots. The 12 damage is dealt once, in
  the tick the bolt bursts.
- `pickups.png` cell 7 (the spare mug) becomes the Debugger cartridge, so
  `PickupKind.debugger = 7` needs no new pickup cell. `hud.png` gains
  cell 8 (the heart is cell 7). `weapons.png` gains cells 9, 10, 11.
- Legend `&` is parsed (level_parse, check_level.py) and the test level
  gets one `&` at (5, 5), off the m1/m2/m5 script paths, for the
  `m6_debugger.json` script.
- Pre-work (lead, committed before the tracks): the enum members, the
  `Player` fields, the `&` legend and compile stubs (`fire_rate` 48,
  `has_ammo`, four-way `next_weapon`, ammo spend without a shot, the
  pickup, `debug_ammo`, hud/audio switch arms). Tracks replace the stubs.

- **Weapon 4, the Debugger.** `Weapon.debugger = 3`. Fires a player
  projectile (`projectiles.kind_debug = 3`, owner = player: it hurts
  enemies, never the player) at 0.10 cells/tick, ttl 120 (12 cells). On
  hitting a solid cell or coming within 0.4 cells of a living enemy it
  bursts: 12 damage to every living enemy within 1.5 cells of the burst
  (no line-of-sight test; the burst is the point), plus a 6-tick white
  flash on each. Cooldown 48 ticks. Ammo `ammo_debugger` u8, start 0, max
  9; pickup `debugger` (legend `&`, `PickupKind.debugger`) gives 3 charges
  and, on the first pickup, `has_debugger` and selects the weapon (grin).
  Select cycles swatter, zapper, spray, debugger, skipping empties.
  Against the Heisenbug (80 HP) that is 7 bursts; the boss's 2.5-cell spit
  minimum means a player at 3 to 6 cells trades bursts for spit.
- **State.** `Player` gains `ammo_debugger: u8` and `has_debugger: bool`
  (append, defaults, keep `assert_no_padding` green: 2 bytes, check the
  struct still has no compiler padding). `GameState` grows by 2 bytes, so
  `sim.hash` changes and the attract demo must be re-recorded
  (`tools/record_demo.sh`); rewind pools grow by 2 x 52 bytes.
- **Art (placeholders, `tools/prepare_assets.py`).** `weapons.png` gains
  three 48x32 cells (idle, fire x2: a chunky breakpoint gun);
  `projectiles.png` gains two 16x16 cells (the bolt, the burst);
  `hud.png` gains an ammo icon cell 7. `ASSETS.md` rows for each.
- **Levels.** Staging: a secret door off the pipe supply wing with one
  `&`; Production: a secret door in the monitor hall with one `&` and a
  hotfix, so the Debugger arrives before the Gold door. Both nooks are
  one or two cells; `check_level.py` must still report every pickup
  reachable. No other balance change.
- **Audio.** A low square thump for the burst (priority with enemy
  death), a short click for the shot.
- **Verification.** Host tests: a burst 3 cells away kills two adjacent
  gnats and leaves a third at 2 cells untouched; the projectile stops at
  a wall and bursts there; Select cycles through four weapons and skips
  the empty Debugger; the 600-tick hash test still passes twice.
  Scripts: `m6_debugger.json` on the test level (pick up `&` placed
  there, fire at the beetle). Re-record the demo, GIF, tag `m6`.
- **Tracks.** A weapon (sim/projectiles/state, tests), B art + levels
  (prepare_assets, ASSETS.md, staging.txt, production.txt, gen.zig), C
  render/HUD/audio (weapon.zig, sprites.zig cells, hud.zig icon,
  audio.zig rows); lead main.zig (nothing much: Select handling is in
  sim), scripts, demo re-record, status.

## Status

- 2026-09-26: M0 scaffold committed. M1 plan written; four tracks launched.
- 2026-09-26: M1 done and tagged `m1`. All four tracks landed as planned.
  ELF text 30.6 KB, bss 15.1 KB (13.3 KB unpacked textures). GameState is
  1,368 bytes with explicit padding so the FNV hash is stable. Sim: 12 host
  tests. Render: inner loop is texel load, palette load, store; estimated
  under 1 ms per frame on the M33 from the generated assembly, unmeasured
  on hardware (the gate). Importer: 10 tests, shareware E1M1 converted
  and embedded as level 1 (B on the title starts it). Deviations: floor
  and ceiling fills use volatile 32-bit stores instead of memset
  (ReleaseSmall memcpy is byte-wise); a closing door reopens if stepped
  into; doors are passable at open >= 198 (22 ticks). Brief notes for the
  art agent are in ASSETS.md section 10. `tools/check.sh` runs the whole
  M1 verification. Next: hardware gate, then M2.
- 2026-09-27: M2 plan written while the M1 hardware gate is pending; four tracks launched.
- 2026-09-27: M2 done and tagged `m2`. All four tracks landed as planned.
  ELF text 72.2 KB (the sprite sheets are now referenced), bss 16.8 KB;
  GameState still 1,368 bytes (enemy stats live in `sim.zig`, no new
  fields). Sim: 25 host tests (weapons, hit reactions, wall_distance,
  Select cycling). Rewind core: 7 host tests, 71,132 bytes of pools, not
  yet wired into `main.zig` (M4). Deviations: portrait frame is 2 px on
  the sides only and the clock glyph sits above the meter bar (a 24 px
  bar cannot fit them beside a 24 px face); the tag line is two lines;
  sprites keep square texels (a 1-cell sprite is 0.85 of a cell's screen
  width); a missed shot still spends ammo. `tools/check.sh` runs the M1
  and M2 scripted runs plus all host tests. Next: hardware gate (still
  pending), then M3 bugs (AI, projectiles, damage, death freeze).
- 2026-09-27: Adrian's Mac cannot compile the cart (`error: OutOfMemory`
  from the compiler, m0 through m2, same pinned Zig; the bugs cart builds).
  Bisected on the `mac-bisect` branch to the comptime level parser (inlining
  the text instead of `@embedFile` did not help; a literal level did). The
  Linux compile peaks at 350 MB virtual either way, so it is a macOS
  compiler defect, not memory. Fix: levels are generated on the host into
  `cart/src/levels/gen.zig` (committed) by `tools/gen_levels.sh`; tests
  parse mini-levels at run time; the comptime nibble checks became a
  runtime `debug_nibble_ok`. Adrian pulls artifacts from the VM meanwhile.
- 2026-09-27: M3 plan written; pre-work committed; four tracks launched.
- 2026-09-27: M3 done and tagged `m3`. All four tracks landed. ELF text
  89.2 KB, bss 16.9 KB, GameState still 1,368 bytes. Host tests: sim 22,
  ai 9, projectiles 5, rewind 7, level_parse 4 (49 in the largest
  aggregate run). Bench (modelled): Build Farm opening mean 2.61 ms,
  worst 3.85 ms of 16.7 (23%); see the gnat run below. Deviations: enemies
  spawn `.idle` and AI treats "idle without the awake bit" as dormant;
  `Enemy.dir` holds attack cooldowns except for wasps; per-kind stop
  distances; melee and teleport require line of sight; the boss spit fan
  deals 8 (the spit kind), not 10; `#` noise shapes play as sawtooth and
  sweeps step every 3 ticks (tone2 has neither). Balance is untuned: three
  gnats take 65 HP in 7 s in the Build Farm opening (SPEC values); tune in
  M5 from play, the knobs are the `tuning` table in ai.zig. Test level key
  chain fixed (coral -> iris -> gold). Next: M4 rewind wiring.
- 2026-09-29: M4 plan written; worktree `snouty-badge-snoutenstein`, two
  tracks launched.
- 2026-09-29: M4 done and tagged `snoutenstein/m4`. Both tracks landed.
  ELF text 92.1 KB, bss 90.7 KB (the rewind pools are referenced now:
  74 KB, incl. 3.8 KB of commit patches). Host tests: rewind 8 (51 in the
  aggregate run). Bench (calibrated, `m4_rewind.json`, 360 frames): mean
  2.21 ms, worst 5.48 ms (33% of budget) at frame 289, a keyframe-boundary
  refill during the rewind (29 `step`s); the entry burst at frame 240 is
  4.53 ms. Bug found by the scripts and fixed in the core (deviation from
  "rewind.zig used as is"): a commit's meter drain and rewind-count bump
  were written into the live state after `commit`, so the first keyframe
  self-check after every rewind fired. `commit(s, meter, count_rewind)`
  now records them as a patch keyed by tick on the input log; replay
  applies patches, keyframes stay pre-patch, and a commit drops the
  patches of the abandoned future. Other deviations: the B press itself
  steps back one tick (a tap out of death lands on the last living tick);
  `debug_tick`/`debug_gameplay_hash` report the shown state while
  rewinding; the death rewind in `m4_death.json` is meter-bound (600 of
  642 ticks), not history-bound; the rewind sweep cuts the death-freeze
  sting. `check.sh` asserts `debug_desync == 0` on every run and runs the
  rewind harness on the walk script. Hardware gate still pending. Next:
  M5 attract/demo (a demo is a keyframe plus an input log, the machinery
  exists), balance, polish.
- 2026-09-29: M5 plan written; worktree branch `snoutenstein-m5`; tracks B
  and C launched, A follows B.
- 2026-09-29: M5 done and tagged `snoutenstein/m5`. All three tracks landed.
  ELF text 92.7 KB (+0.6 KB: demo player, takeover, 48 runs = 192 bytes of
  log), bss 90.7 KB unchanged, GameState still 1,368 bytes. Host tests: ai
  48 (gnat opening x2, Heisenbug duel, separation x2 new), demo 3, rewind 56
  in the aggregate run. Demo: 3,644 ticks (60.7 s) of Build Farm, all nine
  gnats, the Coral key, a 240-tick rewind from 36 HP, ends at 60 HP facing
  the exit; final hash 0xFAB416D6; the cart shows DEMO OK on the title after
  replaying it (DEMO DESYNC would mean the badge's sim diverged from the
  simulator: that readout is the SPEC 9.3 hardware test, Adrian reads it
  off the badge). Bench (calibrated): Build Farm opening unchanged at mean
  2.45 ms, worst 3.56 ms (21%); title idle plus the first 900 demo ticks (`m5_attract.json`, 1,500 frames) mean 2.78 ms, worst 5.08 ms (30%) at frame 1,240, the cable-tray fight. XIP build links.
  Balance (host-measured, hardware feel pass deferred): gnats 2 HP every 60
  ticks at 0.04 (standing among three: 68 HP after 7 s; zapping: 88);
  Heisenbug takes no pain state (its 12-tick pain matched the zapper
  cooldown, so a held A stunlocked it: the duel test found it), spits only
  beyond 2.5 cells, melee 10 every 60 (stand-and-shoot player wins at 52 HP,
  15/45 left 17); chasers keep 0.5 cells apart (about 13 us per tick for
  nine gnats, 0.2 ms worst with 40 awake). Deviations: the demo rewind is
  240 ticks, not 180 (the slower gnats cannot take enough HP for a 3 s
  rewind to show a recovery); the demo skips the hotfix; the takeover
  press is consumed (a held button is not an edge on the next tick, so B
  out of a demo death needs a second press); the neopixel gate is the
  cart-local `neopixels_allowed` constant, not yet the shared `-Dneopixels`
  option (docs/NEOPIXELS.md awaits Adrian's go; that file lives in the main
  checkout, not on this branch; since replaced by `-Dneopixels`, default
  off); the death scripts now die at tick 3028 and
  run 3,300/3,710 frames. Deferred (needs a badge): boss and gnat feel, the
  fourth weapon, the M1 render readout. Fragile: any sim change moves the
  demo (re-record with `tools/record_demo.sh`; `check.sh` fails until then).
- 2026-09-29: M5.1 balance follow-up tagged `snoutenstein/m5.1` (table
  above): enemies hurt again at Adrian's request, demo re-recorded, bench
  unchanged (the sim is not where the frame time goes).
- 2026-09-29: M5.2 (`snoutenstein/m5.2`): attract demo moved to
  Production, secret doors with Build Farm's hidden spray can, M6 Debugger
  planned above. Test level gained a secret door too (`m5_secret.json`
render check). check.sh now reads the demo level from the data file.
- 2026-09-29: M6 plan confirmed by Adrian ("Let's build the debugger gun");
  pre-work committed, three tracks launched (A sim, B art + levels, C
  render/HUD/audio) in worktree branch `snoutenstein-m6`.
- 2026-09-29: M6 done and tagged `snoutenstein/m6`. All three tracks landed
  as contracted (corrections listed under M6 above). ELF text 96.0 KB
  (+3.3 KB: three weapon cells, the bolt/burst code, two audio rows), bss
  91.0 KB (GameState 1,372 bytes, +4 x 52 keyframes). Host tests: sim 57,
  projectiles 57, ai 57, rewind 65 in the aggregate runs (9 new: bolt
  spawn, wall burst in the last floor cell, 3-cell burst kills two gnats
  and spares one 2.04 cells out, exact 12 on a beetle with a 6-tick flash,
  player untouched at 0.5 cells and by a bolt flying through, ttl expiry
  without a burst, four-way Select, `&` pickup 3/3/3/3 capped at 9 with no
  reselect, 48-tick cadence). Script `m6_debugger.json` on the test level:
  the `&` at (5, 5) is taken at tick 97 (weapon 3, 3 charges), the first
  bolt bursts on the adjacent gnat at tick 202 (one kill, burst visible 6
  ticks), the second flies 5 cells to the west wall; `check_determinism`
  passes on it. Demo re-recorded on Production: 4,108 ticks, final tick
  3,687 (its rewind), ends alive at 74 HP, hash 0x636B911C (DEMO OK in
  check.sh). Bench (calibrated): `m6_debugger.json` mean 2.91 ms, worst
  5.72 ms (34%) at frame 206, the point-blank burst sprite filling the
  view; Build Farm opening unchanged (worst 3.50 ms, 21%). Art adds no
  colour to any sheet (weapons and pickups stay 15/15). Level nooks:
  Staging `X` (12, 4) south off the first pipe corridor, `&` (12, 5);
  Production `X` (35, 21) in the monitor hall's south wall (texture 8, the
  6 walls are one cell thick everywhere), `&` (35, 22) and `+` (36, 22),
  before the Gold door. Deviations: the burst is a display-only
  projectile kind (`kind_burst`) so the sprite pass and audio detect it
  by diffing GameState; a burst that kills plays the death sound, not the
  thump (equal priority); a bolt fired while standing closer than 0.4
  cells to a facing wall spawns inside it and bursts there (the damage is
  unaffected, the burst sprite is hidden in the wall; enemy shots have
  always done this); pickup and door indices after the new cells shifted
  in Staging, Production and the test level (no script used them).
  Deferred to hardware as before: weapon feel, boss balance with the
  Debugger (7 bursts kill the Heisenbug; the player at 3 to 6 cells trades
  bursts for spit). Next: Adrian's review of M1-M6 in the simulator; no
  cart milestone is planned beyond M6.
- 2026-10-02: death-loop fix (Adrian: "once you take enough damage in a mob
  ... you die, get prompted to rewind, briefly rewind with your available
  budget, die again, etc."). Cause: the 3 s death reserve lands back in
  the same mob at the HP it had then (a tap out of death: the last living
  tick, 4 HP), so the next bite kills again. Fix: leaving a rewind out of
  death alive revives the player, `rewind.revive`: `player.grace` = 120
  ticks without damage or web freeze (`sim.death_grace`, one of Player's
  two pad bytes, so GameState stays 1,372 bytes and the demo hash holds)
  and HP topped up to `sim.death_hp_floor` = 25. Both go in the commit
  tick's patch (Patch gained `hp` and `grace`), so replays and the
  keyframe self-check agree. HUD: HP text and portrait frame blink Iris
  during the grace. Tests: sim grace unit test; rewind "death revive" runs
  the Build Farm mob (tap out of death without revive dies in < 60 ticks,
  revived lasts >= 300 even without aiming, reserve + revive survives
  600); m3_death asserts HP >= 25 and grace 120 after the rewind. bss
  93.5 KB (+2.5 KB patch ring).
