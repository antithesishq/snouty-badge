# Snouty vs. the Bugs: game spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Second cart for the badge, alongside `snouty-badge` (the running/jumping
Snouty). Status and milestones are at the bottom.

## 1. One paragraph

A horizontal bullet-hell shooter. Snouty pilots a small ship on the left of the
screen, flying right over a scrolling parallax background. Bugs (the software
kind, drawn as the insect kind) fly in from the right in scripted waves and
fill the screen with slow, dense, readable bullet patterns. A fires the zapper,
B drops a bomb that clears every enemy and bullet on screen, the joystick
moves the ship. Left alone, the cart plays itself in an attract/demo loop; the
moment anyone touches a button, the ship is theirs, mid-flight, no reset.

## 2. Hardware and platform facts the design leans on

- Screen 160x128, landscape. Horizontal scroller fits the shape and reuses
  Snouty's right-facing art direction.
- 60 Hz `update()`. All timing is in ticks (1 tick = 1/60 s). No delta time.
- Inputs: joystick up/down/left/right, A, B, Start, Select, joystick click.
  The OS owns two combos: Start+Select held 250 ms exits to the cart menu, and
  joystick click toggles the FPS overlay. The game never binds click.
- Audio: `tone2`, one voice, six wave shapes, cancels whatever was playing.
  Sound design is therefore one channel of short effects, no music.
- 5 neopixels, very bright; anything above ~10/255 is uncomfortable at
  lanyard distance. Used for bomb stock and event flashes only.
- Cart RAM: upstream reserves a 384 KB process region; `snouty-badge` runs
  comfortably at 94 KB. Budget for this cart: 160 KB total, of which art
  is at most 80 KB. The asset manifest in section 12 sums to well under that.
- Rendering: full redraw every frame with `.no_copy_full_frame`, as in
  `snouty-badge`. Upstream `blit` has no transparency, so sprites are drawn by
  our own palette-index loop that skips index 0. Verified fine on hardware for
  a 160x96 backdrop plus a 96x96 sprite per frame; this game draws about the
  same number of pixels (background plus ~40 small sprites plus ~90 bullets).
- Simulator quirks and shims (`present_wasm`, `read_controls`) are inherited
  from `snouty-badge`; see CLAUDE.md.

## 3. Controls

| Input             | Title / game over            | Playing                                  | Demo                          |
|-------------------|------------------------------|------------------------------------------|-------------------------------|
| Joystick          | (nothing)                    | Move ship, 8 directions                  | Take over (see section 8)     |
| A                 | Start a game                 | Zapper. Hold for autofire                | Take over                     |
| B                 | Start a game                 | Bomb (if stock > 0)                      | Take over                     |
| Start             | Start a game                 | Pause / unpause                          | Take over                     |
| Select            | Toggle sound + neopixels     | Toggle sound + neopixels                 | Toggle sound + neopixels      |
| Click             | OS: FPS overlay              | OS: FPS overlay                          | OS: FPS overlay               |
| Start+Select 250ms| OS: exit to menu             | OS: exit to menu                         | OS: exit to menu              |

Select does not count as "interaction" for the demo takeover. Sound and
neopixels are off by default so the badge is quiet on a lanyard; the setting
is not persisted (the flash save API returns 0 bytes upstream).

## 4. Screen layout

```
y   0..7     HUD: score (left), bomb icons (center), lives (right). 8 px.
y   8..127   Play area, 160x120. Background layers fill it.
```

- Far layer: tileable strip, scrolls 1 px every 4 ticks (15 px/s).
- Near layer: tileable strip along the bottom 24 px of the play area
  (y 104..127), scrolls 1 px every 2 ticks (30 px/s).
- Optional starfield between the layers: 24 procedural 1 px stars in two
  speeds drawn with `hline`, like the upstream `space-shooter` cart. Free.
- Ship is clamped to the play area with a 2 px margin and to x in [0, 104]
  so it can never reach the spawn column.

## 5. Player

- Ship cell 32x24; art shows Snouty in a cockpit, thruster at the back.
  Three body poses: level, banking up, banking down (chosen from the joystick
  y input with a 6-tick hysteresis so it doesn't flicker). Thruster flame is a
  separate 8x8 4-frame loop overlaid at the tail, 3 ticks per frame.
- Speed: 1.5 px/tick (90 px/s) on both axes; diagonal is not normalised
  (classic shooter feel, and it makes dodging diagonally slightly better).
- Hitbox: 6x6 centered on the cockpit, not the whole sprite. This is the
  single most important bullet-hell rule; the art brief marks where it sits.
  Drawn as a faint dot when the ship is invulnerable so players learn it.
- Zapper: A. While held, fires one bolt every 6 ticks (10/s). Bolt travels
  4 px/tick, cell 16x8, 2-frame flicker. Damage 1. Pool of 24 bolts. Bolts
  vanish at x >= 160 or on hit.
- Bomb: B, when stock > 0 and no bomb is active. Effect over 30 ticks:
  1. tick 0: every enemy bullet on screen is deleted; every non-boss enemy
     dies with its explosion; the boss takes 8 damage. Player is
     invulnerable until tick 30 ends.
  2. ticks 0..30: an expanding ring (procedural `oval` outline, 2 colors)
     from the ship out past the screen corners; the screen background is
     replaced by a flat flash color for ticks 0..3.
  3. Neopixels: all five white at 8/255 for 6 ticks, then back to bomb stock.
  Stock starts at 2, max 3. +1 at the end of each stage and every 5,000
  points. Bombs are the intended escape hatch, so they are cheap.
- Lives: 3. Losing one: ship explodes (32x32, 6 frames), 60-tick pause with
  no enemy fire and bullets frozen, then respawn at (16, 64) with 120 ticks of
  invulnerability (ship drawn every other tick). All enemy bullets are cleared
  on respawn, bombs refill to at least 1.
- Score: points per enemy (section 6), +1 per graze (an enemy bullet passing
  within 4 px of the hitbox without touching it, once per bullet). Extra life
  at 10,000 and every 20,000 after. Score caps at 999,999.

## 6. Enemies (the bugs)

Every enemy: position (f32), a movement program, HP, a fire program, score.
Fixed pool of 24. Sizes are cells; visible art may be smaller. Names are
flavor and appear on the title-screen bestiary (optional, M5).

| Name (flavor)          | Cell   | HP | Speed px/tick | Movement                                                          | Fire                                                                | Pts |
|------------------------|--------|----|---------------|-------------------------------------------------------------------|---------------------------------------------------------------------|-----|
| Off-by-one (gnat)      | 8x8    | 1  | 1.0           | Straight left with a sine wobble, amplitude 8, period 40 ticks. Comes in strings of 5 with 12-tick spacing. | None. Pure fodder and zapper feedback.                              | 10  |
| Race Condition (wasp)  | 16x16  | 1  | 2.5           | Enters at speed, pauses 20 ticks at x=120, then charges straight at the ship's position at that moment. | None; it *is* the bullet.                                          | 30  |
| Memory Leak (beetle)   | 16x16  | 4  | 0.5           | Slow straight left, stops at x=112, sits 240 ticks, leaves left.  | Every 45 ticks: a 3-way spread aimed at the ship, 1.0 px/tick.     | 50  |
| Deadlock (spider)      | 16x16  | 2  | 1.5 (drop)    | Drops from the top on a 1 px thread to a random y in [24, 72], hangs 180 ticks, climbs back up. Thread drawn with `vline`. | Every 30 ticks while hanging: 5-way ring segment, 0.8 px/tick.     | 40  |
| Segfault (moth)        | 16x16  | 2  | 1.2           | Erratic: picks a new random target point every 30 ticks, moves toward it. | Every 20 ticks: one aimed shot, 1.5 px/tick. Fast but singular.    | 40  |
| Heisenbug (boss)       | 48x48  | 60 | see below     | Section 7.                                                        | Section 7.                                                          | 500 |

Enemy bullets: pool of 96. Two kinds: round 6x6 (cell 8x8, 2 frames) and
needle 8x4 (cell 8x8, 1 frame, drawn from the round sheet). Speeds 0.6 to
1.5 px/tick. Bullets die off screen (4 px margin) or on the bomb. Max speed
is deliberately low: on a 160 px screen, 1.5 px/tick crosses in ~1.8 s, which
is the fastest thing a player can read at lanyard scale.

Hit feedback: enemy flashes white (palette swap to all-index-15) for 2 ticks
on damage; a 3-frame 8x8 spark at the bolt's position; a triangle blip.

Death: 16x16 5-frame explosion, 3 ticks per frame. Boss and player use the
32x32 6-frame explosion.

## 7. Boss: the Heisenbug

Appears at the end of each stage. Cell 48x48, 4-frame idle loop (wings), one
"flicker" frame (partially transparent look, drawn as every-other-pixel skip
in code, not art). HP 60, +20 per loop.

Movement: enters from the right to x=104, then bobs on a vertical sine
(amplitude 32, period 240 ticks). Every 300 ticks it *teleports*: 20 ticks of
flicker frame, then it vanishes and reappears at a new y (and x in [96,112]).
While flickering it cannot be hit. This is the joke: it disappears when you
look at it.

Fire, cycling through three phases of 240 ticks:

1. Ring: 12-way ring every 40 ticks, rotating 15 degrees per volley,
   0.8 px/tick.
2. Aimed stream: 3 aimed bullets 8 ticks apart every 60 ticks, 1.5 px/tick,
   plus a slow 5-way spread (0.6 px/tick) every 90 ticks.
3. Spiral: one bullet every 4 ticks from an emitter rotating 11 degrees per
   shot, 1.0 px/tick. Classic, dense, dodgeable by circling.

Death: 60-tick sequence of 6 small explosions across the body, then the big
one, then a 500 pt score pop, +1 bomb, next stage.

## 8. Game flow, demo mode and takeover

```
boot -> TITLE (10 s, "PRESS A" blinking)
     -> DEMO (autopilot plays, "DEMO" flashes in the HUD center)
         -> any A/B/Start/joystick input -> PLAYING (takeover, see below)
         -> autopilot loses all lives -> TITLE
         -> 5 minutes elapsed -> TITLE (so the loop shows the title again)
TITLE -> A/B/Start -> PLAYING (fresh game, seeded from micros_since_boot)
PLAYING -> lives = 0 -> GAME OVER (score, "PRESS A", 8 s) -> TITLE
PLAYING -> Start -> PAUSED -> Start -> PLAYING
```

Takeover: the ship, enemies and bullets stay exactly where they are. The
score resets to 0, lives to 3, bombs to 2, the "DEMO" tag is replaced by a
"GO!" pop for 60 ticks, and 60 ticks of invulnerability are granted so the
first frame is fair. Human input starts driving on the very next tick. This is
deliberately not a restart: the whole point is that the screen already looks
alive and the player just joins it.

Idle: a human game never falls back to demo mid-game (a paused game stays
paused). Only TITLE and GAME OVER time out into DEMO.

### 8.1 Autopilot (preferred)

Every tick, in DEMO the autopilot writes a `Controls` value that the rest of
the game reads through the same path as real input. It is a small heuristic:

1. Danger map: for each of 15 candidate y positions (every 8 px), sum a
   danger score from every enemy bullet and every wasp whose predicted
   position over the next 30 ticks passes within 10 px of that point at the
   ship's x. Closer in time counts more.
2. Choose the lowest-danger y within 24 px of the current y (bias toward the
   vertical center when tied). Move toward it; also drift x toward 24.
3. Fire: A is held always.
4. Bomb: press B when the sum of danger at the current y exceeds a threshold,
   or when a bullet will hit the hitbox within 6 ticks and no candidate y
   escapes it, or when the boss is at full HP in phase 3.
5. Add jitter: every 20 ticks, 25% chance to hold a random direction for 10
   ticks, so the demo looks alive rather than robotic.

Deterministic: DEMO uses a fixed PRNG seed, so a demo run is reproducible in
the headless preview and a regression in the autopilot shows up as a changed
frame dump. The preview harness gains `--frames 18000` runs that assert the
autopilot survives at least the first stage.

### 8.2 Recorded input (fallback)

If autopilot quality is disappointing, the demo replays a recorded input
log: an array of `{ tick: u32, controls: u16 }` deltas captured from a human
run in the simulator with the demo seed (the preview harness gets a
`--record` flag, and `serve-cart.mjs` a small "record inputs" endpoint). Same
seed + same inputs = same game, since nothing else is nondeterministic. The
log for a 3-minute run is a few hundred entries. Takeover works identically:
replay stops, human input starts. Either way the demo/human boundary is one
function that returns a `Controls`.

## 9. Waves and stages

A stage is a script: a sorted table of `{ at_tick, kind, y, count, spacing }`
entries plus a boss at the end. Stage 1 is about 75 s before the boss:

```
   0 s  gnats x5 at y=40, gnats x5 at y=80 (learn the zapper)
   8 s  beetle at y=64
  14 s  gnats x5 sine at y=30; wasp at y=100
  22 s  spider x2; gnats x5
  32 s  moth x2; beetle x2 at y=40, y=88
  44 s  wasp x3 staggered 30 ticks; spider
  54 s  moth x3, beetle, gnats x10 (two strings)
  66 s  everything quiets; "WARNING" text flashes 3 s; boss enters at 72 s
```

Stage 2 and later reuse the same table with `loop` applied: enemy HP +1 per
loop for beetles and spiders, bullet speeds x1.1 per loop (capped at 2.0
px/tick), fire intervals x0.9 per loop (floored at half), boss HP +20. Three
loops is more than any badge session will see.

Spawn x is always 168 (just off the right edge). Spawn y comes from the
table, or if `y == random` from the PRNG within [16, 104].

## 10. HUD, title, game over

- HUD (y 0..7): score as 6 digits in the built-in 8x8 font at x=0; bomb
  icons 8x8 centered (up to 3); lives as Snouty-head icons 8x8 right-aligned
  (up to 5 shown). Background Anti-Black. In DEMO, "DEMO" replaces the bombs
  every other half second; in the first 60 ticks after takeover, "GO!".
- Title: title logo image 128x40 at (16, 20) over a slowly scrolling
  background; "PRESS A" 8x8 font blinking at y=96; small "Antithesis" in
  Coral at y=116 with Iris marks (reuse `iris_16.png` from snouty-badge).
- Game over: "GAME OVER" 8x8 font, score, best score this boot, then title.
- Pause: "PAUSED" over the frozen frame, dimmed by drawing every other pixel
  black (cheap, looks intentional).

## 11. Audio and neopixels

All effects through `tone2`; each call cancels the previous one, so priority
order (later wins in the same tick): bomb > player death > extra life > enemy
death > player hit spark > zapper. The zapper is quiet (volume 0.3) and only
plays on every third bolt so it does not drown everything.

| Event         | Shape    | Frequency                          | Duration |
|---------------|----------|------------------------------------|----------|
| Zapper        | square   | 880 Hz                             | 0.04 s   |
| Enemy hit     | triangle | 1200 Hz                            | 0.03 s   |
| Enemy death   | square   | 220 Hz                             | 0.10 s   |
| Player death  | sawtooth | 110 Hz                             | 0.50 s   |
| Bomb          | minor    | 55 Hz                              | 0.60 s   |
| Extra life    | major    | 660 Hz                             | 0.30 s   |
| Boss enters   | minor    | 82 Hz                              | 0.80 s   |

Neopixels (GRB, max 10/255): the five LEDs show bomb stock (Coral, one LED
per bomb, from the left). Bomb: all white 8/255 for 6 ticks. Player hit: all
red 10/255 for 10 ticks. Boss death: chase pattern for 60 ticks. Off when
sound is off (Select).

## 12. Asset manifest

Everything is 4-bit indexed (15 colors + transparent index 0) unless noted.
Exact production parameters for the art agent are in `ASSETS.md`; this table
is what the code expects. Sizes in bytes are the packed 4-bit index arrays.

| Sheet                 | Cell   | Frames | Sheet px  | Bytes  | Notes                                            |
|-----------------------|--------|--------|-----------|--------|--------------------------------------------------|
| `ship.png`            | 32x24  | 3      | 96x24     | 1,152  | level, bank up, bank down; cockpit hitbox marked  |
| `thruster.png`        | 8x8    | 4      | 32x8      | 128    | flame loop                                       |
| `bolt.png`            | 16x8   | 2      | 32x8      | 128    | zapper bolt flicker                              |
| `bugs_small.png`      | 8x8    | 4      | 32x8      | 128    | gnat 2-frame wing loop, bullet round 2 frames    |
| `bugs.png`            | 16x16  | 10     | 160x16    | 1,280  | wasp x2, beetle x2, spider x2, moth x2, needle bullet, bomb pickup |
| `boss.png`            | 48x48  | 5      | 240x48    | 5,760  | 4 idle wing frames + 1 flicker/teleport frame    |
| `fx_small.png`        | 16x16  | 8      | 128x16    | 1,024  | explosion x5, spark x3                           |
| `fx_big.png`          | 32x32  | 6      | 192x32    | 3,072  | big explosion                                    |
| `hud.png`             | 8x8    | 4      | 32x8      | 128    | Snouty head (life), bomb, bomb (empty), heart    |
| `title.png`           | 128x40 | 1      | 128x40    | 2,560  | logo lettering                                   |
| `bg_far.png`          | 256x120| 1      | 256x120   | 15,360 | tileable horizontally; opaque, 8-bit allowed (30,720 B) |
| `bg_near.png`         | 256x24 | 1      | 256x24    | 3,072  | tileable horizontally; transparent over far layer |
| `iris_16.png`         | 16x16  | 1      | 16x16     | 128    | from snouty-badge, already exists                 |
| Total                 |        |        |           | ~34 KB | (~49 KB with an 8-bit far layer)                 |

Bullets and the bomb ring are the only things drawn procedurally besides text
and the starfield. Everything else is art.

## 13. Architecture

Fixed-size pools, no allocation, no floating-point transcendental calls at
runtime (a 256-entry sin table is built at comptime). f32 for positions and
velocities is fine: the RP2354's Cortex-M33 has an FPU and upstream's
`space-shooter` does the same.

```
cart/src/
  main.zig        start/update, game-state machine (TITLE/DEMO/PLAYING/PAUSED/GAME_OVER),
                  wasm shims (present_wasm, read_controls)
  input.zig       Controls source: hardware/sim, autopilot, or replay; edge detection
  draw.zig        draw_sprite (any cell size, index-0 transparency, optional white flash,
                  optional every-other-pixel skip), draw_bg (two scrolling layers), text helpers
  player.zig      ship state, movement, zapper, bombs, lives, invulnerability
  enemies.zig     enemy pool, per-kind movement + fire programs, boss
  bullets.zig     enemy bullet pool + player bolt pool, movement, off-screen cull
  patterns.zig    ring/spread/aimed/spiral emitters writing into the bullet pool
  waves.zig       stage tables and the spawner
  collide.zig     AABB checks: bolts vs enemies, bullets/enemies vs hitbox, graze
  fx.zig          explosion/spark pool, bomb ring, screen flash, hit-stop
  autopilot.zig   section 8.1
  replay.zig      section 8.2 (only if needed)
  audio.zig       tone2 wrappers with the priority rule; neopixels
  hud.zig         HUD, title, game over, pause overlay
  rng.zig         xorshift32 seeded per game
tools/
  prepare_assets.py  alpha -> magenta key, strip assembly, palette checks, feet/anchor rows
  preview.mjs        headless run; extend --press to all buttons and add --script inputs.json
  serve-cart.mjs     as in snouty-badge
  make_gif.py        as in snouty-badge
```

Update order per tick: read controls -> state machine -> spawner ->
player -> enemies (move, fire) -> bullets/bolts move -> collisions -> fx ->
draw (bg, near layer, bullets under sprites? no: enemies, ship, bolts, enemy
bullets on top so they are always visible, fx, HUD) -> audio/neopixels ->
present.

Drawing order puts enemy bullets above everything except the HUD and fx.
Readability of bullets is the game.

## 14. Verification

- `zig build` produces `zig-out/firmware/snouty-bugs.uf2` and
  `zig-out/bin/snouty-bugs.wasm`.
- `node tools/preview.mjs zig-out/bin/snouty-bugs.wasm --frames 3600 --every 6 --out out/`
  then `python3 tools/make_gif.py out/ demo.gif --scale 3 --ms 100` gives a
  one-minute GIF of the demo. Every milestone ships one in `docs/`.
- Autopilot soak: `preview.mjs --frames 18000 --seed 1 --quiet` must not trap
  and the final frame must not be GAME OVER (a tiny pixel check against the
  HUD lives area, scripted in `tools/check_demo.mjs`).
- Input scripts: `--script inputs.json` drives all buttons per tick range
  so the takeover, pause and bomb paths are exercised headlessly.
- Hardware: FPS overlay (joystick click) must read 60 during the boss with
  the bullet pool near full. If it dips, first drop the far layer to 4-bit,
  then halve the starfield, then reduce the bullet pool to 64.
- Every review round: Adrian runs the simulator locally (docs/RUNNING.md,
  copied from snouty-badge once the cart draws something).

## 15. Milestones

Each milestone is a tag, a preview GIF in `docs/`, and a "how to pull and
run" note in the hand-off message. Parallelisable chunks go to Opus
subagents, as with `snouty-badge`.

- **M0 Scaffold** (this commit): repo, build, stub title card, spec, asset
  brief. `zig build` works.
- **M1 Flying**: parallax background (placeholder tiles), ship movement with
  banking, zapper, gnats, collisions, score. Playable in the simulator.
- **M2 Bullet hell**: all five enemy kinds, patterns, enemy bullets, bombs,
  lives, HUD, explosions, graze. Balance pass on speeds.
- **M3 Stages and boss**: wave tables, the Heisenbug, stage loop, warning.
- **M4 Attract mode**: title, autopilot demo, takeover, game over, pause,
  deterministic soak test. Decide autopilot vs replay here.
- **M5 Polish**: final art drop-in, audio, neopixels, Select toggle, title
  bestiary, tuning from hardware play.

Parallel tracks: art (external agent, per `ASSETS.md`) runs alongside M1 to
M3 using placeholder sprites; the asset prep script is written against the
brief so the real sheets drop in without code changes.

## 16. Open questions for Adrian

- Repo name and GitHub remote: scaffolded locally as `snouty-bugs`; rename
  before pushing if you want something else.
- Sound default off, on-badge toggle on Select: agree?
- Boss flavor name "Heisenbug" and the software-bug enemy names: keep, or go
  with plain insect names on screen?
- Graze scoring: keep (bullet-hell tradition, teaches the small hitbox) or
  drop for simplicity?

## Status

- 2026-09-26: M0 scaffolded. Build verified on the VM. Nothing tagged yet.
