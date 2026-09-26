# Plan: Snouty vs. the Bugs

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
`SPEC.md` is the design; this file is the execution plan per milestone and
the contracts the parallel tracks build against. Status at the bottom.

## M1 Flying (started 2026-09-26)

Goal: playable in the simulator. Parallax background on placeholder tiles,
ship with banking poses and thruster, zapper, gnats in sine strings,
bolt-vs-gnat and gnat-vs-hitbox collisions, score. Boots to the M0 title
card; A, B or Start begins a game. A minimal lives counter is included so a
play session ends (lives 0 returns to the title) instead of running forever.
Everything else from SPEC.md sections 5 to 11 (other enemies, enemy bullets,
bombs, graze, explosions on the player, audio, neopixels) is M2 or later.

### Tracks (run in parallel, disjoint files)

| Track | Owner        | Files                                                            |
|-------|--------------|------------------------------------------------------------------|
| A art | Opus agent   | `tools/prepare_assets.py`, `assets/gen/*.png` (same sizes as now) |
| B code| Opus agent   | `cart/src/*.zig` (everything except `packed_int_array.zig`)      |
| C tools| Opus agent  | `tools/preview.mjs`, `docs/RUNNING.md` section 5                 |
| lead  | this session | `build.zig`, `PLAN.md`, `SPEC.md` status, `docs/*.gif`, commits, tag |

Agents do not commit; the lead commits per track. `build.zig` already lists
every M1 sheet, so neither A nor B edits it. Track A only changes pixels
inside PNGs whose dimensions are fixed below, so B compiles against the
stand-ins committed with this plan and A's better placeholders (and later
the real art) drop in with no code change.

### Asset contract (assets/gen/, consumed as `gfx.<basename>`)

All 4-bit. `transparent = true` means alpha 0 is flattened to magenta
`#FF00FF`, which the converter maps to palette index 0 and `draw.zig` skips.
Sheets are horizontal strips of equal cells, frame 0 left, cell top-left is
the anchor. At most 15 opaque colors per sheet (16 for the opaque far layer).

| File             | Sheet px | Cell   | Frames | Transparent | Contents                                                |
|------------------|----------|--------|--------|-------------|---------------------------------------------------------|
| `ship.png`       | 96x24    | 32x24  | 3      | yes         | 0 level, 1 bank up, 2 bank down. Faces right.           |
| `thruster.png`   | 32x8     | 8x8    | 4      | yes         | flame loop, 3 ticks per frame                           |
| `bolt.png`       | 32x8     | 16x8   | 2      | yes         | zapper bolt, 2 ticks per frame flicker, Coral core      |
| `bugs_small.png` | 32x8     | 8x8    | 4      | yes         | 0-1 gnat wing loop (4 ticks/frame), 2-3 round bullet    |
| `fx_small.png`   | 128x16   | 16x16  | 8      | yes         | 0-4 explosion (3 ticks/frame), 5-7 spark (2 ticks/frame) |
| `hud.png`        | 32x8     | 8x8    | 4      | yes         | 0 Snouty head (life), 1 bomb, 2 empty bomb, 3 heart     |
| `bg_far.png`     | 256x120  | n/a    | 1      | no          | opaque, tiles horizontally; low contrast                |
| `bg_near.png`    | 256x24   | n/a    | 1      | yes         | tiles horizontally; drawn over the far layer at y 104   |
| `iris_16.png`    | 16x16    | 16x16  | 1      | yes         | already present, from snouty-badge                      |

Ship constants the code hard-codes until the real sheet reports its own
(then only these two lines in `player.zig` change):

- hitbox: cell-relative top-left (14, 9), size 6x6
- thruster cell top-left relative to the ship cell: (-6, 8)

### Gameplay numbers for M1 (from SPEC.md, repeated so B needs no lookup)

- Play area y 8..127; HUD row y 0..7 in Anti-Black `#16031B`.
- Far layer scrolls 1 px every 4 ticks, near layer (y 104..127) 1 px every
  2 ticks, 24 procedural 1 px stars in two speeds between them.
- Ship speed 1.5 px/tick both axes, not normalised. Clamp the cell to
  x in [0, 104] and y in [10, 125 - 24] (2 px margin inside the play area).
- Banking pose from joystick y with 6-tick hysteresis.
- Zapper: A held fires one bolt every 6 ticks. Bolt 4 px/tick, cell 16x8,
  spawns at the ship's nose (cell x+28, y+8), pool 24, dies at x >= 160 or on
  hit. Bolt hitbox = the cell.
- Gnat: cell 8x8, HP 1, 1.0 px/tick left, sine wobble amplitude 8 period 40
  ticks around its spawn y, strings of 5 with 12-tick spacing, 10 points.
  Spawn x 168. Dies off screen at x < -8. Enemy pool 24. Hitbox = the cell.
- M1 spawner (`waves.zig`): a looping table, spawn y from the seeded PRNG in
  [16, 104]: t=0 string at y=40, t=0 string at y=80, then every 150 ticks
  one string at a random y, every third string doubled at y and y+32.
- Collisions: bolt AABB vs gnat cell (bolt dies, gnat dies, spark at the bolt
  tip, explosion at the gnat, +10). Gnat cell vs ship hitbox 6x6: gnat dies
  with an explosion, ship takes a hit (only when not invulnerable).
- Hit: 120 ticks of invulnerability, ship drawn every other tick, hitbox drawn
  as a 1 px cream dot while invulnerable; lives 3 -> 0 returns to TITLE.
- Score 6 digits at x=0 in the built-in font, capped at 999,999. Lives shown
  as up to 3 `hud.png` frame-0 icons right-aligned in the HUD row.
- Start toggles PAUSED ("PAUSED" over the frozen frame, every other pixel
  black). Select does nothing yet.
- Game seed: `cart.micros_since_boot()` truncated at the moment A/B/Start is
  pressed on the title. On wasm `micros_since_boot` may be constant; that is
  fine for M1.

### Code layout for M1 (track B)

```
cart/src/
  main.zig      start/update, state machine TITLE/PLAYING/PAUSED, update order,
                wasm shims (present_wasm, read_controls), debug exports
  input.zig     Controls snapshot + previous for edge detection (pressed/held)
  draw.zig      draw_sprite(sheet, cell_w, cell_h, index, x, y, opts) with index-0
                transparency, clipping, optional every-other-pixel skip and
                white flash; draw_bg (two scrolling layers + stars); text helpers
  rng.zig       xorshift32: seed(), next(), range(lo, hi)
  player.zig    ship state, movement, banking, invulnerability, lives
  bullets.zig   bolt pool (enemy bullet pool declared, unused in M1)
  enemies.zig   enemy pool, Kind enum, gnat program, hit flash timers
  waves.zig     M1 spawner table
  collide.zig   AABB helpers, bolts vs enemies, enemies vs hitbox
  fx.zig        spark/explosion pool
  hud.zig       HUD row, title card (from M0), pause overlay
```

Update order per tick: read controls -> state machine -> spawner -> player ->
enemies -> bolts -> collisions -> fx -> draw (bg far, stars, bg near,
enemies, ship + thruster, bolts, fx, HUD) -> present.

Fixed pools, no allocation, no libm at runtime (comptime sine table of 256
entries), f32 positions, tick-based timing, `zig fmt` clean. Never call
`cart.rand()` from gameplay.

Debug exports (wasm only, `if (cart.is_wasm)` at comptime) so the headless
harness can assert on game state without pixel matching:

```
export fn debug_state() u32     // 0 TITLE, 1 PLAYING, 2 PAUSED
export fn debug_score() u32
export fn debug_lives() u32
export fn debug_enemies() u32   // live enemies
export fn debug_bolts() u32     // live bolts
```

### Harness contract (track C, `tools/preview.mjs`)

- `--press` accepts `BTN:T1-T2` items, comma separated, BTN in
  `A B START SELECT UP DOWN LEFT RIGHT` (case-insensitive); a bare `T1-T2`
  still means A. Bits follow `cart.Controls`: start 0, select 1, a 2, b 3,
  click 4, up 5, down 6, left 7, right 8. Click is never set.
- `--script inputs.json`: `[{ "from": 0, "to": 59, "hold": ["A", "UP"] }, ...]`
  inclusive tick ranges, OR-ed with `--press` and `--controls`.
- `--dump-exports name[,name...]`: after the run, call each zero-arg export
  and record its i32 result in `frames.json` under `exports` and on stderr.
- `--expect name OP value` (repeatable, OP in `== != < <= > >=`): evaluated
  against those exports at the end; any failure exits 3 with a message.
- `--quiet`: no per-frame PNGs (only `frames.json`), for soak runs.

### Verification for M1

```
zig build
node tools/preview.mjs zig-out/bin/snouty-bugs.wasm --frames 1800 --every 6 --out out/ \
  --script tools/scripts/m1_play.json \
  --dump-exports debug_state,debug_score,debug_lives,debug_enemies \
  --expect "debug_state == 1" --expect "debug_score > 0"
python3 tools/make_gif.py out/ docs/preview_m1.gif --scale 3 --ms 100
```

`tools/scripts/m1_play.json` presses A on the title at tick 30, then holds A
with up/down sweeps so bolts hit gnats. A second script pauses and unpauses.
The lead runs both after tracks B and C land, plus an `.elf` size check
(`size zig-out/firmware/snouty-bugs.elf`, budget 160 KB text+data) and a
look at every 60th frame for clipping or palette mistakes.

### Hand-off

Tag `m1`, `docs/preview_m1.gif`, `docs/RUNNING.md` updated, SPEC.md status
line, and the "pull and run" note in the final message.

## Status

- 2026-09-26: M0 scaffold committed. M1 plan written; stand-in sheets
  committed so the code track compiles from the first minute.
