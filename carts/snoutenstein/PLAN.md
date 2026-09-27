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
node tools/preview.mjs zig-out/bin/snoutenstein.wasm --frames 900 --every 6 --out out/ \
  --script tools/scripts/m1_walk.json \
  --dump-exports debug_mode,debug_tick,debug_px,debug_py,debug_angle,debug_render_us \
  --expect "debug_mode == 1" --expect "debug_px > 393216"
python3 tools/make_gif.py out/ docs/preview_m1.gif --scale 3 --ms 100
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
