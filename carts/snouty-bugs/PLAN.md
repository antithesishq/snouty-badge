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
- `simulate()` gains a `Mode` parameter, `.live` or `.silent`; audio and
  neopixel calls check it. M2 has no audio yet, so this is one enum and a
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

## M4 Rewind (not started, after M3)

Sketch of the tracks so M2 and M3 leave the hooks in place:

| Track | Files                                         | Contents                                                              |
|-------|-----------------------------------------------|-----------------------------------------------------------------------|
| A core| `history.zig`, `main.zig` (state machine)     | keyframe ring (4), input log (256), `record()`, `restore(tick)`, REWIND state, `debug_history_check`, `debug_rewinds` |
| B show| `rewind.zig`, `hud.zig`, `audio.zig`          | bug-report bar and messages, scanline dim, `<<` and `GO!`, red dot on the hitbox, retriggered rewind tone, LED chase |
| C tools| `tools/preview.mjs`, `tools/scripts/rewind_*.json` | identity check at several ticks, a script that flies into a bullet and asserts the rewind, GIF of one rewind for `docs/` |

Hooks M2/M3 must leave: `simulate(mode)`, `EnemyBullet.source`, the
collision result reporting *what* hit the player (kind + which pool index,
so track B can flash it), and `World` staying plain data.

Padding note from the step-0 refactor: the pool structs use auto layout,
so `Bolt`, `Fx`, `Enemy` and `EnemyBullet` have padding bytes that a
whole-struct store does not guarantee. Before the M4 identity test relies
on a byte compare, either make the pool structs `extern struct` with
explicit field order or write the compare field by field.

Hardware check at the end of M4: FPS overlay during a rewind must read 60
with the bullet pool near full. Fallbacks in SPEC.md 13.1.

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
