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
bombs, graze, explosions on the player, audio) is M2 or later.

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
| `hud.png`        | 48x8     | 12x8   | 4      | yes         | 0 Snouty head (rewind stock; 12x8 since 2026-09-29), 1 bomb, 2 empty bomb, 3 heart |
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
node ../../tools/preview.mjs zig-out/bin/snouty-bugs.wasm --frames 1800 --every 6 --out out/ \
  --script tools/scripts/m1_play.json \
  --dump-exports debug_state,debug_score,debug_lives,debug_enemies \
  --expect "debug_state == 1" --expect "debug_score > 0"
python3 ../../tools/make_gif.py out/ docs/preview_m1.gif --scale 3 --ms 100
```

`tools/scripts/m1_play.json` presses A on the title at tick 30, then holds A
with up/down sweeps so bolts hit gnats. A second script pauses and unpauses.
The lead runs both after tracks B and C land, plus an `.elf` size check
(`size zig-out/firmware/snouty-bugs.elf`, budget 160 KB text+data) and a
look at every 60th frame for clipping or palette mistakes.

### Hand-off

Tag `m1`, `docs/preview_m1.gif`, `docs/RUNNING.md` updated, SPEC.md status
line, and the "pull and run" note in the final message.

## M2 Bullet hell (started 2026-09-26)

Goal: the full bullet hell without the boss. Step 0 is the `World`
refactor from SPEC.md section 13.1, done as a single track on its own so
the M1 frames prove it is behaviour-neutral. Then three parallel code and
art tracks fan out against the new layout (below the contract). At the end
of M2: all five enemy kinds, enemy bullets that know who fired them, bombs,
graze, explosions, the rewind stock in the HUD (a hit spends a rewind and
grants invulnerability; the real rewind is M4), death when the stock is
empty, and a looping spawner that exercises every kind.

### World refactor contract (step 0 of M2)

- New `cart/src/world.zig`:

  ```zig
  pub const World = struct {
      game_tick: u32,
      rng: u32,
      input: struct { current: cart.Controls, previous: cart.Controls },
      player: player.State,     // x, y, pose, pose_age, fire_cooldown, invuln, score
      enemies: [24]enemies.Enemy,
      bolts: [24]bullets.Bolt,
      enemy_bullets: [96]bullets.EnemyBullet,
      fx: [16]fx.Fx,
      waves: waves.State,       // cursor t, stage/loop counters
      bg: draw.BgState,         // scroll tick, star positions
  };
  pub var w: World = .{ ... };
  ```

  Plain data only: no pointers, no slices, no `undefined` padding that
  would break a byte compare (use `= 0` defaults everywhere; the identity
  test compares bytes). Fields may be added freely in later milestones as
  long as they are plain data.
- Modules keep their names and functions; module-level `var`s move into
  the sub-structs above and the functions read `world.w.<field>`. `reset()`
  functions become default values on the struct, so `new_game` is
  `w = .{}` plus the seed.
- Kept outside `World` (in `main.zig`): `state`, `tick_total`, `rewinds`,
  `bombs`, best score, sound toggle. These are meta-state a rewind must not
  touch.
- `simulate()` gains a `Mode` parameter, `.live` or `.silent`; audio
  calls check it. M2 has no audio yet, so this is one enum and a
  guard in the one place effects will be emitted.
- Behaviour is unchanged: the M1 scripts must produce identical
  `frames.json` export values and the `m1_play.json` GIF must be pixel
  identical before and after the refactor. That is the whole test.
- `@sizeOf(World)` is printed by a wasm debug export `debug_world_size()`
  so the keyframe budget in SPEC.md 13.1 is checked against reality.

The rest of M2 (all five enemies, `patterns.zig`, enemy bullets with a
`source: Kind` field, bombs, graze, HUD rewind stock, hit = spend a rewind
and grant invulnerability) is planned in the usual three tracks once step 0
has landed.


### Tracks after step 0 (run in parallel, disjoint files)

| Track  | Owner        | Files                                                                                  |
|--------|--------------|----------------------------------------------------------------------------------------|
| A art  | Opus agent   | `tools/prepare_assets.py` (draw_bugs, draw_fx_big), `assets/gen/bugs.png`, `assets/gen/fx_big.png`, `docs/placeholders.png`, ASSETS.md section 10 |
| B1 bugs| Opus agent   | `cart/src/enemies.zig`, `cart/src/patterns.zig` (new), `cart/src/waves.zig`             |
| B2 ship| Opus agent   | `cart/src/player.zig`, `bullets.zig`, `collide.zig`, `fx.zig`, `hud.zig`, `main.zig`, `world.zig` (field additions only) |
| C tools| Opus agent   | `tools/preview.mjs`, `tools/scripts/m2_*.json`, `tools/check.sh`, `docs/RUNNING.md` section 5 |
| lead   | this session | `build.zig` (done: `bugs.png`, `fx_big.png` rows), `PLAN.md`, `SPEC.md` status, `docs/preview_m2.gif`, commits, tag `m2` |

Stand-in `bugs.png` (160x16, 10 cells) and `fx_big.png` (192x32, 6 cells) are
committed with this plan so B1/B2 compile from the first minute; track A
replaces the pixels at the same sizes. B1 and B2 meet only at the
interfaces below; where B2 needs a type B1 owns (or vice versa) the contract
names it and neither side changes it without telling the lead.

### Interfaces between B1 and B2

Owned by B1 (`enemies.zig`), read by B2:

```zig
pub const Kind = enum(u8) { gnat, wasp, beetle, spider, moth, boss }; // boss reserved for M3
pub const Enemy = struct {
    active: bool = false, kind: Kind = .gnat, delay: u32 = 0,
    x: f32 = 0, y: f32 = 0,          // cell top-left
    hp: u8 = 1, flash: u8 = 0, age: u32 = 0,
    // B1 adds whatever plain-data program state it needs (base_y, vx, vy,
    // phase, timer, target_x, target_y, fire_cooldown ...), all defaulted.
    pub fn live(e: Enemy) bool;      // active and delay == 0
    pub fn size(e: Enemy) [2]f32;    // 8x8 gnat, 16x16 others, 48x48 boss
    pub fn points(e: Enemy) u32;     // 10, 30, 50, 40, 40, 500
    pub fn hittable(e: Enemy) bool;  // false while the boss flickers (M3); true in M2
};
pub const sin_table: [256]f32;       // sin(2 pi i / 256); cos(a) = sin(a + 64)
pub fn spawn(kind: Kind, x: f32, y: f32, delay: u32) ?*Enemy; // one enemy; spider: y is ignored, x is its column
pub fn spawn_gnat_string(y: f32) void;   // kept from M1
pub fn update() void;                    // move + fire (fire goes through patterns.zig into bullets)
pub fn draw_enemies() void;              // includes the spider thread (vline from y 8 to the spider)
pub fn live_count() u32;
```

Owned by B2 (`bullets.zig`), called by B1's `patterns.zig`:

```zig
pub const Shape = enum(u8) { round, needle };   // round: bugs_small cells 2-3 (pulse, 4 ticks/frame); needle: bugs cell 8
pub const EnemyBullet = struct {
    active: bool = false,
    x: f32 = 0, y: f32 = 0,          // CENTER of the bullet
    vx: f32 = 0, vy: f32 = 0,
    shape: Shape = .round,
    source: enemies.Kind = .gnat,    // who fired it (SPEC.md 5.1 messages, M4)
    grazed: bool = false,
    age: u32 = 0,
};
/// Returns false when the pool (96) is full; the shot is dropped.
pub fn spawn_enemy_bullet(x: f32, y: f32, vx: f32, vy: f32, shape: Shape, source: enemies.Kind) bool;
pub fn clear_enemy_bullets() void;       // bomb
pub fn live_enemy_bullets() u32;
```

Owned by B1 (`patterns.zig`), helpers B1 uses from every fire program (B2
does not call these). Angles are in 1/256 turns so the sin table is used
directly; `aim` needs `@sqrt` (an FPU instruction on the badge; no libm):

```zig
pub fn aimed(x: f32, y: f32, speed: f32, shape: bullets.Shape, source: Kind) void;          // straight at the ship hitbox center
pub fn spread(x: f32, y: f32, n: u32, step_256: u32, speed: f32, shape, source) void;        // n bullets centered on the aim direction, `step_256` apart
pub fn ring(x: f32, y: f32, n: u32, phase_256: u32, speed: f32, shape, source) void;         // full ring starting at `phase_256`
pub fn arc(x: f32, y: f32, n: u32, span_256: u32, speed: f32, shape, source) void;           // n bullets over `span_256` centered on the aim direction
```

Owned by B2 (`collide.zig`), consumed by `main.zig` (B2) and by M4:

```zig
pub const HitBy = enum(u8) { none, enemy, bullet };
pub const Hit = struct { by: HitBy = .none, kind: enemies.Kind = .gnat, index: u8 = 0 };
pub fn run() Hit;             // bolts vs enemies, bullets vs hitbox (+graze), enemies vs hitbox. `.none` if unhurt or invulnerable
pub fn kill(e: *enemies.Enemy) void;         // explosion + score + deactivate (pub for the bomb)
```

### Gameplay numbers for M2 (from SPEC.md 5, 6, 9, 10)

Enemies (B1). Spawn x is 168 for everything but the spider. Enemies die
off screen once they have been on screen (x < -16, x > 176, y < -16 or
y > 144), never before entering. Cell centers are the emitter positions.

- Wasp 16x16, HP 1, 30 pts: enters at 2.5 px/tick left; at x <= 120 it
  stops for 20 ticks (drawn, hittable), then charges at 2.5 px/tick along the
  vector to the ship hitbox center captured on the last pause tick. No fire.
- Beetle 16x16, HP 4, 50 pts: 0.5 px/tick left to x = 112, sits 240 ticks,
  then leaves left at 0.5. While sitting, every 45 ticks (first at tick 45
  of sitting): `spread(3, 12/256 turn apart, 1.0 px/tick, round)`.
- Spider 16x16, HP 2, 40 pts: `spawn(.spider, column_x, _, delay)` puts it
  at (column_x, -16). Drops 1.5 px/tick to a hang y drawn from the world rng
  in [24, 72] at spawn time, hangs 180 ticks, climbs 1.5 px/tick, dies at
  y < -16. Thread: `cart.vline` in `draw.star_dim`, x = cell x + 8, from y 8
  to the cell top. While hanging, every 30 ticks: `arc(5, 96/256 turn, 0.8,
  round)`.
- Moth 16x16, HP 2, 40 pts: every 30 ticks picks a new target from the
  world rng, x in [80, 144], y in [16, 104]; moves toward it at 1.2 px/tick
  (stops when within 1.2 px). Every 20 ticks: `aimed(1.5, needle)`. After
  600 ticks on screen its targets are x = -40 (it leaves).
- Gnat as M1 (`spawn_gnat_string`), 10 pts, no fire.
- All programs are plain data in `Enemy`; no per-kind allocation. The
  spawn functions draw from `rng` only inside `spawn`/`update` so the
  order of rng calls is deterministic per tick.

Spawner (B1, `waves.zig`): the SPEC.md section 9 stage-1 table as data,
`Entry = struct { at: u32, kind: Kind, y: i16 (or `random` = -1), count: u8 = 1, spacing: u8 = 0 }`,
through the 54 s entry; at 66 s (3960 ticks) the table wraps to 0 (M3
inserts the warning and the boss there and adds the loop counter).
Gnat entries spawn strings; `count` for other kinds spawns that many with
`spacing` ticks of delay. Random y is drawn from the world rng in [16, 104]
(spider: column in [64, 136]). `waves.State` = `{ t: u32 = 0, next: u8 = 0 }`.

Player, bullets, collisions (B2):

- Enemy bullets move by (vx, vy) each tick, die when the center is outside
  x in [-4, 164) or y in [4, 132). Drawn on top of everything but fx and
  the HUD. Round hitbox 6x6 centered; needle hitbox 8x4 centered. Drawing:
  cell top-left = center - (4, 4), round frame `2 + (age / 4) % 2`.
- Graze: a live bullet whose hitbox (expanded by 4 px on each side) touches
  the ship hitbox without the unexpanded box touching it sets `grazed` and
  adds 1 point once. Count grazes in `player.State.grazes` for the debug
  export. No visual in M2.
- Hit result: bullets first, then enemies; first contact wins, one hit per
  tick, nothing when invulnerable. A bullet that hits is deactivated. An
  enemy that rams dies (`kill`).
- Rewinds replace lives: `main.zig` keeps `rewinds: u32 = 3` (meta-state,
  not in the World). A hit with `rewinds > 0`: `rewinds -= 1`, `invuln =
  120` (M4 replaces this branch with the rewind sequence). A hit with
  `rewinds == 0`: state DYING, 60 ticks: the ship is not drawn, a big
  explosion (`fx_big`, 32x32, 6 frames x 4 ticks) plays at the ship center,
  enemies and bullets do not move and enemies do not fire, fx and the
  background keep running; then TITLE (GAME OVER screen is M5). Extra rewind
  at 10,000 points and every 20,000 after, max 5.
- Bombs: `main.zig` keeps `bombs: u32 = 2` and `next_bomb_score: u32 =
  5000` (meta-state). B pressed in PLAYING with `bombs > 0` and no bomb
  active: `bombs -= 1`, `player.bomb_timer = 30`. On that tick: every enemy
  bullet is cleared; every live non-boss enemy is `kill`ed (score counts);
  `invuln = @max(invuln, 30)`. While `bomb_timer > 0`: ticks 30..27 the
  background is replaced by a flat `draw.cream` rect; a ring is drawn
  centered on the hitbox center with radius `r = (30 - bomb_timer) * 7`
  (`cart.oval` stroke, Anti-White) and a second ring at `r - 3` in Coral.
  Max 3 bombs; +1 when the score crosses `next_bomb_score` (then +5000).
- Invulnerability after a hit stays 120 ticks (M1 value) and the hitbox dot
  stays. Bomb invulnerability is 30.
- HUD: score 6 digits at x 0; three bomb slots centered at x 68, 76, 84
  (`hud` cell 1 filled, cell 2 empty); rewinds as `hud` cell 0 right-aligned,
  up to 5. Colors and the pause overlay as M1.
- Draw order: bg (or the flat flash), enemies (+ thread), ship + thruster,
  bolts, enemy bullets, fx, bomb ring, HUD.
- Debug exports added in `main.zig` (wasm only): `debug_rewinds`,
  `debug_bombs`, `debug_bullets` (live enemy bullets), `debug_grazes`,
  `debug_bomb_timer`. `debug_lives` stays and returns `rewinds`.
  `debug_state`: 0 TITLE, 1 PLAYING, 2 PAUSED, 3 DYING.

### Harness (C)

- `--at T name OP value` (repeatable): an expectation evaluated right after
  update number T (0-based, so T = the tick just simulated) instead of at
  the end; same OP set as `--expect`. Failures are collected and reported
  like `--expect`, exit 3. `--call-at T name` records an export value at
  tick T into `frames.json` under `calls` (for M4's identity check).
- Scripts: `m2_bomb.json` (start at 30, hold A, sit still so the 8 s beetle
  fires, press B at tick 720; expect `debug_bullets == 0` at 720 and
  `debug_bombs == 1`), `m2_hit.json` (start, no fire, no movement: a gnat
  string at y 40 or the 14 s wasp hits; expect `debug_rewinds < 3` by tick
  1500 and `debug_state == 1`), `m2_death.json` (same, 6000 ticks; expect
  `debug_state == 0` at the end, i.e. died and returned to the title, with
  `debug_rewinds == 0` seen along the way via `--at`), `m2_play.json`
  (m1_play with B presses at 900 and 2400, 4000 ticks, expects score > 570).
- `tools/check.sh`: builds and runs every `tools/scripts/*.json` with its
  expectations (one line per script in the file header comment or a
  sidecar `.args`), exit non-zero on any failure. This is the regression
  gate from M2 on.
- `docs/RUNNING.md` section 5: the new flags and scripts.

### Verification for M2

`tools/check.sh` green; `docs/preview_m2.gif` from `m2_play.json` (4000
ticks, every 6); ELF text+data still far under 160 KB; `debug_world_size`
reported in the status line for the M4 keyframe budget (target: at or
below 6 KB); a look at frames around the beetle spread, spider arc, moth
needles, a bomb and a death for clipping, draw order and palette mistakes.
Balance pass: if the 14 s to 54 s stretch is unsurvivable without bombs in
the lead's hands, halve bullet speeds before tagging and note it.

## M3 Stages and boss (started 2026-09-26)

Goal: the stage loop and the Heisenbug. At 66 s the table goes quiet and
"WARNING" flashes for 3 s; at 72 s the boss enters; when it dies the stage
is cleared (+500, +1 bomb, "STAGE n"), the table restarts with the loop
modifiers from SPEC.md section 9. Stand-in `boss.png` (240x48, 5 cells)
and `title.png` (128x40, for M5) are committed with this plan; track A
redraws them in place.

### Tracks (run in parallel, disjoint files)

| Track  | Owner        | Files                                                                                  |
|--------|--------------|----------------------------------------------------------------------------------------|
| A art  | Opus agent   | `tools/prepare_assets.py` (draw_boss, draw_title), `assets/gen/boss.png`, `assets/gen/title.png`, `docs/placeholders.png`, ASSETS.md section 10 |
| B1 boss| Opus agent   | `cart/src/enemies.zig`, `cart/src/patterns.zig`, `cart/src/waves.zig`                  |
| B2 flow| Opus agent   | `cart/src/main.zig`, `hud.zig`, `player.zig`, `collide.zig`, `fx.zig`, `bullets.zig`, `world.zig` (fields only) |
| C tools| Opus agent   | `tools/scripts/m3_*.json` + `.args`, `docs/RUNNING.md` section 5 (preview.mjs only if needed) |
| lead   | this session | `build.zig` (done), `PLAN.md`, `SPEC.md` status, `docs/preview_m3.gif`, commits, tag `m3` |

### Interfaces between B1 and B2

Owned by B1, read or called by B2:

```zig
// enemies.zig
pub const DamageResult = enum(u8) { alive, killed, boss_dying };
/// Applies `amount` HP of damage. `.killed`: the caller runs collide.kill
/// (explosion, score, deactivate). `.boss_dying`: B1 has started the boss
/// death sequence itself (60 ticks; explosions, +500 via player.add_score,
/// waves stage clear at the end); the caller does nothing more.
pub fn damage(e: *Enemy, amount: u8) DamageResult;
pub fn boss() ?*Enemy;            // the boss while active (entering, fighting, teleporting or dying), else null
pub fn boss_max_hp() u32;         // 60 + 20 * loop
// Enemy.hittable(): false while the boss flickers, is vanished, or is dying.

// waves.zig
pub const StagePhase = enum(u8) { waves, warning, boss, cleared };
pub const State = struct {
    t: u32 = 0, next: u8 = 0,
    loop: u8 = 0,                  // completed stages (drives the modifiers)
    phase: StagePhase = .waves,
    stage_clears: u8 = 0,          // monotonic; B2 awards a bomb when it grows
    clear_tick: u32 = 0,           // game_tick when the last boss died (0 = never)
};
pub fn warp_to_warning() void;     // debug: jump t to the 66 s mark (wasm test hook, called by B2's debug export)
pub fn speed_mul() f32;            // 1.1^loop capped so speed * mul <= 2.0 is the caller's job: use `bullet_speed(base)`
pub fn bullet_speed(base: f32) f32;   // base * 1.1^loop, capped at 2.0
pub fn fire_interval(base: u32) u32;  // base * 0.9^loop, floored at base / 2
pub fn extra_hp() u8;              // = loop, added to beetle and spider HP at spawn
```

Owned by B2, called by B1: nothing new. B1 keeps using `bullets.spawn_enemy_bullet`,
`fx.spawn(.explosion | .big_explosion, cx, cy)` and `player.add_score`.

Owned by B2 (`collide.zig`, `player.zig`): every place that removes HP now
calls `enemies.damage` and switches on the result (`.alive` -> flash 2,
`.killed` -> `kill`, `.boss_dying` -> nothing). The bomb calls `damage(boss, 8)`
and kills every other live enemy as before. A ramming boss is never killed.

### Gameplay numbers for M3 (SPEC.md 7 and 9)

Stage flow (B1, `waves.zig`): the table runs as in M2. At t = 3960 (66 s)
`phase = .warning`; at t = 4320 (72 s) `phase = .boss` and
`enemies.spawn(.boss, 168, 40, 0)`. While `phase == .boss`, `t` keeps
counting but nothing spawns. When the boss death sequence ends B1 sets
`stage_clears += 1`, `clear_tick = game_tick`, `loop += 1`, `phase =
.cleared`, and after 120 ticks of `.cleared` (a breather) resets `t = 0`,
`next = 0`, `phase = .waves`. Loop modifiers: `bullet_speed`, `fire_interval`
and `extra_hp` above, applied at spawn/fire time by every fire program
(gnat/wasp have none). Use a comptime table of 8 multipliers, no `pow`.

Boss (B1, `enemies.zig`, kind `.boss`, cell 48x48, HP `60 + 20 * loop`,
500 pts): enters from x 168 at 1.0 px/tick to x = 104, then bobs: cell y =
`base_y + 32 * sin(2 pi * age / 240)` with `base_y` = 40 (center y 64),
clamped so the cell stays within y in [8, 80]. Every 300 ticks of fighting:
`.flicker` 20 ticks (drawn as cell 4 with `skip_odd`, not hittable, no
fire), then `.vanished` 20 ticks (not drawn, not hittable), then reappears
at x in [96, 112] and `base_y` in [24, 56] from the rng and resumes. Fire,
three phases of 240 fighting ticks each, cycling, paused while not
fighting:

1. Ring: `ring(12, phase, bullet_speed(0.8), round)` every
   `fire_interval(40)` ticks; `phase += 11` (about 15 degrees) per volley.
2. Aimed stream: every `fire_interval(60)` ticks, 3 `aimed(bullet_speed(1.5),
   needle)` shots 8 ticks apart; plus `spread(5, 12, bullet_speed(0.6), round)`
   every `fire_interval(90)` ticks.
3. Spiral: one round bullet every `fire_interval(4)` ticks at angle
   `spiral_angle`, `spiral_angle += 8` (about 11 degrees) per shot,
   `bullet_speed(1.0)`. Needs a single-shot helper in `patterns.zig`:
   `pub fn shot(x, y, angle_256: u32, speed, shape, source)`.

Boss idle animation: cells 0..3, 6 ticks per frame. Emitter = cell center.
Death (B1): `.dying` 60 ticks: not hittable, no fire, no movement; every 10
ticks a small explosion at a rng offset inside the body (6 in total); at
tick 60 the big explosion at the center, `player.add_score(500)`, the enemy
deactivates and the stage clear above fires. Boss bullets in flight are
untouched (the player still has to dodge them; the bomb clears them).

Flow, HUD, hooks (B2):

- `main.zig` meta-state `stage_clears_awarded: u8`; when `w.waves.stage_clears`
  exceeds it, `bombs = @min(bombs + 1, 3)` and it catches up. Reset in
  `new_game`.
- `hud.zig`: while `phase == .warning`, "WARNING" centered at y 56 in
  Coral, visible 20 ticks of every 40. Boss HP bar while `enemies.boss()`
  is non-null and not dying: a 2 px bar at y 8..9 from x 8 to 151 (144 px),
  Anti-Black track, Coral fill `144 * hp / boss_max_hp()` from the left.
  After a clear: "+500" centered at y 56 in Anti-White for 60 ticks from
  `clear_tick`, then "STAGE n" (n = loop + 1) for the next 60 ticks.
- Debug exports (wasm only): `debug_stage` (= loop), `debug_boss_hp` (0 when
  no boss), `debug_stage_clears`, `debug_phase` (StagePhase as int), and two
  test hooks: `debug_god()` toggles a meta flag that makes `on_hit` ignore
  hits (bullets still vanish on contact), `debug_warp()` calls
  `waves.warp_to_warning()`. Both return the new value (god flag / t).
- Bomb: `damage(boss, 8)`; everything else as M2.

### Harness (C)

- `m3_boss.json` + `.args`: A at 30, `--call-at "31 debug_god"`, `--call-at
  "32 debug_warp"`, then the m2_play sweep holding A. Expect `debug_phase ==
  1` (warning) shortly after the warp, `debug_boss_hp > 0` once the boss has
  entered (about 72 s mark + 64 ticks of entry), `debug_stage_clears == 1`
  and `debug_stage == 1` by the end, `debug_bombs == 3` (2 + the clear).
  Frames of the ring, stream and spiral phases and of the death sequence.
- `m3_loop.json` + `.args`: continue past the clear; expect `debug_enemies
  > 0` again after the 120-tick breather and `debug_phase == 0`.
- `m3_bomb_boss.json`: god + warp, wait for the boss, press B; expect
  `debug_boss_hp` to drop by 8 across the press tick (two `--call-at`s).
- Update `docs/RUNNING.md` section 5 and keep `tools/check.sh` green.

### Verification for M3

`tools/check.sh` green (nine scripts); `docs/preview_m3.gif` from
`m3_boss.json` around the boss (frames 4300..6000, every 6); ELF text+data;
`debug_world_size`; a look at the three fire phases, a teleport and the
death sequence for clipping and readability (the boss must never hide a
bullet: bullets draw above it). Boss HP bar and warning legible at 3x.

## M4 Rewind (started 2026-09-26)

Goal: SPEC.md 5.1 and 13.1. A hit with a rewind in stock freezes the game
for 20 ticks with a bug report naming the enemy kind, plays the last 120
game ticks backward over 60 frames, restores the world 120 ticks before
the hit, grants 60 ticks of invulnerability and a `GO!` pop, and hands
control back. The identity test proves restore is exact.

### Decisions fixed here (deviations from SPEC.md 13.1, to be reflected there)

- **Bomb stock moves into the World** (`player.State.bombs`, and the
  `next_bomb_score` threshold with it). The bomb *action* is simulated
  inside the world (B pressed is in the input log), so with the stock
  outside, a catch-up replay would re-spend a bomb that was already spent
  live and the identity test would fail. Consequence, which we accept and
  will tell Adrian: a bomb used inside the rewound two seconds is refunded
  along with the bullets it cleared. The stage-clear bomb award and the
  5,000-point award also happen inside the world (`award_extras` for
  bombs moves into the simulation). `god` stays meta.
- **Rewind stock stays meta** (a rewind can never refund itself), so the
  10,000/20,000-point rewind grants happen only in `.live` mode and only
  once per threshold: `next_rewind_score` lives in the World (so replays
  are deterministic) and `main.zig` keeps `rewind_award_high_water: u32`
  (meta): grant when the world crosses a threshold that is above the high
  water, then raise it. Crossing the same threshold again after a rewind
  grants nothing.
- **A hit leaves the offender alive.** `collide.run` no longer deactivates
  the bullet that hit the ship or kills the enemy that rammed it; it only
  reports `Hit { by, kind, index }`. `main.on_hit` decides: rewind (the
  restore wipes everything anyway), or death / god mode (then main
  deactivates the bullet or `kill`s the non-boss enemy exactly as M3 did,
  so the M3 scripts keep their values).
- Input during REWIND is ignored except Select and the OS combos; Start
  cannot pause a rewind.

### Tracks (run in parallel, disjoint files)

| Track  | Owner        | Files                                                                                  |
|--------|--------------|----------------------------------------------------------------------------------------|
| A core | Opus agent   | `cart/src/history.zig` (new), `main.zig`, `world.zig`, `player.zig`, `collide.zig`, `input.zig`, `rng.zig` |
| B show | Opus agent   | `cart/src/rewind.zig` (new), `hud.zig`, `draw.zig`, `bullets.zig`, `enemies.zig` (draw-only additions), `fx.zig` |
| C tools| lead         | `tools/scripts/m4_*.json` + `.args`, `docs/RUNNING.md`, `docs/preview_m4.gif`         |
| lead   | this session | `PLAN.md`, `SPEC.md` (13.1 bombs note, status), commits, tag `m4`                       |

### Interface A -> B (A calls, B implements; B draws only, never simulates)

```zig
// rewind.zig (B)
pub const report_ticks: u32 = 20;       // hit-stop with the bug report
pub const playback_frames: u32 = 60;    // frames of reverse playback
pub const ticks_per_frame: u32 = 2;     // game ticks stepped back per frame (120 total)
pub const resume_invuln: u32 = 60;
pub const go_ticks: u32 = 30;
pub fn message(kind: enemies.Kind) []const u8;   // OFF BY ONE, RACE CONDITION, OUT OF MEMORY, DEADLOCK, ACCESS VIOLATION, UNDEFINED BEHAVIOR
/// Over the frozen, fully drawn scene + HUD: red dot on the hitbox, the
/// offender (w.enemy_bullets[hit.index] or w.enemies[hit.index]) drawn
/// again in flash-white, the Anti-Black bar y 52..67 with `message(hit.kind)`
/// centered at y 56 in Coral. `age` is 0..report_ticks-1.
pub fn draw_report(hit: collide.Hit, age: u32) void;
/// Over the restored, fully drawn scene + HUD, frame 1..playback_frames:
/// every other scanline black (`draw.darken_scanlines`), the same bar and
/// message, and `<<` blinking (on 8 of every 16 frames) over the HUD
/// center (cover x 60..99 of the HUD row in Anti-Black first).
pub fn draw_playback(hit: collide.Hit, frame: u32) void;
/// The bar and message only (used by DYING and, in M5, GAME OVER).
pub fn draw_bar(kind: enemies.Kind) void;
/// "GO!" centered at y 56 in Anti-White; `ticks_left` counts go_ticks down.
pub fn draw_go(ticks_left: u32) void;

// draw.zig (B)
pub fn darken_scanlines() void;         // every odd screen row black, full width
// bullets.zig (B): pub fn draw_enemy_bullet(b: EnemyBullet, opts: draw.SpriteOpts) void
// enemies.zig (B): pub fn draw_enemy(e: Enemy, opts: draw.SpriteOpts) void  (used by draw_enemies too)
```

`player.State.go_pop: u32` (A adds, decremented in `player.update`); main
calls `rewind.draw_go(w.player.go_pop)` while it is > 0. A's `main.zig`
draws the scene and the HUD, then calls the B overlay for the current
phase. B does not touch `world.w` except to read it.

### Interface A (history.zig) used by main.zig and the harness

```zig
pub const keyframe_count = 4;
pub const keyframe_every: u32 = 60;
pub const log_len = 256;
pub const State = struct {                 // module-level `var`, NOT in the World (history is not rewound)
    keyframes: [keyframe_count]world.World, // slot = (tick / 60) % 4
    keyframe_tick: [keyframe_count]u32,    // invalid = 0xFFFF_FFFF
    log: [log_len]u16,                     // controls used for tick t at log[t % 256]
};
pub fn reset() void;                       // new game: all keyframes invalid
/// Called at the top of `simulate(.live)`: log[game_tick] = current controls;
/// if game_tick % 60 == 0, keyframes[slot] = w, keyframe_tick[slot] = game_tick.
pub fn record() void;
/// Oldest tick a restore can reach (the oldest valid keyframe's tick).
pub fn earliest_tick() u32;
/// Copies the newest valid keyframe at or before `tick` into w, then for t
/// in kf.tick+1 .. tick-1: input.update(log[t]); simulate(.silent); ends
/// with w.game_tick == tick. Requires earliest_tick() <= tick <= w.game_tick
/// and tick - kf.tick <= 255 (log coverage); returns false if impossible.
pub fn restore(tick: u32) bool;
/// Drops keyframes with tick > `tick` (the future that was rewound away).
pub fn invalidate_after(tick: u32) void;
/// Field-by-field comparison (comptime reflection over structs, arrays,
/// enums, bools, ints, floats). Padding bytes are NOT compared.
pub fn worlds_equal(a: *const world.World, b: *const world.World) bool;
```

The keyframe at tick K is saved after `input.update` for tick K, so the
replay applies `input.update(log[t])` only for t > K. `simulate` must be
callable from history.zig: A moves the per-tick simulation into a
`pub fn simulate(mode)` (in `main.zig`, imported by history, or into a
new `sim.zig` if the import cycle is awkward). In `.silent` mode:
no `history.record`, no `on_hit`, no rewind grants, no audio (M6).

State machine (`main.zig`, A): `State` gains `rewind = 4`. Meta:
`rewind_hit: collide.Hit`, `rewind_hit_tick: u32`, `rewind_target: u32`,
`rewind_age: u32`. `on_hit` with `rewinds > 0`: `rewinds -= 1`,
`rewind_hit_tick = w.game_tick` (the tick just simulated + 1, i.e. the
current game_tick), `rewind_target = @max(hit_tick -| 120, earliest_tick())`,
`state = .rewind`, `rewind_age = 0`. Each REWIND tick: age < 20: freeze
(no simulate), draw scene + HUD + `draw_report`; 20 <= age < 80: frame k =
age - 19 (1..60), `history.restore(@max(hit_tick - 2k, target))`, draw
scene + HUD + `draw_playback`; age == 80: `history.restore(target)` (a
no-op if already there), `history.invalidate_after(target)`, `w.player.invuln
= resume_invuln`, `w.player.go_pop = go_ticks`, `state = .playing`. The
resumed tick reads live controls as usual. DYING draws `rewind.draw_bar`
with the fatal kind.

Debug exports (A, wasm only): `debug_history_check() u32` (copy w aside,
`restore(w.game_tick)`, `worlds_equal` -> 0 if identical, 1 if not, 2 if
restore refused), `debug_game_tick`, `debug_rewind_target`,
`debug_earliest_tick`. `debug_state`: 4 = REWIND. Keep every existing
export; `debug_bombs` reads the world now.

### Harness (C, lead)

- `m4_identity`: `m2_play.json` with `--at "T debug_history_check == 0"` at
  T = 300, 777, 1500, 2241 (just after a bomb), 3333, 3999; and the same on
  `m3_boss.json` (boss, teleport, death in history).
- `m4_rewind`: `m2_hit.json` input (idle ship; the beetle's spread hits at
  about 750): `--at` checks that `debug_state == 4` shortly after the hit,
  `debug_rewinds == 2`, `debug_state == 1` 80 ticks later, `debug_game_tick`
  after the resume == hit tick - 120 (pinned value), and the score after
  the resume equals the score 120 ticks before the hit (pinned via
  `--call-at`). Then a second hit after the invulnerability ends rewinds
  again (rewinds 1) with a target inside the previous replayed segment.
- `m4_early`: a hit before tick 120 (a script that flies straight into the
  first gnat string) rewinds to tick 0 and resumes.
- `m4_god_bomb`: the M3 scripts keep passing unchanged (god path unchanged;
  bombs read from the world).
- GIF of one rewind (ticks 700..900 of `m4_rewind`, every 2) in
  `docs/preview_m4.gif`.

### Verification for M4

`tools/check.sh` green (all scripts, including the identity checks);
`docs/preview_m4.gif`; ELF text+data (the four keyframes are RAM, not
flash: check `.bss` grows by about 17 KB and nothing else); hardware:
the FPS overlay during a rewind with the bullet pool near full must read
60 (Adrian, on the badge; fallbacks in SPEC.md 13.1).

## M5 Rewind bar (started 2026-09-27)

Goal: SPEC.md 5.2 and 5.3. The bomb is gone. B held in PLAYING rewinds the
world live, 2 game ticks per frame, paid from a fuel bar that refills slowly
during live play, a little per graze, and fully on a stage clear. A hardcore
mode, chosen with B on the title, has no rewind stock: a hit auto-rewinds as
far as fuel allows, and a hit with fuel under the fatal floor is death.
Adrian confirmed the M4 timing (20 freeze + 60 playback + 60 invulnerable)
on 2026-09-27; it does not change. Attract mode moves to M6, polish to M7,
because the autopilot must drive the hold-B rewind instead of a bomb.

### Decisions fixed here

- **Fuel is meta** (`main.zig`), never in the World. A manual rewind moves
  the World's clock, so fuel inside the World would be restored with it and
  every rewind would be free. Same reasoning as the rewind stock. Grants
  from world events use the high-water pattern of `award_rewinds`:
  `graze_high_water` and `clear_high_water` in main; a grant happens live
  only, for a world count above the high water, then the high water rises.
  This also dissolves the M4 bomb-refund question: nothing in the World
  spends anything any more.
- **Refill only on live simulated ticks** (PLAYING). Never in pause, the
  bug-report freeze, playback, a manual rewind, or DYING.
- **The B press frame does not simulate a tick.** B (meta rising edge) in
  PLAYING enters MANUAL and performs its first step in the same frame, so a
  tap is exactly 2 ticks. The hold continues while B is held. Running out
  of fuel or history mid-hold resumes with B still down; a fresh press is
  needed to rewind again, so fuel trickling back cannot jitter the world.
- **Resume from MANUAL**: `history.invalidate_after(game_tick)`,
  `history.checkpoint()`, no invulnerability, no `GO!`. The player chose
  the moment. Joystick, A and Start are ignored during the hold.
- **Fuel charged = ticks actually rewound.** Manual: 2 per frame; a step
  needs `fuel >= 2` and `game_tick - 2 >= history.earliest_tick()`, so an
  odd remnant of 1 fuel stays and refills.
- **Hardcore on a hit**: `fuel < fatal_floor` is death (DYING as today; the
  dying bar names the bug, then says `UNRECOVERABLE`). Otherwise `depth =
  min(120, fuel, hit_tick - earliest_tick())`, `fuel -= depth`, and the
  rewind runs as in M4 with that depth. No death loop is possible: every
  iteration costs at least the floor, and the only refill between a resume
  and the next hit is 1 per 10 live ticks, so a player who is hit again
  right after the invulnerability has strictly less fuel each time and dies
  within a few hits. A player who lasts long enough to refill 45 is not
  looping.
- **Playback length follows depth**: `rewind_frames = (depth + 1) / 2`, so
  a 120-tick rewind still plays 60 frames (m2_hit pins hold) and the
  54-tick rewind of m4_early plays 27 (its pins move). Normal mode is
  otherwise unchanged: the auto rewind is free of fuel, lives and fuel are
  independent resources.
- **Title**: A or Start starts a normal game, B a hardcore one. `hardcore`
  is meta, set by `new_game`.
- **HUD layout** (B): score x 0..47; a status slot x 48..63 (`<<` during
  any rewind playback, auto or manual); the fuel bar x 68..99 (Anti-White
  1 px frame x 68..99, y 1..6; inner fill 30x4 at x 69..98, y 2..5, Coral,
  width `fuel * 30 / fuel_max` rounded down but at least 1 px while fuel
  > 0; in hardcore the fill is red while `fuel < fatal_floor`); rewinds as
  right-aligned icons as before, or `HARD` in Coral at x 128 in hardcore.
  `<<` leaves the HUD center so the bar stays visible during playback.
- **Bombs removed everywhere**: player stock, timer, awards and
  `try_bomb`; the fx ring and flash; `bullets.clear_enemy_bullets`; HUD
  slots; exports `debug_bombs` and `debug_bomb_timer`; scripts `m2_bomb`
  and `m3_bomb_boss`; the B entries in `m2_play` and `m4_identity`.
  `hud.png` frames 1 and 2 stay in the sheet unused (ASSETS.md notes them
  free for reuse). The boss loses nothing: bolts were always the main
  damage source.

### Numbers (SPEC.md 5.2, 5.3)

| Quantity               | Value                                  |
|------------------------|----------------------------------------|
| `fuel_max`, start fuel | 180 ticks (3 s)                        |
| Refill                 | +1 fuel per 10 live ticks (`fuel_refill_every`) |
| Graze                  | +2 fuel per graze (`graze_fuel`)       |
| Stage clear            | fuel = `fuel_max`                      |
| Manual step            | 2 ticks per frame (`rewind.ticks_per_frame`) |
| Auto depth, normal     | 120, free                              |
| Auto depth, hardcore   | min(120, fuel), charged                |
| `fatal_floor`          | 45 ticks                               |

### Tracks (run in parallel, disjoint files)

| Track   | Owner        | Files                                                                                     |
|---------|--------------|-------------------------------------------------------------------------------------------|
| A core  | Opus agent   | `cart/src/main.zig`, `player.zig`, `fx.zig`, `bullets.zig`, comment lines in `world.zig`, `enemies.zig`, `waves.zig` |
| B show  | Opus agent   | `cart/src/hud.zig`, `rewind.zig`, `draw.zig` (helpers only)                               |
| C tools | Opus agent, after A and B land | `tools/scripts/*` (delete, re-pin, add m5_*), `docs/RUNNING.md`, `docs/preview_m5.gif` |
| lead    | this session | `PLAN.md`, `SPEC.md`, `ASSETS.md`, `README.md`, commits, tag `m5`                          |

### Interface A -> B (A calls, B implements; B draws only, never simulates)

```zig
// hud.zig (B)
/// HUD row per the layout above. `rewinds` is ignored when `hardcore`.
pub fn draw_hud(rewinds: u32, fuel: u32, fuel_max: u32, fatal_floor: u32, hardcore: bool) void;
/// Title card: "A PLAY" at y 92 and "B HARDCORE" at y 104 (both blinking
/// like the old "PRESS A", B line in Coral) replace "PRESS A"; the rest as M0.
pub fn draw_title(tick: u32) void;

// rewind.zig (B)
pub const report_ticks: u32 = 20;       // unchanged
pub const playback_frames: u32 = 60;    // now the MAXIMUM; main passes the actual count
pub const ticks_per_frame: u32 = 2;     // shared by auto playback and the manual hold
pub const resume_invuln: u32 = 60;
pub const go_ticks: u32 = 30;
pub fn draw_report(hit: collide.Hit, age: u32) void;      // unchanged
/// As M4, but `<<` blinks in the status slot (Anti-Black patch x 48..63,
/// then "<<" at x 48, y 0 in Coral); the fuel bar is left visible.
pub fn draw_playback(hit: collide.Hit, frame: u32) void;
/// Over the restored scene + HUD during a hold-B rewind, `frame` 1.. since
/// the hold began: `draw.darken_scanlines` and the same `<<` blink. No bar.
pub fn draw_manual(frame: u32) void;
/// DYING bar. `age` 0..59: `message(kind)` while age < 30, then
/// "UNRECOVERABLE" (13 chars) in the same bar and colour. Normal mode keeps
/// calling `draw_bar(kind)`.
pub fn draw_fatal_bar(kind: enemies.Kind, age: u32) void;
pub fn draw_bar(kind: enemies.Kind) void;                 // unchanged
pub fn draw_go(ticks_left: u32) void;                     // unchanged
```

`fx.draw_bg_or_flash` and `fx.draw_bomb_ring` go away (A); `draw_scene`
calls `draw.draw_bg()` directly. B must not reference `player.bombs`,
`bomb_timer` or `gfx.hud` frames 1 and 2.

### State machine and meta-state (A, `main.zig`)

`State` gains `manual = 5`. New meta: `fuel: u32`, `fuel_acc: u32` (live
ticks toward the next refill), `graze_high_water: u32`,
`clear_high_water: u32`, `hardcore: bool`, `manual_frame: u32`,
`rewind_frames: u32` (playback frames of the auto rewind in progress).
`new_game(hardcore)` resets them (fuel full) and sets `rewinds` to
`start_rewinds` in normal mode, 0 in hardcore.

- TITLE: A or Start -> `new_game(false)`; B -> `new_game(true)`.
- PLAYING: Start -> PAUSED. Else if `input.meta_pressed(.b)` and
  `can_step()` -> `state = .manual`, `manual_frame = 0`, `manual_step()`.
  Else `input.update(c)`, `simulate(.live)`.
- MANUAL: if `input.meta.current.b` and `can_step()` -> `manual_step()`;
  else `manual_resume()`.
- `can_step()`: `fuel >= ticks_per_frame and game_tick >=
  history.earliest_tick() + ticks_per_frame`.
- `manual_step()`: `history.restore(game_tick - ticks_per_frame)` (a false
  return resumes instead), `fuel -= ticks_per_frame`, `manual_frame += 1`.
- `manual_resume()`: `history.invalidate_after(game_tick)`,
  `history.checkpoint()`, `state = .playing`.
- `simulate(.live)`, after the tick: refill (`fuel_acc += 1`; at
  `fuel_refill_every` reset it and `fuel = min(fuel + 1, fuel_max)`), graze
  grant (`fuel += graze_fuel * (grazes - graze_high_water)` capped, then
  raise the high water) and the clear refill (`stage_clears >
  clear_high_water` -> `fuel = fuel_max`, raise). All three live only.
- `on_hit`, normal mode: as M4 (`rewinds > 0` -> rewind of depth 120, else
  DYING). Hardcore: as decided above; `rewinds` stays 0.
- `step_rewind` uses `rewind_frames` in place of `rewind.playback_frames`.
- DYING draws `rewind.draw_fatal_bar(fatal_kind, dying_len - dying_ticks)`
  in hardcore, `rewind.draw_bar` otherwise. MANUAL draws the scene, then
  `rewind.draw_manual(manual_frame)`.
- `debug_history_check` treats `.manual` like `.playing` (the world is a
  restored history state, so 0 is expected).

Exports (wasm): keep every existing one except `debug_bombs` and
`debug_bomb_timer`; add `debug_fuel`, `debug_hardcore` (0/1),
`debug_manual_frame`. `debug_state`: 5 = MANUAL.

### Harness (C, after A and B)

- Delete `m2_bomb` and `m3_bomb_boss`. Strip the B entries from
  `m2_play.json` and `m4_identity.json`, drop `debug_bombs` from every
  `.args`, and re-pin the values that moved (the runs change: the bombs
  used to clear the 2240 and 3380 waves). Keep the identity samples.
  `m3_boss.args` loses its `debug_bombs == 3` expectation. Re-pin
  `m4_early` for the 27-frame playback (resume at update 84 + 20 + 27 =
  131, `debug_game_tick == 0`, `debug_rewinds == 2`).
- `m5_manual`: the `m2_hit` input plus B held for 20 updates starting
  around 700 (before the beetle spread hits at 748). Pins: state 1 the
  frame before, 5 on the press frame, `debug_game_tick` 40 lower and
  `debug_fuel == 140` on release, state 1 the frame after release, and a
  `debug_history_check == 0` sample during the hold and one after. The
  idle ship then meets the spread again later (state 4 at a pinned tick).
- `m5_empty`: B held for 200 updates from 400: fuel reaches 0 after 90
  frames, state returns to 1 while B is still down, `debug_game_tick` is
  180 lower than at the press, and 100 updates later `debug_fuel == 10`.
- `m5_hardcore`: B at 30 on the title, `debug_hardcore == 1`,
  `debug_rewinds == 0`, idle. First hit at 748: state 4, `debug_fuel ==
  60` after the hit. The idle ship replays its fate: second hit rewinds by
  the fuel left (about 80 with refills), fuel 0; third hit, fuel under 45:
  state 3 then 0. Pin the ticks by running.
- `m5_graze`: hold B briefly early (fuel 160), then fly the `m2_play`
  sweep; pin `debug_fuel` at a tick where `debug_grazes > 0` and show it
  exceeds 160 plus the refill alone.
- `docs/preview_m5.gif`: a manual rewind, updates 690..760 of `m5_manual`,
  every 2 frames.

### Verification for M5

`tools/check.sh` green (all scripts, including the re-pinned M2..M4
ones); `docs/preview_m5.gif`; `@sizeOf(World)` shrinks (bomb fields gone);
ELF text within a few KB of M4. Adrian on hardware: the hold-B feel (2
ticks per frame), the refill rate, the hardcore floor.

## M6 Powerups (started 2026-10-02)

Adrian, 2026-10-02: "Snouty bugs needs fun powerups, like any great bullet
hell shooter": Raiden-style stacking weapon crates, reskinned as testing
tools, plus one twist only this game can do because it already records its
own history: the FORK, a ghost ship replaying the player's own trajectory a
second behind. Attract mode moves to M7, polish to M8. SPEC.md 5.4 has the
design; this section is the contract the tracks build against.

### Decisions fixed here

- **Everything a crate grants lives in the World** (weapon kind and level,
  forks, the retry shield, the crates themselves). A rewind therefore
  un-collects anything grabbed in the rewound window and un-forks the
  ghosts: Raiden's power loss, for free, from the honesty rule of 13.1.
  No extra level drop on a hit (the rewind already charges the player).
- **The one meta effect, CORE HOURS fuel**, is paid by `main.zig` against a
  high-water mark on a monotonic World counter (`player.cores`), exactly
  like graze fuel, so a crate rewound away and collected again pays once.
- **No new rng draws until a crate is collected.** Drop timing and crate
  kind are deterministic functions of World counters (kills, a drop
  sequence index), never of `rng`, so every existing script's world is
  unchanged up to the first collection. The fuzzer's level-5 jitter does
  draw from `rng` (world-deterministic, fine).
- **Base state = the current zapper.** Weapon kind FUZZER at level 1 fires
  exactly today's single bolt at today's cadence, so a run that collects
  nothing plays as M5 did.
- **Trail ring**: the ship's position is recorded every tick into an
  80-entry ring in the World whether or not a fork exists, so a fork has
  history to replay the moment it is collected and the ring rewinds with
  everything else.
- Pickups collide with the whole ship cell (32x24), not the 6x6 hitbox:
  collecting must feel generous.
- Bolt pool grows 24 -> 64; `@sizeOf(World)` may grow to ~7 KB (keyframes
  ~28 KB .bss, inside the 160 KB budget). Shots that do not fit are dropped,
  the ship's own volley spawning before the ghosts' so it has priority.
- Sound: no new effects (Adrian 2026-09-30: no audio development).

### Numbers (SPEC.md 5.4)

Weapons, all fired on A at the zapper cadence (one volley per 6 ticks),
`level` 1..5. The ship's volley originates at the nose, (x + 28, y + 8) as
today (bolt cell top-left for the zap; the other bolts are placed so their
hitbox center is at (x + 36, y + 12)).

| Kind   | Letter | Bolt | Speed | Damage | Volley per level 1..5 |
|--------|--------|------|-------|--------|------------------------|
| FUZZER | F | zap, 16x8, dies on hit | 4.0 | 1 | 1 straight; 2 straight (y -3, +3); 3-way (0, +-8/256 turn); 5-way (0, +-8, +-16); 5-way with +-4/256 random jitter per bolt (`rng`) |
| ASSERT | A | beam, 24 px long, pierces | 6.0 | 1 (L1-2), 2 (L3-4), 3 (L5) | 1 beam; 1; 2 beams (y -4, +4); 2; 3 beams (0, -6, +6). Thickness drawn 1, 1, 2, 2, 3 px; hitbox 24x4 centered |
| BISECT | B | seeker, 8x8 hitbox, dies on hit, homes | 3.5 | 1 | 1; 2; 3; 4; 5 seekers, initial angles alternating +-10/256 turn times i; steer gain 0.08 + 0.04 (level - 1) |

- Angles in 1/256 turns, vectors from `enemies.sin_table` (no libm).
  Screen y is down; "+-" offsets are symmetric so the sign does not matter.
- Pierce: a beam damages each enemy slot at most once (`hit_mask: u32`
  over the 24 enemy slots), a spark at each hit, and keeps going. Zap and
  seeker die on the first hit.
- Seeker steering, per tick: `t` = unit vector to the nearest live,
  hittable enemy's center (squared distance, pool order breaks ties);
  `v_hat = normalize(v_hat + gain * t)`, `v = v_hat * speed`. No target:
  straight on. `@sqrt` only.
- Bolt cull: x >= 160 or x < -24 or y < -8 or y >= 136.
- Crate on the same weapon: level + 1 (max 5; at max +500 points
  instead). Crate of another weapon: kind changes, level kept. Every
  collection also scores +100.
- FORK: `forks` 0..3; ghost k (1-based) is drawn at the trail entry of
  `game_tick - 24k` and fires the current weapon at its own nose whenever
  the ship fired 24k ticks ago (the trail entry's `fired` flag). Ghosts
  have no hitbox, collect nothing, and are drawn with `skip_odd`
  (checkerboard) without a thruster. A fourth fork crate: +500.
- RETRY: `shield` 0..1 (a second crate: +500). A hit with the shield up
  consumes it inside `simulate` (both modes): the offender is removed as
  in god mode, 60 ticks of invulnerability, `retry_pop = 60` ticks of
  `FLAKY, RETRYING` on the message line (the `GO!` row logic). No rewind
  or fuel is spent; meta never sees the hit. A 12x8 shield icon is drawn
  centered above the ship cell (y - 6) while the shield is up.
- CORE HOURS: `player.cores += 1`; `main.zig` adds 60 fuel per count above
  `cores_high_water` (capped at `fuel_max`).
- Crates: pool of 4 (`world.w.pickups`), 16x16 cell, spawned centered on
  the dropper's center, drifting left 0.5 px/tick with y = base_y + 6 *
  sin(age / 90 turn) clamped to the play area [16, 104] for the cell top;
  gone at x < -16. A drop with a full pool is lost.
- Drops (no rng): a Memory Leak beetle killed by a bolt; every 5th gnat
  killed by a bolt (`player.gnat_kills` counter); the boss's fire phase
  changing (every 240 fighting ticks, `fire_tick % 240 == 0` with
  `fire_tick > 0`); a ram kill (`remove_offender`) drops nothing. Crate
  kind from `drop_seq` (World, wraps at 8): [W, cores, W, fork, X, retry,
  W, fork], W = the ship's current weapon kind at drop time, X = the next
  kind after W cyclically (F -> A -> B -> F). So stacking is the default
  and a swap is on offer every eight crates.
- HUD: the status slot (x 48..63) shows the weapon as letter + level
  (`F3`) in Anti-White; `<<` still takes the slot during any rewind
  (rewind.zig already patches it Anti-Black first). Nothing else in the
  HUD changes.

### Tracks (run in parallel, disjoint files)

- **A: gameplay** (Opus). `bullets.zig` (Bolt rework, pool 64),
  `player.zig` (weapon state, volley, trail ring, forks, shield, ghost
  draw), `collide.zig` (pierce, damage amounts, drop hooks),
  `pickups.zig` (new), `world.zig`, `enemies.zig` (boss phase-change
  drop), `main.zig` (update/draw order, shield handling, cores fuel, debug
  exports), `hud.zig` (weapon slot), `rewind.zig` (retry pop text helper if
  needed). Builds against the placeholder `bolt.png` (2 cells) and
  `pickups.png` from track B; until B lands, A may generate stand-in
  sheets locally but must not commit them.
- **B: art** (Opus). `tools/prepare_assets.py`: `bolt.png` grows to 6
  cells 16x8 (0-1 zap as today, 2-3 beam segment, 4-5 seeker dart);
  new `pickups.png`, 6 cells 16x16 (fuzzer F, assert A, bisect B, fork,
  retry, core hours), crates with a 1 px border, readable at lanyard
  scale; `hud.png` cell 1 (a spare) becomes the retry shield icon. New
  `build.zig` image row for `pickups.png`; manifest, mockup and validator
  updated; `assets/gen/*.png` regenerated and committed; `ASSETS.md`
  section 7 rows.
- **C: harness and docs** (Opus, after A and B): new scripts
  `m6_pickup`, `m6_fork`, `m6_retry`, `m6_cores`, `m6_identity`
  (`debug_history_check == 0` with forks and beams in flight); re-pin the
  existing scripts where the sweep now collects crates; `docs/RUNNING.md`
  section for the crates; `tools/check.sh` green.

### Interface A exposes (for C and the HUD)

- `debug_weapon() -> kind * 10 + level` (kind 0 F, 1 A, 2 B),
  `debug_forks()`, `debug_shield()`, `debug_pickups()` (live crates),
  `debug_cores()` (World counter), `debug_drops()` (crates spawned this
  game, World counter), all wasm-only like the others.
- `debug_grant(n)` is NOT provided: scripts collect real crates (the
  first beetle dies at a known tick under constant fire).

### Deviations (A)

Track A, 2026-10-02. Choices where the contract was silent or ambiguous:

- `Bolt` carries one field beyond the contract, `gain: f32`: a seeker's
  steering gain is fixed at spawn from the level then, so a crate collected
  while seekers are in flight does not retune them.
- Bolt positions: (x, y) is the top-left of the 16x8 cell for zaps and
  seekers (both spawn at (x + 28, y + 8), so their centers are the nose,
  (x + 36, y + 12)) and of the 24x4 box for beams ((x + 24, y + 10) plus the
  level's y offset). The drawn beam (1-3 px) is centered in the 4 px box;
  its "coral flicker" is the tail third drawn Coral on alternate 2-tick
  frames. `bullets.bolt_hitbox(b)` gives each kind's box (the name
  `hitbox` is the enemy bullets').
- BISECT initial angles "alternating +-10/256 times i" read as a symmetric
  fan: 0, +10, -10, +20, -20 (1/256 turns) for seekers 1..5.
- Angle 0 is exactly (speed, 0) (no table lookup), so the level-1 zap moves
  bit-for-bit as the M5 zapper did; the L5 jitter can also land on 0.
- `trail[t % 80].fired` means the ship triggered a volley that tick, even
  if the full pool dropped every bolt of it. Ghost k fires only once
  `game_tick >= 24k` (no history to replay before that) and is drawn at
  the trail entry of the tick just simulated (`game_tick - 1 - 24k`), i.e.
  where it last fired from, in the ship's current pose, farthest first.
- The drop cursor and the crate count live in `world.w.drops`
  (`pickups.Drops{ seq, count }`), the crates in `world.w.pickups`. The
  cursor advances only when a crate actually spawns, so a drop lost to a
  full pool skips no kind of the sequence.
- Collection is tested inside `pickups.update` (after the crates move,
  before `collide.run`); a crate dropped by this tick's kill first moves and
  can first be collected on the next tick. The cell-top clamp to [16, 104]
  also applies to the spawn position. A crate that grants nothing more
  scores 100 + 500 = 600 (the +100 is on every collection).
- Beam pierce is per enemy SLOT: an enemy spawned into a slot that the
  beam already damaged is skipped by that beam too (harmless; beams live
  at most ~23 ticks).
- `FLAKY, RETRYING` is drawn in PLAYING only (as `GO!`), and the shield
  icon is drawn whenever the shield is up, also while the ship blinks.

### Verification for M6

- `tools/check.sh` all green; `debug_history_check == 0` on frames with
  ghosts, beams and crates in flight, during a hold-B rewind and after.
- A rewind that crosses a collection restores the earlier weapon level
  (pinned in `m6_pickup`).
- `@sizeOf(World)` reported; ELF `.text + .data` under 160 KB.
- badge-bench on `m6_fork` (3 ghosts, fuzzer 5) and `m3_boss`: worst
  frame under 16.7 ms with headroom.
- `docs/preview_m6.gif`: crates collected, ghosts, a beam, a retry.

## M7 Bullet hell for real (started 2026-10-04)

Adrian, 2026-10-04: "Snouty bughunt is way too easy currently. We need to
make this a true bullet hell shooter that has increasingly difficult and
complex attack patterns as the game goes on, take inspiration from the
greats like 1942 and RaidenX. Right now you basically have to try to get
hit, especially if you hold down the fire button. Now that we have
powerups, the player is especially overpowered."

Measured on origin/main e5d9e13 before any change (god mode, hits counted,
10,800 updates = 3 minutes): a ship that sweeps up and down holding A was
touched **once** and cleared two full stage loops; one that sits still at
the spawn point holding A was touched 20 times in the first minute, 0 times
in the first 30 s. The loop-0 boss has 60 HP and the ASSERT at level 5
deals about 90 a second, so it dies in under a second. Attract mode moves
to M8, polish to M9. SPEC.md 5.5 has the design summary; this section is
the contract.

### What changes, in one list

1. **Four stages instead of one looping table**, each with its own bugs,
   formations, a midboss (stages 2-4) and its own boss, then a second loop
   that is harder again. Stage names: 1 `UNIT TESTS`, 2 `INTEGRATION`,
   3 `STAGING`, 4 `PRODUCTION`.
2. **Rank** (Raiden / Battle Garegga): one World number 0..1000 that rises
   with the stage, the time spent in it, the loop and the player's
   firepower, and falls a little when the player is hit. It scales enemy
   bullet speed, fire rate, the number of bullets in a pattern, enemy HP,
   and turns on revenge bullets. A strong player gets a harder game; a
   struggling one gets some slack.
3. **A pattern engine.** Enemy bullets learn to accelerate, decelerate,
   curve, split and re-aim; two new shapes (pellet, orb); pool 96 -> 128;
   tighter hitboxes so the screen can hold far more bullets and still be
   fair (the bullet-hell bargain).
4. **New bugs** (1942 / Raiden staples, reskinned): a weaving centipede,
   fleas that jump in from *behind* the ship, ladybugs flying loops in from
   the top and bottom, ground mites riding the near layer like Raiden's
   tanks, zombies that revive once, a swarm midboss. Old bugs get real HP
   and fire on entry, so holding A no longer kills everything before it
   shoots.
5. **Three new bosses** plus a harder Heisenbug, each with HP-gated
   phases (bullet cancel and a crate at each break) and a timeout so a
   weak player is never stuck.
6. **Powerups cut down to size**: weapon damage rebalanced (ASSERT level 5
   was ~90 damage a second, now 40); ghosts fire a level-1 shot instead of
   the full volley; a hit that triggers the auto rewind also costs one
   weapon level and one fork (Raiden's power loss); crates come from whole
   formations (1942's POW) instead of every fifth gnat.
7. **A difficulty probe**: deterministic bots (turret, sweeper, dodger)
   played headlessly through all four stages in an endless god mode, so
   the difficulty curve is a table of numbers, not a feeling.

### Decisions fixed here

- **Rank lives in the World.** Every input to it (stage, loop, stage
  clock, weapon level, forks, a mercy counter) is World state, so a rewind
  rewinds the rank too and replays stay exact. It is computed, not stored,
  except `mercy`.
- **The power loss is applied at the resume of an auto rewind**, as a
  World edit right after `history.restore(rewind_target)`, next to the
  invulnerability grant, before `history.checkpoint()`. So it is honest
  (the rewound World is the 2-s-old one, then the cost is charged) and
  history sees it. Hold-B rewinds cost no power (fuel already pays). The
  retry shield costs no power. Hardcore pays it too.
- **Bullets scale with rank at spawn**, inside `bullets.spawn_shot`:
  content code writes base (rank 0) speeds and never multiplies by hand.
  Fire intervals and bullet counts are scaled explicitly by content with
  `rank.interval(base)` and `rank.extra(k)`.
- **No new rng in the bullet engine.** Splits, re-aims and turns are pure
  functions of the bullet and the ship position. Content may draw from the
  world rng (as moths and the Heisenbug already do), in pool order.
- **Bosses have a timeout** (Touhou's spell timer, simplified): each
  non-final phase ends after its time limit even with HP left (no crate
  for a timed-out phase), and the final phase ends after its limit with
  the boss escaping off the right edge (no +500, no fuel refill, the stage
  still advances). Nobody is ever stuck on a boss, and the probe always
  reaches the next stage.
- **Enemy HP becomes u16** (bosses go to the thousands).
- Sound: none (Adrian 2026-09-30).
- Perf: the bullet pool grows to 128 only if badge-bench keeps the worst
  frame of the stage-4 boss under 14 ms (84%) with a hold-B rewind in it;
  otherwise 112, then 96. Bullet drawing stays an 8x8 cell at most except
  the orb.
- RAM (SYCL is RAM carts only, ~274.7 KB for text + data + bss): the
  M6 cart is 92 KB. M7 must stay under 160 KB total; `@sizeOf(World)`
  grows to roughly 11 KB (5 copies: live + 4 keyframes).

### Rank (`rank.zig`, new, track A)

```
value = clamp(stage_base[stage] + 400 * loop + stage_seconds
              + 25 * (level - 1) + 30 * forks - mercy, 0, 1000)
stage_base = { 0, 150, 300, 450 }
stage_seconds = min(waves.t / 60, 120)       (resets at each stage start)
mercy (World u16): +80 at each auto-rewind resume, -1 every 120 ticks, >= 0
r = value / 1000
```

Effects (all functions of `r`, read at the moment of use):

| What | Formula | Where |
|------|---------|-------|
| Enemy bullet speed | base x (1 + 0.5 r), capped per shape: round 2.0, needle 2.6, pellet 2.2, orb 1.6 | `bullets.spawn_shot` and split / aim children |
| Fire interval | round(base x (1 - 0.4 r)), at least base / 2 and 1 | content: `rank.interval(base)` |
| Extra bullets | floor(r x (k + 1)), at most k | content: `n + rank.extra(k)` |
| Regular enemy HP | round(base x (1 + 0.6 r)), at least 1 | `enemies.spawn` via `rank.hp(base)` |
| Revenge bullets | on a bolt kill of a non-gnat when loop >= 1 or r >= 0.6, of a gnat when loop >= 1: one aimed pellet (3-way fan, 10/256 apart, when r >= 0.85) at base speed 1.0, only if the kill is more than 40 px from the hitbox center | `rank.revenge(kind, cx, cy)`, called from `collide` |

The loop modifiers in `waves.zig` (`speed_mul`, `bullet_speed`,
`fire_interval`, `extra_hp`) are deleted; rank replaces them. The pause
screen shows `RANK nnn` (0..1000) in the help box so a tester can see it.

### Bullet engine (track A: `bullets.zig`, `patterns.zig`)

`EnemyBullet` keeps its fields and gains:

```zig
pub const Shape = enum(u8) { round, needle, pellet, orb };
pub const Event = enum(u8) { none, split, aim };
// new fields, defaults = today's behaviour
drag: f32 = 1,       // v *= drag every tick (< 1 slows, > 1 speeds up)
vmax: f32 = 0,       // if > 0, |v| is clamped to it after drag and accel
ax: f32 = 0,         // added to v every tick
ay: f32 = 0,
turn: i8 = 0,        // heading += turn / 256 turn every tick ...
turn_left: u8 = 0,   // ... for this many ticks
event: Event = .none,
event_at: u16 = 0,   // the bullet's age at which the event fires
ev_n: u8 = 0,        // split: children; aim: bullets in the aimed fan (1 = just re-aim)
ev_speed: u8 = 0,    // child / re-aim base speed in 1/16 px per tick (rank-scaled when it fires)
gen: u8 = 0,         // split: children split again (same event_at, ev_n, ev_speed) while gen > 0
```

Per tick, in order: turn (rotate v by the table), drag, accel, vmax clamp,
move, age, event (if `age == event_at`), cull. Events:

- `split`: the bullet dies and leaves a ring of `ev_n` pellets at its
  position, the first along its heading (rotation of its unit velocity by
  `i * 256 / ev_n`, no atan2), speed `ev_speed / 16` rank-scaled. Children
  carry `split` with `gen - 1` while `gen > 0`. Children that do not fit in
  the pool are dropped.
- `aim`: velocity becomes `aim(x, y) * ev_speed / 16` (rank-scaled), drag
  1, accel 0, no more turning; with `ev_n > 1` the bullet itself is the
  middle of a fan of `ev_n` (8/256 apart) and the extra ones are spawned.
  Stop-and-go = `drag 0.94` plus `aim` at age 50.

Shapes and hitboxes (the bullet-hell bargain: smaller boxes, many more
bullets):

| Shape | Drawn | Hitbox (centered) | Art |
|-------|-------|-------------------|-----|
| round  | 6x6 ball in an 8x8 cell | 4x4 (was 6x6) | `bugs_small` cells 2-3, as today |
| needle | 8x4 | 6x2 (was 8x4) | `bugs` cell 8, as today |
| pellet | 4x4 dot in an 8x8 cell | 2x2 | `shots.png` cells 0-1 (new) |
| orb    | 12x12 in a 16x16 cell | 8x8 | `orb.png` cells 0-1 (new) |

The ship's hitbox shrinks from 6x6 to **4x4**, same center: offset
(15, 10) in the cell. The graze margin stays 4 px. The invulnerability
dot stays at the center.

API (old pattern signatures go; track A ports today's callers):

```zig
pub const Shot = struct {
    speed: f32,                 // base, rank 0
    shape: Shape = .round,
    source: enemies.Kind,
    drag: f32 = 1, vmax: f32 = 0,
    accel: f32 = 0,             // along the initial heading: ax, ay = dir * accel
    turn: i8 = 0, turn_left: u8 = 0,
    event: Event = .none, event_at: u16 = 0, ev_n: u8 = 0, ev_speed: u8 = 0, gen: u8 = 0,
};
// bullets.zig
pub fn spawn_shot(x: f32, y: f32, dir: [2]f32, shot: Shot) ?*EnemyBullet  // dir is a unit vector
pub fn cancel_all() u32       // every enemy bullet -> +10 score, spark fx for the first 8; returns count
// patterns.zig (x, y = emitter center; angles in 1/256 turns, 0 = right, 64 = down)
pub fn aim(x, y) [2]f32
pub fn aimed(x, y, shot)
pub fn fan(x, y, n, step_256, shot)        // aimed, n bullets step apart (the old `spread`)
pub fn arc(x, y, n, span_256, shot)        // aimed, n bullets over span, ends included
pub fn ring(x, y, n, phase_256, shot)
pub fn ring_aimed(x, y, n, shot)           // ring whose first bullet points at the ship
pub fn at_angle(x, y, angle_256, shot)     // the old `shot`
pub fn line(x, y, n, speed_step, shot)     // n aimed bullets, speeds speed + i * speed_step (a sniper line)
pub fn wall(x, y_top, y_bottom, n, gap_y, gap_half, shot) // n bullets evenly on a vertical line moving left (angle 128), skipping |y - gap_y| < gap_half
```

### Formations and drops (track A: `formations.zig`, new; `pickups.zig`, `collide.zig`)

1942's rule: shoot down the whole formation, get the POW.

- World `formations: [8]Formation{ id: u8 = 0 (free), size: u8, killed: u8, gone: u8, drop: bool }`,
  `next_formation_id: u8` (wraps, skips 0). `Enemy` gains `formation: u8 = 0`.
- `formations.open(size, drop) u8`: claims a free slot, returns its id (0 if
  none free: the enemies just have no formation).
- `formations.killed(id, cx, cy)`: on a bolt kill; when `killed == size`
  and `drop`: `pickups.spawn_drop(cx, cy)` plus 200 points; slot freed.
- `formations.lost(id)`: an enemy of it left the field or rammed the ship;
  the slot is freed once `killed + gone == size`, without a drop.
- Drop sources after M7: a completed formation with `drop`; every second
  Memory Leak beetle killed by a bolt (World counter); the midboss (two
  crates on death); each boss HP phase break (one crate; a timed-out phase
  gives none). The "every fifth gnat" rule is deleted. Crate kinds keep
  the M6 sequence.

### Player (track A: `player.zig`, `main.zig`)

Weapon volleys, single-target damage per volley (volley every 6 ticks):

| Level | FUZZER (unchanged geometry) | ASSERT (beams: y offset / damage) | BISECT (seekers, gain) |
|-------|------|------|------|
| 1 | 1 zap | 0/d1 | 1, 0.08 |
| 2 | 2 zaps (y -3, +3) | 0/d2 | 2, 0.10 |
| 3 | 3-way | -4/d1, +4/d1 | 2, 0.14 |
| 4 | 5-way | 0/d1, -6/d1, +6/d1 | 3, 0.16 |
| 5 | 5-way, jitter | 0/d2, -6/d1, +6/d1 | 4, 0.20 |

So a single target takes at most ~40 a second from the ship at level 5.

- **Forks fire a level-1 volley** of the current weapon (one zap, one d1
  beam, one seeker at gain 0.08) whenever the ship fired 24k ticks ago.
- **Power loss**: `player.on_rewound_hit()`, called in `main.step_rewind`
  at resume (normal and hardcore): `level = max(1, level - 1)`,
  `forks -|= 1`, `mercy += 80`. Not on hold-B, not on a shield pop.
- Endless probe mode (wasm `debug_probe`, toggles): like god mode, but a
  hit removes the offender, applies `on_rewound_hit()` in the World at
  once, grants 60 ticks of invulnerability and counts the hit; no rewind
  runs. Applied in both simulate modes (the flag is constant through a
  probe run, as `god` is) so the identity check still holds.

### Kinds, bosses, messages (track A defines, track B fills)

```zig
pub const Kind = enum(u8) { gnat, wasp, beetle, spider, moth, boss, centipede, flea, ladybug, mite, zombie, herd };
pub const BossId = enum(u8) { heisenbug, mandelbug, schrodinbug, bohrbug };   // Enemy.variant for .boss
```

`Enemy` gains `variant: u8` (boss id; centipede 0 = head, 1 = segment),
`formation: u8`, `aux: u32` and `aux2: f32` (free per-kind state for
track B), `hp` becomes `u16`. Bug messages (`rewind.message`; `.boss`
looks up the stage's boss):

| Kind | Message |
|------|---------|
| centipede | `STACK OVERFLOW` |
| flea | `NULL POINTER DEREF` |
| ladybug | `INFINITE LOOP` |
| mite | `BUFFER OVERFLOW` |
| zombie | `USE AFTER FREE` |
| herd (midboss) | `THUNDERING HERD` |
| boss: Heisenbug | `UNDEFINED BEHAVIOR` (as today) |
| boss: Mandelbug | `EMERGENT BEHAVIOR` |
| boss: Schrodinbug | `IT NEVER WORKED` |
| boss: Bohrbug | `REPRODUCIBLE CRASH` |

### Stages (track B1: `waves.zig`, `enemies.zig`, `hud.zig` stage text)

`waves.State` gains `stage: u8` (0..3). Flow per stage: `STAGE n` +
name pop for 120 ticks at the start, waves table (~70 s, sorted by tick),
an optional midboss entry in the table (the table clock pauses while the
midboss is alive, so it cannot be skipped by waiting), `WARNING` 6 s, the
boss, the clear (+500, fuel refill) or the escape, a 120-tick breather,
next stage. After stage 4: stage 1 with `loop + 1`, popped as `LOOP 2`.
`Entry` gains `formation: bool` (open a formation of `count` with drop)
and a `pattern: u8` variant so one kind can run several movement / fire
programs (B1 defines the table).

Design intent per stage (B1 owns the numbers; the probe decides them):

- **1 UNIT TESTS** (gnat, wasp, beetle, spider, moth): learn the game,
  but a careless player gets hit. Every kind fires within 30 ticks of
  becoming visible. Gnat strings are formations; from 20 s some strings
  fire one aimed pellet each when they cross x 120. Beetle HP 12, 5-way
  fan; spider 6, rotating 7-arc; moth 5, aimed needle pairs; wasp 2 and
  arrives in threes. Boss Heisenbug.
- **2 INTEGRATION** adds the centipede (head 10 HP + 5 segments of 4,
  weaving sine, a ripple of aimed pellets down its body), ladybug loops
  (formations of 4 entering from the top or bottom edge, an 8-ring at the
  top of each loop), fleas from behind (a 30-tick warning chevron at the
  left edge first). Midboss Thundering Herd at ~35 s. Boss Mandelbug.
- **3 STAGING** adds ground mites (walk the near layer at the layer's
  scroll speed, 16 HP, aimed needle bursts and an upward fan) and zombies
  (die into a husk, revive after 90 ticks with half HP and a 12-ring),
  walls with gaps, two kinds at once. Midboss Herd v2. Boss Schrodinbug.
- **4 PRODUCTION**: everything, overlapping formations, curtains from two
  sides. Midboss Herd v3. Boss Bohrbug.
- **Loop 2+**: the same four stages with rank +400 (revenge bullets on).

Midboss Thundering Herd (`herd`, 32x32): holds at x 112, HP ~300 (x
rank), releases a gnat string from itself every 120 ticks and fires
flowers (two rings of 10, half a step apart, one fast one slow); leaves
after 25 s if alive (no crates); death: `cancel_all`, two crates, 1,000
points.

### Bosses (track B2: `bosses.zig`, new, holding all boss code)

Common: HP-gated phases (break at the listed fractions), each break runs
`bullets.cancel_all()`, drops one crate and gives 60 ticks of no fire; a
non-final phase that times out moves on without the crate; the final
phase times out into an escape (fly off right, stage advances without
the +500 or the fuel refill). Boss HP is x (1 + 0.3 x loop), not ranked.
Starting HP (tune with the probe so the turret bot takes 30-60 s, the
dodger 25-45 s):

- **Heisenbug** (stage 1, 500 HP, phases at 100/66/33 %, 20 s limits,
  final 30 s): keeps its teleport. P1 rotating 12-ring + aimed 3-stream;
  P2 counter-rotating double spiral and a ring at each reappearance; P3
  teleports every 120 ticks, a 16-ring of pellets and a sniper `line` at
  each reappearance.
- **Mandelbug** (stage 2, 800 HP, 4 phases): fractal. Orbs that split
  into 6 pellets; then splits of splits (gen 1); aimed walls plus split
  rings; final: everything splits.
- **Schrodinbug** (stage 3, 900 HP, 4 phases): two bodies, one real, both
  drawn dithered (superposed) until a bolt touches one: the touched body
  collapses (solid if real; a phantom bursts into a ring and reforms).
  Mirrored patterns (the phantom fires the y-flipped copy), stop-and-go
  bullets (drag then `aim`), crossing curtains.
- **Bohrbug** (stage 4, 1,600 HP, 5 phases): the final exam, totally
  reproducible. Walls with a gap that tracks the ship; double flowers;
  stop-and-go rain; curving spirals (`turn`); the last phase layers three
  of them.

### Art (track C: `tools/prepare_assets.py`, `assets/gen/`, `build.zig`, `ASSETS.md`)

Code-drawn like the rest (Adrian 2026-09-27: placeholders are final art).

| Sheet | Cell | Cells |
|-------|------|-------|
| `bugs2.png` | 16x16 | 12: centipede head x2, centipede segment x2, flea x2, ladybug x2, mite x2, zombie x2 (the husk is a zombie cell drawn dithered) |
| `herd.png` | 32x32 | 2 (wing loop) |
| `boss2.png` Mandelbug, `boss3.png` Schrodinbug, `boss4.png` Bohrbug | 48x48 | 5 each: 4 idle + 1 alt (hurt / collapse / charge) |
| `shots.png` | 8x8 | 4: pellet x2 (4x4 dot centered), spare x2 |
| `orb.png` | 16x16 | 2 (12x12 orb centered, pulse) |

Bullets must contrast with every background layer; enemy bullets are
warm (Coral / pink / white cores), the player's bolts stay cool. Each
boss reads as its own bug at 160x128 and differs from the Heisenbug in
silhouette, not only color.

### Probe (track D: `autopilot.zig`, `tools/difficulty.sh`)

Bots drive the ship through the normal input path (logged by history, so
rewinds and the identity check work with them):

- `turret` (1): holds A, never moves.
- `sweep` (2): holds A; up 40 ticks, still 20, down 40, still 20, as the
  M2 sweep.
- `dodger` (3): holds A; danger map over a 2D grid of reachable positions
  from predicted bullet / enemy positions over the next ~30 ticks; steers
  to crates when safe. The seed of M8's attract autopilot. Never draws
  from the world rng.

`tools/difficulty.sh` runs each bot in endless probe mode from a fresh
game for the full four stages (plus loop-2 stage 1) and prints one table:
per bot and stage, hits, seconds to clear (boss time separately), rank at
the stage's end, weapon and forks at the stage's end, and whether the boss
was killed or escaped. Deterministic: same build, same table.

Wasm exports track A adds: `debug_probe()` (toggle, returns the flag),
`debug_hits()` (probe hits so far), `debug_rank()`, `debug_stage_index()`
(stage + 4 x loop), `debug_next_stage()` (jumps to the start of the next
stage: clears enemies, bullets and crates, checkpoints the history),
`debug_bot(n)` takes an arg (0 = off) and `main.update` reads controls
from `autopilot.controls(bot, tick)` while it is on (A ships a stub that
returns no buttons; D implements).

### Difficulty targets (the acceptance table)

Hits per stage in endless probe mode (each hit is one rewind a real
player would have spent):

| Bot | Stage 1 | Stage 2 | Stage 3 | Stage 4 | Loop 2, stage 1 |
|-----|---------|---------|---------|---------|-----------------|
| turret | >= 12 | >= 20 | >= 30 | >= 40 | >= 40 |
| sweep  | >= 6  | >= 12 | >= 20 | >= 30 | >= 30 |
| dodger | 1..5  | more than stage 1 | more than stage 2 | more than stage 3 | >= stage 4 |

Plus: no boss dies in under 15 s to any bot; the turret bot reaches each
boss with the weapon at level 2 or more at least once (crates still
come); the dodger, which is not a great player, gets through stage 1 with
at most 5 hits (a first-time human with 3 rewinds can see the first
boss).

### Tracks

- **Phase 1, in parallel** (git worktrees, disjoint files):
  - **A engine** (Opus): `rank.zig`, `formations.zig`, `autopilot.zig`
    (stub), `bullets.zig`, `patterns.zig`, `player.zig`, `pickups.zig`,
    `collide.zig`, `world.zig`, `main.zig`, `rewind.zig` (messages),
    `boss_hp.zig` (u16), `hud.zig` (boss bar u16, pause rank), and the
    minimal `enemies.zig` edits to compile (Kind / BossId / fields, u16
    HP, ported pattern calls, formation `lost` on cull, rank HP at spawn).
    Stand-in art for the new sheets may be generated locally, never
    committed. Old content keeps playing (stage 1 only) when A is done.
  - **C art** (Opus): the sheets above.
  - **D probe** (Opus): `autopilot.zig` and `tools/difficulty.sh`
    against the interface above (with a local stub of A's exports until
    A lands).
- **Phase 2, after A and C are merged**: the lead moves the boss code
  from `enemies.zig` into `bosses.zig` (mechanical), then in parallel:
  - **B1 stages** (Opus): `waves.zig`, `enemies.zig`, `hud.zig` stage
    text: four stage tables, the new regular kinds and the midboss,
    rework of the five old kinds.
  - **B2 bosses** (Opus): `bosses.zig`: the four bosses.
  Both tune against `tools/difficulty.sh`.
- **Phase 3**: lead integrates, tunes to the targets, benches; **E
  harness and docs** (Opus): re-pin every `tools/scripts/` script to the
  new game, new `m7_*` scripts (rank, power loss, split / aim identity,
  formation drop, stage skip through all four bosses, boss timeout), the
  GIF, `docs/RUNNING.md`.

### Deviations (A)

Track A (engine), 2026-10-04. Choices where the contract was silent, and
the few places it was read loosely:

- **Modules.** The rank formula and effects table are pure in
  `rank_math.zig` (host tests in `zig build test`, wired next to
  `boss_hp.zig` in this cart's `build.zig`); `rank.zig` feeds them from
  the World. `BossId` lives in the pure `boss_hp.zig` (re-exported as
  `enemies.BossId`) with `boss_hp.for_stage(stage) BossId`; boss HP is
  `max_hp(id, loop) u16`, still 60 + 20 per loop for every boss, no cap.
- **Mercy** is `world.w.mercy: u16` (saturating +80 in
  `player.on_rewound_hit`), decayed by `rank.update()` at the top of
  `simulate` (before `waves.update`) when `game_tick % 120 == 0`.
- **Stage and loop until B1.** `waves.stage_count = 1`: every boss clear
  moves the stage index on (`advance`: stage + 1, or stage 0 and loop + 1
  after the last stage; `t = 0`) at the clear, so the next stage's rank
  applies during the breather. With one table every clear is a loop (as
  M6 counted it): loop 1 = rank +400 after the first boss, revenge on.
  `debug_stage` still returns `loop`; `debug_stage_index` = stage + 4 x
  loop. B1 sets `stage_count = 4`.
- **`waves.next_stage()`** (`debug_next_stage`): clears enemies (the boss
  too), enemy bullets, crates and formations (bolts and fx stay), moves
  the stage on as a clear does (not a second time during the breather
  after a clear, which already did), restarts the table at its first
  entry; no +500, no fuel refill, no `stage_clears`. The export
  checkpoints the history only while playing or paused.
- **Event timing.** Events are collected while the pool moves and run
  after it, in pool order, so children and fan bullets never move in
  their spawn tick whichever slot they land in; the event bullet is culled
  after its event. A split outside the field leaves nothing. A standing
  bullet's heading is straight left. `aim` also clears `vmax` (the new
  speed is the one). An `aim` fan with even `ev_n` keeps the bullet at
  index (n - 1) / 2, the half step below the middle. `event_at = 0` never
  fires. Turn, drag and accel are skipped when they are no-ops, so a
  default bullet moves bit for bit as before.
- **Cull** by shape: the center leaves x [-m, 160 + m) or y [8 - m,
  128 + m), m = 4 (the M2 bounds), 8 for the orb.
- **`cancel_all`** scores `10 * n` in one `add_score` and sparks at the
  first 8 bullet centers in pool order.
- **Emitter types**: counts `u32`, `step_256` / `span_256` `u32`, absolute
  angles and phases `i32` (wrapping, so counter-rotation is a negative
  step), `speed_step` and wall coordinates `f32`. `wall` with one bullet
  puts it midway; its heading is exactly (-1, 0), not the table's angle
  128. `ring_aimed`'s first bullet is the aim vector itself. `Shot.accel`
  is not rank-scaled. `spawn_shot` computes the rank once per bullet.
- **Formations.** `open(0, _)` returns 0; ids skip 0 and ids still in use.
  Gnats of a string that do not fit in the enemy pool count as lost at
  once, so the slot still frees. `formations.clear()` frees all.
  `enemies.spawn_gnat_string(y, drop)`: every M6 string opens with
  `drop = true` until B1's `Entry.formation`. A gnat leaving past x -8
  and the off-field cull both call `lost`, as does a ram
  (`collide.remove_offender`).
- **Drops.** `player.gnat_kills` is replaced by `player.beetle_kills`
  (every second beetle killed by a bolt drops). On a bolt kill the order
  is: kill, `formations.killed`, the beetle drop, `rank.revenge`. The
  M6 boss phase-change drop is kept until B2.
- **Revenge** pellets carry the killed kind as `source` (its bug message);
  the distance is to the ship's hitbox center; a boss never revenges (its
  death is not a `.killed`).
- **Probe mode.** Hits count in the World (`player.probe_hits`), so a
  hold-B rewind un-counts what it rewinds (the bots never hold B). The
  retry shield takes a hit first, as it would for a player; probe wins
  over `god` when both are on; the grant is 60 ticks (`resume_invuln`).
- **Bots.** `autopilot.controls(bot, world.w.game_tick)` replaces the
  hardware/script controls in every state, title included (a bot holding
  A starts a game); `debug_bot(n)` clamps n to 255 and returns it.
  `tools/preview.mjs` gained `--call-at "T NAME:ARG"` (one integer
  argument; the zero-argument form is unchanged).
- **Extra test exports**: `debug_mercy()`, and `debug_spray()`, which
  spawns a fixed set of engine bullets from (140, 64) (8 turning rounds, 2
  orbs splitting into 6 pellets that split again into 3, 3 stop-and-go
  pellets re-aiming as fans of 3, an accelerating capped needle) and
  checkpoints; `tools/scripts/m7_identity` uses it to put splits, re-aims
  and turns in flight across hold-B rewinds without new stage content.
- **Placeholder kinds** (centipede .. herd) until B1: 16x16 (herd 32x32),
  base HP 2 (herd 30), points 30 / 30 / 40 / 60 / 50 / 1000, fly left 1 px
  per tick without firing, drawn with `bugs` cells 0-1 (the herd as 2x2
  beetle cells).
- **Weapons.** A ghost's level-1 FUZZER volley is one straight zap (no
  jitter, no rng draw). BISECT angles stay 0, +10, -10, +20 by seeker.
- **Power loss** runs in `step_rewind` after `restore` and
  `invalidate_after`, before the invulnerability grant and the
  checkpoint.
- **Pause** panel rows moved up 2-4 px to fit `RANK nnn` (y 98; four
  digits at 1000).
- **Art.** Stand-in `shots.png` / `orb.png` were committed first so the
  engine compiled; the merge of `bugs/m7-difficulty` (track C's sheets)
  replaced them and their `build.zig` rows with track C's.
- **Sizes**: `@sizeOf(World)` 10,520 (was 6,340); the World's defaults
  are in `.data` as before (the bullet pool's `drag = 1` is non-zero).

### Deviations (B2)

Track B2 (bosses), 2026-10-04. All boss code is in `bosses.zig`; in
`enemies.zig` only the `.boss` cases of `size`, `hittable`, the damage
path (`bosses.damage`) and `boss()` (skips the phantom).

**The common frame.** HP-gated phases, each with a limit (20 s, the
final 30 s). A break (HP at the phase's threshold) runs
`bullets.cancel_all()`, drops one crate at the boss, and rests 60 ticks
(no fire; bolts are absorbed, no damage). A non-final phase that times
out drops its HP to the threshold and moves on the same way without the
crate. The final phase timing out flies the boss (and the phantom) off
the right edge at 1.5 px per tick, not hittable, then
`waves.boss_escaped()`. Death: `cancel_all`, the phantom pops, the M3
explosion sequence, +500 and `waves.boss_cleared()`. Additions:

- **Phase floor**: no phase breaks before 6 s (360 ticks): HP stops at
  the threshold until then. This is what keeps a strong ship from
  melting a boss (no boss under 15 s for any ship: 3 phases x 6 s + 2
  rests = 20 s for the Heisenbug, 27 s, 27 s and 34 s for the others).
- **Body boxes**: a boss's (x, y) is the top-left of its body box from
  ASSETS.md M7 sheets (Mandelbug 14,12 32x25; Schrodinbug 8,10 35x35;
  Bohrbug 6,13 40x33; the Heisenbug keeps its whole 48x48 cell), so bolts
  and rams meet the body, not the legs; `draw_boss` draws the cell at the
  box minus the offset. The wave still spawns the boss by its cell
  position; the first update converts it.
- **Telegraph**: a heavy volley (countdown A of a phase marked `heavy`)
  shows the alt cell for its last 24 ticks (Mandelbug glow, Schrodinbug
  pop-out, Bohrbug charge; the Heisenbug's teleport flicker is its own
  tell, and it now also materialises for 16 ticks before it can be hit or
  fire). No bullet spawns within 18 px of the ship's hitbox center
  (walls check per bullet).
- **Hit flash** on one frame in eight (under steady fire a boss flashed
  on a quarter of the frames and hid the telegraph).
- **State** fits the existing Enemy fields: `aux` is a packed struct (HP
  phase, phase clock, rest, countdown B, a flag, phantom, init), `fire_tick`
  countdown A, `ring_phase` countdown C or a second angle, `timer` the
  movement clock, `aux2` per boss. Countdowns reload with
  `rank.interval(base)`; counts add `rank.extra(k)`. No new Enemy or
  World fields.
- **Movement** keeps every boss near the middle third (Mandelbug +-12 px,
  Bohrbug +-16, Schrodinbug bodies 4..32 px either side of y 68) so a ship
  in line can hurt it; the Heisenbug keeps its M3 bob and teleport.
- **Test hooks** (not World state, constant through a run, read once at
  a boss's first update): `bugs_force_boss` / `bugs_force_phase`
  (exported, so badge-bench can `--poke` them; wasm `debug_boss(id |
  phase << 4)`), wasm `debug_boss_id`, `debug_boss_phase`,
  `debug_boss_clock`. In `main.zig`, its own commit: `bugs_bench_stage`
  (poke N > 0: every game starts in probe mode N - 1 stages on, at the
  boss warning).

**The bosses** (base intervals in ticks at rank 0; HP fractions are the
phase's span):

| Boss, HP | Phase (HP, limit) | Pattern |
|---|---|---|
| Heisenbug 320 | P1 100-66 %, 20 s | rotating ring of 12 (+4) rounds every 34; aimed 3-needle sniper line every 50; teleport every 300 |
| | P2 66-33 %, 20 s | counter-rotating double spiral (2 pellet arms one way, 2 round arms the other) every 7; aimed ring of 12 (+4) at each reappearance; teleport every 240 |
| | P3 33-0 %, 30 s | teleport every 120; at each reappearance a 16 (+4) pellet ring and a 5-needle sniper line; aimed 3 (+2) fan every 40 |
| Mandelbug 480 | P1 100-75 %, 20 s | 3 orbs (fan) that split into 6 (+2) pellets at age 45, every 70 (telegraphed); aimed 3-pellet fan every 45; 2-pellet line from the proboscis every 26 |
| | P2 75-50 %, 20 s | 3 orbs that split into 4 whose children split into 4 again (gen 1), every 90; 5 (+2) round fan every 40; pellet line every 30 |
| | P3 50-25 %, 20 s | wall of 17 rounds with a weaving gap every 80; ring of 8 (+4) pellets that split into 3 at age 50, every 70; aimed pellet every 24 |
| | P4 25-0 %, 30 s | 2 orbs splitting 3 x 3 (gen 1) every 80; split rings every 50; aimed 3-pellet fan every 24 |
| Schrodinbug 240 | all | two bodies mirrored about y 68 (the real one on a side the rng picks at each phase); both fire, the lower one the y-flipped copy; a touched real body collapses (solid) until the next phase, a touched phantom bursts into an aimed 8 (+4) pellet ring and reforms for 90 ticks (no fire, not hittable) |
| | P1 100-75 %, 20 s | per body a stop-and-go arc of 9 pellets (drag 0.95, re-aim at age 50) every 60; aimed round every 30 |
| | P2 75-50 %, 20 s | crossing curtains: per body one round every 6, sweeping between down-left and left, the two streams crossing; stop-and-go ring of 10 (+2) per body every 90 |
| | P3 50-25 %, 20 s | stop-and-go ring of 14 (+4) per body every 75; mirrored spirals every 8 |
| | P4 25-0 %, 30 s | curtains every 7; stop-and-go ring of 12 (+4) per body every 90; 3-needle line every 40 |
| Bohrbug 420 | P1 100-80 %, 20 s | wall of 17 rounds every 60 whose gap tracks the ship but sits 20 px above it, then below, alternating (at most 30 px from the last gap): a ship that sits still meets the wall; horn needle every 20; 3-pellet fan every 50 |
| | P2 80-60 %, 20 s | double flowers: rings of 12 (+4) fast pellets and slow rounds half a step apart, rotating, every 40; horn needle every 32 |
| | P3 60-40 %, 20 s | stop-and-go rain: one pellet every 4 thrown left over a cone at 1.2-2.2, braked, re-aimed at age 64 (a golden-ratio walk, no rng); 5 (+2) needle fan every 70 |
| | P4 40-20 %, 20 s | 3-arm spiral every 5 whose bullets curve (turn 2/256 a tick for 40 ticks), the curl flipping every 4 s; 4-needle sniper line every 80 |
| | P5 20-0 %, 30 s | the wall every 90, a 2-arm curving spiral every 7 and the rain every 9 at once |

The Mandelbug and Bohrbug walls share `weave_gap`. HP is far below the
contract's 500 / 800 / 900 / 1600: a turret bot is hit about once a
second, so the power loss keeps it at level 1, and with the bosses
moving it deals only 3-9 damage a second; the contract HPs made every
turret fight time out. The phase floor, not HP, sets a strong ship's
time.

**Measured** (endless probe mode, a boss reached by `debug_next_stage`
x k + `debug_warp` with `waves.stage_count` set to 4 locally, so each
boss fights at its stage's rank; the bot starts the fight at weapon
level 1-2; seconds from spawn to gone; hits during the fight; bullet
peaks per tick):

| Boss | turret s / hits | sweep s / hits | dodger s / hits | pool peak |
|---|---|---|---|---|
| Heisenbug | 47 / 27 | 62 / 27 | 23 / 0 | 56 (P2) |
| Mandelbug | 50 / 38 | 91 escaped / 51 | 28 / 0 | 98 (P2) |
| Schrodinbug | 51 / 37 | 57 / 29 | 30 / 0 | 89 (P3) |
| Bohrbug | 50 / 35 | 91 / 54 | 32 / 0 | 80 (P2) |
| Bohrbug, loop 2 | 63 / 47 | 105 / 63 | 42 / 1 | 73 (P5) |

The dodger (track D's, run locally) is not hit by any loop-1 boss: it
reads every bullet's future including drag; the bosses are dense enough
to hit the turret about once a second and the sweep 30-60 times a fight.

**badge-bench** (calibrated busy ms; each boss forced into its busiest
phase with `--poke bugs_bench_stage=2 --poke bugs_force_boss=K --poke
bugs_force_phase=P`, so loop 1 at rank ~400, a turret holding A from 30
and B held 800..859; 1300 updates, the fight from about 460):

```
badge-bench/bench.sh zig-out/firmware/snouty-bugs.elf --frames 1300 --press A:30-1299 \
    --press B:800-859 --poke bugs_bench_stage=2 --poke bugs_force_boss=3 \
    --poke bugs_force_phase=4 --symbols
```

| Boss, phase | fight mean | worst outside the hold | worst in the hold | hold frames > 14 ms |
|---|---|---|---|---|
| Heisenbug P2 | 8.99 | 9.94 | 14.86 | 6 of 60 |
| Mandelbug P2 | 9.91 | 10.80 | 17.33 | 27 |
| Schrodinbug P3 | 9.71 | 10.55 | 16.10 | 22 |
| Bohrbug P5 | 9.59 | 10.07 | 16.62 | 23 |

Playing frames stay under 11 ms; the hold-B frames go over the 14 ms
target by up to 3.3 ms. A hold frame restores a keyframe and replays up
to 59 ticks; with 80-100 bullets and a full bolt pool each simulated
tick costs about 0.12 ms (bullet moves and events, the bolt-vs-enemy and
bullet-vs-ship passes), so the catch-up, not the boss code, is the cost.
Levers for the lead (outside this track's files): keyframes every 30
ticks (SPEC.md 13.1's fallback), or the pool at 112 / 96 per the
decision above.

### Deviations (B1)

Track B1 (stages), 2026-10-04. `waves.zig`, `enemies.zig` (not the boss
lines), `hud.zig` stage text. Every number below is a knob at the top of
`enemies.zig` or in the stage tables.

- **Fire on countdowns.** Every regular fire program runs on a countdown
  (`aux`, a second one in `fire_tick`) reloaded at fire time, so a rising
  rank never shifts a modulus. A countdown at 0 waits until the emitter is
  inside the field; a volley is skipped (and the countdown reloaded) when
  the emitter is within 22 px of the ship's hitbox center, so bullets never
  spawn on the ship. Reload = `rank.interval(base) x pace / 16`, with
  **pace** 16 / 9 / 9 / 7 for stages 1-4 and a third of that from the
  second loop (`stage_pace`, `loop_pace`): the content's own difficulty
  curve on top of the rank. The rank alone could not carry it: the probe
  showed the dodger, once powered up, killing everything as it enters, and
  the mercy term (+80 per hit, -1 per 2 s, uncapped) pins a struggling
  player's rank at 0 for minutes, which also cancels loop 2's +400.
- **Enemy fields.** `Enemy` gains `pattern: u8` (the program) and `edge`.
  `Phase` gains `warn`, `jump`, `land`, `loop`, `husk`, `hold`. `spawn`
  keeps its signature (program 0, right edge); `spawn_ex(kind, x, y,
  delay, pattern, edge, variant)` is the full one; `spawn_gnat_string(y,
  drop)` stays, `spawn_gnat_string_ex(x, y, id, pattern)` and
  `spawn_centipede(y, id, pattern)` are new, `herd_alive()` is what the
  table clock waits on.
- **Kill hooks.** `damage()` at 0 HP calls `regular_death()` for regular
  kinds (the boss lines are untouched): a zombie's first death turns it
  into a husk and returns `.alive`; the herd's death runs
  `bullets.cancel_all()`, drops two crates 20 px apart and a big explosion,
  then returns `.killed` so `collide.kill` scores the 1,000.
  `Enemy.hittable()` is false for a flea behind its chevron and a husk
  (neither shot, rammed nor steered at by seekers). Points: centipede head
  100, segment 20, flea 40, ladybug 30, mite 60, zombie 50 (+25 for the
  husk), herd 1,000.
- **HP above the contract's.** Stage 1 asked beetle 12, spider 6, moth
  5; stage 2 centipede 10 + 4, mite 16, herd about 300. With those, a
  powered ship killed everything before its first volley; the table below
  has the numbers used (wasp 2 as asked).
- **Big-bug flash.** The herd flashes on the first tick of a hit only
  (under constant fire it was white all the time).

Kinds (base HP x `rank.hp`, base intervals in ticks before pace and rank;
p = `pattern`):

| Kind | HP | Movement | Fire |
|------|----|----------|------|
| gnat | 1 | strings of 5, 1 px/tick, wobble 8 (p2: 14) | p0 none; p1 aimed pellet crossing x 120; p2 crossing x 136 and 84 |
| wasp | 2 | threes in a vee; in at 2.5 to x 120 (or from the top / bottom edge to y 22 / 90), 20-tick pause, charge | on stopping: aimed 3-fan of pellets (p1+: 5-fan) |
| beetle | 24 | in at 0.5 to x 112 (p2: 136), sits 240, leaves | every 24: p0 aimed 5-fan of rounds (+ rank.extra(2)); p1 fan / rotating 10-ring alternating; p2 (every 60) a 13-round wall, gap 26 px opening 48 px from the ship's y; p3 fan / aimed orb that splits into 6 pellets at age 50 |
| spider | 12 | drops from the top, hangs 180 at y 24..72, climbs | every 18: 5-arc (8/256 apart) around a middle that sweeps 128 +- 40 (a sprinkler); p1 7 faster pellets |
| moth | 8 | M2 wander (rng), 600 ticks | p0 aimed needle pairs every 20; p1 a 6-ring of stop-and-go pellets every 45 (drag 0.93, re-aim at age 40) |
| centipede | head 24, segment 8 | head + 5 segments on one sine path (0.6 px/tick, amplitude 16, p1 28), each 14 ticks behind | the ripple: every 50, head first, each segment 6 ticks later; p0 aimed pellet; p1 aimed 3-fan; p2 the head an aimed 10-ring |
| flea | 12 | 30-tick chevron at the left edge on its line, then jumps in from behind (vx 1.1, gravity 0.09, jumps vy -2.5, p1 -3.0, 12 ticks on the ground) | at each apex: p0 aimed 3-fan of pellets; p1 8-ring; p2 sniper line of 3 needles |
| ladybug | 6 | fours from the top or bottom edge, 1.6 px/tick, drifting 0.4 left; one loop of radius 18 (64 ticks; p1 two), out the far edge | a ring of 10 (+extra) at the top of each loop; p2 12, plus an aimed pellet as the loop starts |
| mite | 36 | locked to the near layer's scroll (integer steps of `bg.tick`), feet on the lower of the layer's tops under its feet, 1 px/tick steps | from the muzzle: needle bursts of 3 (p1 4), 6 apart, every 60; a 5-fan (p1 7) of pellets up-left every 70 |
| zombie | 16 | 0.55 px/tick left on a slow sine (amplitude 10) | every 35: p0 aimed 3-fan of rounds; p1 5-fan of pellets. First death: husk (cell 10 dithered, drifts 0.5), revives after 90 with half HP and a 12-ring of pellets |
| herd | 400 / 520 / 640 (v1-v3) | in to x 112, holds 25 s bobbing +- 16, leaves right | a gnat string from the egg row every 120 (gnat program = version + 1, so they fire); flowers every 50 / 42 / 36: two rings of 10 (v3: 12) + extra, half a step apart, pellets 1.2 and rounds 0.7; v2+ every third slow ring stops and re-aims; v3 also an aimed 3-needle line every 70 |

Stages (each about 70 s of waves, WARNING at 72 s on the table clock,
the boss at 78 s; the herd entry at 35 s holds the clock while she lives):

| Stage | New | Ideas |
|-------|-----|-------|
| 1 UNIT TESTS | gnat, wasp, beetle, spider, moth | wasp threes, beetle fans, spider sprinklers, needle pairs; strings fire from 20 s; two crate strings and a last one on the spawn line |
| 2 INTEGRATION | centipede, ladybug (top and bottom), flea | ripples, loops with rings, crossfire from behind (flea pairs at 16, 30, 57 s), pace 9/16; herd v1; beetle p1 rings, wasp 5-fans from above |
| 3 STAGING | mite, zombie, walls (beetle p2) | fire from the ground, revivals, walls with far gaps, stop-and-go rings, two kinds per wave; herd v2 |
| 4 PRODUCTION | splitting orb beetle (p3) | everything at pace 7/16: ladybug fours from both edges at once, walls from the right while fleas come from behind, wasps from top and bottom; herd v3 |
| loop 2 | | the same tables at a third of the pace, every gnat string fires, the herd one version up, and stage 1 adds a loop table (fleas, mites, ladybugs, zombies) |

- **Formations** are on a few waves per stage (the first centipede or
  ladybug four, a gnat string or two, and a last dropping string at 69 s
  on the spawn line, y 58, so the turret bot meets a boss powered up at
  least once). With every gnat string dropping, the probe saw 10-23
  crates a stage; now 2-7, plus the beetle rule and the herd's two.
- **Entry.** `pattern`, `formation`, `edge` (top / bottom for wasps and
  ladybugs; fleas always left; others the right), `dy` (vee offsets 0,
  -dy, +dy, ...). `y` is the coordinate along the edge. `State` gains
  `next_loop` for the loop tables.
- **Scripts.** `tools/scripts/m7_stages` warps through the four tables
  and into loop 2 in probe mode with a B hold in each, pinning
  `debug_history_check == 0` every 10 updates (1,126 checks).
  `m7_bosses`' outcome pins were re-pinned for four stages (the
  Heisenbug dies at about 1650, the Bohrbug is killed rather than
  escaping); its id, phase and identity pins hold.
- **HUD.** `STAGE n` (y 52) and the name (y 62, Coral) for the first 120
  ticks of each table, `LOOP n` above (y 40) from the second loop; `+500`
  or `ESCAPED` for 60 ticks after the boss. The old `STAGE n` after a
  clear is gone (the pop replaces it).

Probe (`tools/difficulty.sh` from bugs/m7-probe, used locally, not
committed by B1; B2's four bosses merged), hits per stage, boss fights
included:

| Bot | S1 | S2 | S3 | S4 | L2 S1 |
|-----|----|----|----|----|-------|
| turret (target >= 12/20/30/40/40) | 70 | 110 | 109 | 117 | 89 |
| sweep (>= 6/12/20/30/30) | 81 | 112 | 113 | 145 | 71 |
| dodger, one game (1..5, then rising) | 1 | 7 | 8 | 22 | 30 |
| dodger, a fresh game warped to each stage | 1 | 13 | 21 | 29 | 29 |

The dodger is chaotic: a hit costs a level and a fork and adds mercy, so
small changes swing a chained run by 10 hits a stage; the fresh-start row
(F1, no forks, `debug_next_stage` at the start) is the steadier curve.
The turret reaches the stage-3 boss at A2 and the stage-4 boss at B2.
Peaks: 20 of 24 enemies; the 128-bullet pool is full at moments in
stages 2-4 and loop 2 for every bot (mean on screen: stage 1 20-33,
stage 4 70-80), so later patterns are clipped by the pool there.

Bench: badge-bench on a stage-4 build (a local edit started the game in
stage 4 with god mode, not committed), the m7_stages sweep holding A from
update 30, B held at 1700..1719 (28 s into PRODUCTION, the pool full at
moments, 84 bullets on screen on average, up to 14 enemies), after the
merge of B2's sprite speedup: mean 3.54 ms, p95 4.01 ms, worst 15.56 ms
on the first hold-B frame (93 % of the budget, 0 frames over); without
the hold the worst frame is 4.67 ms. A 100-frame hold at 15 s
(900..999) peaks at 17.9 ms (6 frames over). The hold frames are the
history replay of up to 59 ticks: B1's per-tick code is small
(`enemies.update` about 800 cycles a tick, the fire countdowns about
600), the replay is dominated by the engine's per-tick collision and
bullet passes, which grow with the full bullet pool. So the 14 ms target
for a hold-B frame is missed by 1.6 ms in a full stage-4 wave; the
contract's fallback (pool 112 or 96) or fewer keyframe ticks to replay
are the levers, not stage content. Iterating arrays by value (`for
(world.w.enemy_bullets) |b|` copies the array) costs about 0.25 ms of
memcpy a frame in `bullets.zig` (tried locally by pointer: mean 3.54 ->
3.30 ms, worst unchanged; not committed, engine file).

### Verification for M7

- `tools/check.sh` all green; `debug_history_check == 0` on every frame of
  a probe run through all four stages and on frames with splitting,
  turning and re-aiming bullets in flight, during a hold-B and after an
  auto-rewind resume with the power loss.
- `tools/difficulty.sh` table meets the targets; the table goes in the
  status entry.
- badge-bench: the stage-4 boss's busiest phase with a hold-B rewind in
  it, worst frame under 14 ms; mean reported. RAM total (text + data +
  bss) reported, under 160 KB.
- `zig build test` (host tests: rank formula, boss HP table).
- `docs/preview_m7.gif`: a stage-1 wave, then each boss's busiest phase
  (via `debug_next_stage`).

## Status

- 2026-09-26: M0 scaffold committed. M1 plan written; stand-in sheets
  committed so the code track compiles from the first minute.
- 2026-09-26: M1 done and tagged `m1`. All three tracks landed as planned.
  ELF text+data 31 KB. `m1_play.json` scores 570 in 1800 ticks; an 18,000
  tick soak does not trap (the scripted ship idles after tick 1800, loses
  its lives and returns to the title, as designed). Deviations from the M1
  numbers: stars scroll every 3 and 2 ticks (grey, white); the five gnats
  of a string share a spawn and appear 12 ticks apart; doubled strings
  draw y from [16, 72]; lives 0 returns to TITLE immediately. Art notes
  for the brief are in ASSETS.md section 10. Next: M2 bullet hell.
- 2026-09-26: Rewind mechanic designed (SPEC.md 5.1, 13.1). Milestones
  renumbered: M4 Rewind, M5 Attract, M6 Polish. M2 now opens with the
  `World` refactor (contract above) before any new entities land.
- 2026-09-26: M2 step 0 done: `world.zig` landed, all 400 M1 frames
  byte-identical before and after, `@sizeOf(World)` = 3160 bytes, ELF
  text+data 36 KB. M2 tracks A, B1, B2, C planned above and started.
- 2026-09-26: M2 done and tagged `m2`. All four tracks landed as planned;
  `tools/check.sh` runs six scripts green; 18,000-tick soak clean. ELF
  text+data 46.7 KB, `@sizeOf(World)` 4132 bytes (M4 keyframe ring of 4 =
  16.5 KB). Deviations from the M2 numbers: the spider pair at 22 s is
  spaced 60 ticks (SPEC gave none); the wasp stops at x 119.5 (no snap);
  the moth counts its 600 ticks from entering the screen and fires only
  once on screen; the bomb resolves after all movement, just before
  collisions; no graze while invulnerable; DYING runs no collisions.
  Harness: frames are captured before per-tick export calls because the
  wasm shadow stack overlaps the simulator framebuffer at 0x20 (a
  `--call-at` used to paint a black band over columns 49..57). Balance is
  untested by a human: an idle ship is hit by the beetle every 130 ticks;
  the scripted sweep survives a loop with two bombs. Next: M3 stages and
  boss.
- 2026-09-26: M3 done and tagged `m3`. Nine scripts green; 18,000-tick
  god-mode soak clean; ELF text+data 55.4 KB; `@sizeOf(World)` 4232 bytes.
  Deviations: the boss bob clock restarts at each reappearance (so the
  rng-chosen base_y is where it reappears); `live()` is false while the
  boss is vanished; `damage()` is not gated by the boss phase but the bomb
  and the ram pass are (a flickering, vanished or dying boss neither takes
  nor gives hits); the boss hit flash is 1 tick (2 was a third of the
  frames white). Boss HP bar shows from the spawn tick, while the boss is
  still off screen. Balance: under constant fire the loop-0 boss lasts
  about 9 s; a human has not played it. The spare debug hooks (`debug_god`,
  `debug_warp`) are wasm-only. Next: M4 rewind (history.zig, rewind.zig).
- 2026-09-26: M4 done and tagged `m4`. Twelve scripts green;
  `debug_history_check` returned 0 on every recorded frame of m2_play,
  m3_boss, m1_pause, m2_hit and m4_early (track A checked every frame, the
  scripts pin a sample). ELF text 52.6 KB + data 4.3 KB; .bss 17.6 KB (the
  keyframes). `@sizeOf(World)` 4252. Changes beyond the contract, all in
  PLAN.md terms: the World's input edge detector is stepped only on
  simulated ticks and a meta detector (`input.meta`) drives title and
  pause, so a button held through a pause cannot desync a replay;
  `history.checkpoint()` saves a between-ticks keyframe at resume (and
  after `debug_warp`) so a later restore across the resume sees the
  invulnerability grant; restoring to a keyframe tick undoes that tick's
  input step from the log; the check returns 2 on title, dying and the 20
  bug-report frames; floats compare by bit pattern. The bug-report bar
  dodges the ship (SPEC.md 5.1 note). Resume invulnerability is 60 ticks.
  An idle ship replays its fate exactly (same hit, same tick), which is
  the mechanic working as designed. Needs Adrian: FPS overlay during a
  rewind on the badge; feel of the 20 + 60 tick timing. Next: M5 attract
  mode (title, autopilot, takeover, game over).
- 2026-09-27: Adrian played m4 locally: "rewind feels great" (timing
  confirmed). Adrian's call: drop the bomb, add a hold-B rewind paid from a
  slowly refilling fuel bar, plus a hardcore mode with no lives where the
  auto rewind spends fuel and a near-empty bar is fatal (floor 45, no
  consolation refill). M5 planned above; attract mode becomes M6, polish M7.
- 2026-09-27: M5 done and tagged `m5`. Fourteen scripts green (`m2_bomb`
  and `m3_bomb_boss` gone; `m5_manual`, `m5_empty`, `m5_hardcore`,
  `m5_graze` added; `m2_play`/`m4_identity` now survive the loop with two
  short B holds instead of the bombs). `@sizeOf(World)` 4236; ELF text
  52.6 KB, data 4.3 KB, bss 17.6 KB. Identity check 0 on every hold frame
  and every playback frame of three sweeps. Choices beyond the contract:
  the rewind-or-die decision is made at collision time with the fuel the
  hit meets (before that tick's refill); the refill counter keeps running
  while full and across a hold, so fuel can tick up on the first live tick
  after a release; the scanline dim covers the HUD row too, so the bar is
  visible but dimmed during a hold (SPEC 5.2 says "stays visible"; check
  by eye). `m5_hardcore`'s second rewind is 72, not "about 80": the graze
  rewound away does not pay again. Needs Adrian: hold-B feel at 2 ticks per
  frame, the refill rate, the floor, and hardcore difficulty. Next: M6
  attract mode (autopilot drives hold-B instead of a bomb).

- 2026-10-02: M6 done and tagged `snouty-bugs/m6`. Twenty scripts green
  (`m6_pickup`, `m6_cores`, `m6_fork`, `m6_retry`, `m6_retry_hc`,
  `m6_identity` added; `m3_loop` re-pinned, `m5_graze`'s hold moved four
  updates earlier to keep its graze). `debug_history_check` 0 on every
  frame of a 12,000-update god-mode sweep that reaches A5, B5, F5 with
  the rng jitter, three forks and two stage clears, holds included.
  `@sizeOf(World)` 6340 (was 4236); ELF text 58.9 KB + data 6.4 KB, bss
  26.0 KB. badge-bench on the 4,800-update `m2_play` sweep (two ghosts, A4,
  the shield pop): mean 7.35 ms, worst 12.19 ms at update 2090 (a hold-B
  frame, 73% of budget), 0 frames over; simulation is under 1% of a frame
  (drawing dominates), so full bolt pools cost nothing visible. Tracks: A gameplay, B art, C harness
  (three Opus agents), deviations under "Deviations (A)". Notes for Adrian
  (defaults taken, not blocking): a CORE HOURS crate grabbed with a full
  bar grants nothing (fuel is meta, so the World cannot know to pay points
  instead; +100 like any crate); the BISECT crate letter is B; with F5 or
  B5 and three forks the 64-bolt pool is full on some frames, so ghost
  volleys get dropped (by design, the ship fires first); m2_play's sweep
  no longer needs its holds to survive, so the game got easier for a
  player who collects (balance pass still pending a human). Next: M7
  attract mode (the autopilot should collect crates and hold B).
- 2026-10-04: Adrian: the game is far too easy, especially holding A with
  powerups; make it a real bullet hell with patterns that escalate as the
  game goes on (1942, Raiden X). Measured: an up/down sweep holding A was
  touched once in 3 minutes and cleared two loops. M7 "Bullet hell for
  real" planned above (rank, four stages, new bugs and bosses, pattern
  engine, powerup cuts, difficulty probe). Attract mode becomes M8,
  polish M9.
