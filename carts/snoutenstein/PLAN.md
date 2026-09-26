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
