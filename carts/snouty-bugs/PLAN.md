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

