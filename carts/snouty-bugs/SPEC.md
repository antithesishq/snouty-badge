# Snouty vs. the Bugs: game spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Second cart for the badge, alongside `snouty-badge` (the running/jumping
Snouty). Status and milestones are at the bottom.

## 1. One paragraph

A horizontal bullet-hell shooter. Snouty pilots a small ship on the left of the
screen, flying right over a scrolling parallax background. Bugs (the software
kind, drawn as the insect kind) fly in from the right in scripted waves and
fill the screen with slow, dense, readable bullet patterns. A fires the zapper,
holding B rewinds time for as long as you can afford it (section 5.2), the
joystick moves the ship. Getting hit does not kill you: the game names the bug that
got you, rewinds the last two seconds in front of your eyes, and hands the
ship back so you can dodge it this time (section 5.1). Left alone, the cart
plays itself in an attract/demo loop; the moment anyone touches a button, the
ship is theirs, mid-flight, no reset.

## 2. Hardware and platform facts the design leans on

- Screen 160x128, landscape. Horizontal scroller fits the shape and reuses
  Snouty's right-facing art direction.
- 60 Hz `update()`. All timing is in ticks (1 tick = 1/60 s). No delta time.
- Inputs: joystick up/down/left/right, A, B, Start, Select, joystick click.
  The OS owns two combos: Start+Select held 250 ms exits to the cart menu, and
  joystick click toggles the FPS overlay. The game never binds click.
- Audio: `tone2`, one voice, six wave shapes, cancels whatever was playing.
  Sound design is therefore one channel of short effects, no music.
- 5 neopixels: off. The cart never writes non-zero values (root
  `docs/NEOPIXELS.md`; a coworker's badge shows the LEDs are unusably bright
  even at 1%, 2026-09-29).
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
| B                 | Start a hardcore game        | Hold: rewind time (spends fuel)          | Take over                     |
| Start             | Start a game                 | Pause / unpause                          | Take over                     |
| Select            | Toggle sound                 | Toggle sound                             | Toggle sound                  |
| Click             | OS: FPS overlay              | OS: FPS overlay                          | OS: FPS overlay               |
| Start+Select 250ms| OS: exit to menu             | OS: exit to menu                         | OS: exit to menu              |

During a REWIND (section 5.1) the game ignores every input except Select and
the OS combos; a takeover request made during a demo rewind is applied when
the rewind ends. Select does not count as "interaction" for the demo takeover. Sound is
off by default so the badge is quiet on a lanyard; the setting
is not persisted (the flash save API returns 0 bytes upstream).

## 4. Screen layout

```
y   0..7     HUD: score (left), rewind fuel bar (center), rewinds (right). 8 px.
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
- Hold-B rewind: see section 5.2. There is no bomb (dropped 2026-09-27: the
  rewind is the better escape hatch and the better show, and it keeps the
  pattern on screen instead of wiping it).
- Rewinds: 3 (they replace lives; none in hardcore, section 5.3). Getting
  hit with a rewind in stock spends it and runs the rewind sequence in
  section 5.1: the world goes back two seconds and play resumes from there.
  The auto rewind costs no fuel in normal mode. Getting hit with none left is
  death: ship explodes (32x32, 6 frames), 60 ticks of frozen bullets and no
  enemy fire, then GAME OVER. Extra rewind at 10,000 points and every 20,000
  after, max 5.
- Score: points per enemy (section 6), +1 per graze (an enemy bullet passing
  within 4 px of the hitbox without touching it, once per bullet). A graze
  also adds 2 fuel (section 5.2). Score caps
  at 999,999. Score is part of the world, so a rewind takes it back too, along
  with the kills and grazes of those two seconds.

### 5.1 Getting hit: the rewind

The Antithesis mechanic. The game is fully deterministic (section 13), so it
can keep snapshots of the world and replay from recorded input, exactly the
way Antithesis rewinds a system to the moment before a bug. When the hitbox
is touched and a rewind is in stock:

1. **Bug report, 20 ticks.** Hit-stop: nothing moves, the ship is drawn
   with its hitbox as a red dot, the offending bullet or enemy flashes
   white. A centered 8x8-font message in Coral on an Anti-Black bar at y=56
   names the bug, chosen from the kind of enemy that fired the bullet (or
   rammed the ship). (M4: the bar moves to y 88..103 or y 20..35 when the
   ship's sprite would be under it, and keeps that row for the whole
   sequence; `GO!` uses the same row.)

   | Hit by                          | Message              |
   |---------------------------------|----------------------|
   | Off-by-one (gnat)               | `OFF BY ONE`         |
   | Race Condition (wasp)           | `RACE CONDITION`     |
   | Memory Leak (beetle) bullet     | `OUT OF MEMORY`      |
   | Deadlock (spider) bullet        | `DEADLOCK`           |
   | Segfault (moth) bullet          | `ACCESS VIOLATION`   |
   | Heisenbug (boss) or its bullets | `UNDEFINED BEHAVIOR` |

   Enemy bullets carry the `Kind` of their emitter for this. The longest
   message is 18 characters, 144 px, which fits the 160 px screen.
2. **Reverse playback, 60 ticks.** The world plays backward 120 game ticks
   at two ticks per frame. Everything reverses: bullets retreat, dead bugs
   un-explode, the score counts down, the background scrolls right. The
   message bar stays, `<<` blinks in the HUD status slot (x 48..63), and
   the frame is dimmed by drawing every other scanline black (the pause
   look, so it reads as "not live"). Inputs are ignored.
3. **Resume.** The world is restored to exactly its state 120 ticks before
   the hit, including every enemy bullet then in flight (that is the point:
   you have seen what comes next). The player gets 60 ticks of
   invulnerability and a `GO!` pop for 30 ticks. Human input drives from the
   first resumed tick. Recorded input after the resume point is discarded, so
   the future is the player's to change.

If less than 120 ticks of history exist (early in a game, or a second hit
soon after a rewind), the rewind goes back as far as it can and the
playback is proportionally shorter (2 ticks per frame). The rewind count is
not part of the rewound world, so a rewind cannot refund itself. B during a
rewind does nothing. In DEMO the autopilot's input is
recorded like a human's, so the demo shows death-rewinds too; that is the
best advertisement the mechanic gets.

Why the score rewinds: honesty. The snapshot is the whole world, and a rule
that says "everything goes back except the number in the corner" is the kind
of special case that makes replays diverge. It also means a rewind is never
free, even with stock left.

### 5.2 Hold-B rewind and the fuel bar

The same machinery, under the player's thumb. While B is held in PLAYING the
world runs backward 2 game ticks per frame (half a second of holding undoes
a full second), enemies and bullets included; nothing is wiped, the last
second simply un-happens and the player threads the pattern differently.
Joystick, A and Start are ignored during the hold. On release the history
after the resume point is discarded and live input drives the next tick.
No invulnerability, no `GO!`: the player chose the moment. A press with no
fuel, or with no history to go back to, does nothing.

Fuel is a bar of 180 ticks (3 s), full at the start of a game, spent 2 per
frame while rewinding. It refills 1 tick per 10 ticks of live play (empty to
full in 30 s), never during a pause, freeze, playback or rewind; a graze adds
2; a stage clear fills it. Fuel is meta-state, outside the World: a rewind
moves the World's clock, so fuel kept inside it would be restored along with
everything else and rewinds would be free.

Look: the frame dims every other scanline and `<<` blinks in the HUD status
slot, as in reverse playback, but there is no message bar and the fuel bar
stays visible so the player can watch it drain. Sound: the rewind sweep of
section 11 while held.

### 5.3 Hardcore mode

B on the title starts a hardcore game: no rewind stock (the HUD shows `HARD`
where the icons would be), so a hit is paid from the fuel bar. The bug
report runs as in 5.1, then the world rewinds as far as fuel allows, up to
120 ticks, and that much fuel is spent. If fuel is below the fatal floor of
45 ticks when the hit lands, the hit is fatal: the report names the bug,
then reads `UNRECOVERABLE`, and the game is over. The bar fill turns red
below the floor. The floor is what makes a death loop impossible: every hit
costs at least 45 or ends the game, and the bar refills far slower than
that between one resume and the next hit, so a player who keeps getting hit
runs out within a few hits instead of rewinding one frame forever. There
is no consolation refill after a hit.

### 5.4 Powerups: crates, weapons, the fork (M6)

Bugs drop crates. Collecting one (any overlap with the 32x24 ship cell)
scores 100 and grants something; everything granted lives in the World, so
a rewind that crosses the collection takes it away again and the crate is
back on screen to be grabbed a second time. That is Raiden's power loss
without a special rule: the snapshot is the whole world.

**Weapons.** Three kinds, each a crate with a letter, stacking to level 5
on the same kind and swapping kind (level kept) on a different one. Every
weapon fires on A at the zapper's cadence. The HUD status slot shows the
weapon as letter plus level (`F3`). Default: FUZZER level 1, which is the
plain zapper.

| Crate | Weapon  | Bolt                     | Levels 1..5                                                    |
|-------|---------|--------------------------|----------------------------------------------------------------|
| F     | FUZZER  | zap, dies on hit, 4 px/t | single; twin; 3-way; 5-way; 5-way with random angle jitter    |
| A     | ASSERT  | beam, pierces, 6 px/t    | 1 beam; damage up; 2 beams; damage up; 3 beams (dmg 1,1,2,2,3) |
| B     | BISECT  | seeker, homes, 3.5 px/t  | 1; 2; 3; 4; 5 seekers, steering tighter per level             |

The fuzzer covers the screen (literally fuzzing), the assert goes through
every bug in its row (narrow, exact, nothing gets past), the bisect finds
the culprit. A crate at max level, or a fork or retry you already have,
scores 500 instead.

**FORK.** A ghost ship that replays the player's own trajectory from 24
ticks ago and fires the current weapon whenever the ship fired then. A
second fork sits 48 ticks behind, a third 72. Ghosts have no hitbox and
collect nothing; they are drawn with the every-other-pixel dither of the
Heisenbug and the pause screen, so they read as branches rather than
ships. The World records the ship's position every tick for this, so the
ghosts rewind with everything else and a fork collected is history-ready
at once.

**RETRY.** A one-hit shield (a small icon floats above the ship). When it
absorbs a hit the message line reads `FLAKY, RETRYING`, the offender
vanishes, the ship gets 60 ticks of invulnerability, and no rewind or fuel
is spent.

**CORE HOURS.** A third of the fuel bar (60 ticks). Fuel is meta-state, so
this is paid against a high-water mark on a World counter: a crate rewound
away and collected again pays once (section 13.1).

**Drops.** A Memory Leak beetle killed by a bolt (leaks drop memory); every
fifth gnat shot down; each change of the Heisenbug's fire phase. Crates
drift left at 0.5 px/tick on a gentle sine and leave at the left edge.
Crate kinds follow a fixed sequence (no randomness): current weapon, core
hours, current weapon, fork, the next weapon kind, retry, current weapon,
fork, and round again. Stacking is the default; a swap is on offer every
eight crates. Pool of 4 crates.

### 5.5 Difficulty: rank, stages, power loss (M7)

Adrian, 2026-10-04: too easy, especially holding A with powerups; make it
a real bullet hell whose patterns escalate (1942, Raiden X). The design,
with every number in PLAN.md M7:

- **Rank** (Raiden, Battle Garegga): a World value 0..1000 from the
  stage, the time spent in it, the loop and the player's firepower,
  minus a mercy term a hit adds to. It speeds enemy bullets up, shortens
  fire intervals, adds bullets to patterns, adds enemy HP and turns on
  revenge bullets. The stronger you are, the harder it pushes back.
- **Four stages**, `UNIT TESTS`, `INTEGRATION`, `STAGING`,
  `PRODUCTION`, each adding bugs and pattern ideas, midbosses from stage
  2, four different bosses with HP-gated phases, then a second loop.
- **A pattern engine**: bullets that accelerate, brake, curve, split and
  re-aim; pellets and orbs; a 128-bullet pool. The ship's hitbox shrinks
  to 4x4 and bullet hitboxes shrink with it, so dense screens stay fair.
- **Power loss**: a hit that triggers the auto rewind costs one weapon
  level and one fork once the world is restored. Ghosts fire a level-1
  shot. Crates come from whole formations (1942's POW), every second
  beetle, the midboss and each boss phase break.

This supersedes the 1.5 px/tick speed cap of section 6 (rank-scaled caps
per shape, 2.0 to 2.6) and the loop modifiers of section 9.

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
needle 8x4 (cell 8x8, 1 frame, drawn from the round sheet). Each bullet
records the `Kind` of the enemy that fired it (section 5.1). Speeds 0.6 to
1.5 px/tick. Bullets die off screen (4 px margin). Max speed
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
one, then a 500 pt score pop, the fuel bar fills, next stage.

## 8. Game flow, demo mode and takeover

```
boot -> TITLE (10 s, "PRESS A" blinking)
     -> DEMO (autopilot plays, "DEMO" flashes in the HUD center)
         -> any A/B/Start/joystick input -> PLAYING (takeover, see below)
         -> autopilot is hit with no rewinds left -> TITLE
         -> 5 minutes elapsed -> TITLE (so the loop shows the title again)
TITLE -> A/B/Start -> PLAYING (fresh game, seeded from micros_since_boot)
PLAYING -> hit, rewinds > 0 -> REWIND (80 ticks, section 5.1) -> PLAYING
PLAYING -> hit, rewinds = 0 -> GAME OVER (score, "PRESS A", 8 s) -> TITLE
PLAYING -> Start -> PAUSED -> Start -> PLAYING
DEMO    -> hit, rewinds > 0 -> REWIND -> DEMO (takeover input is queued)
```

Takeover: the ship, enemies and bullets stay exactly where they are. The
score resets to 0, rewinds to 3, fuel to full, the "DEMO" tag is replaced by a
"GO!" pop for 60 ticks, and 60 ticks of invulnerability are granted so the
first frame is fair. Human input starts driving on the very next tick. This is
deliberately not a restart: the whole point is that the screen already looks
alive and the player just joins it.

Idle: a human game never falls back to demo mid-game (a paused game stays
paused). Only TITLE and GAME OVER time out into DEMO. The rewind history
(section 13) keeps recording across a takeover; the human simply continues
the world the autopilot was flying.

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
4. Rewind: hold B (section 5.2) when a bullet will hit the hitbox within 6
   ticks and no candidate y escapes it, for as long as the danger at the
   current y stays above a threshold or fuel runs out, then release and
   pick a new y. The demo therefore shows both kinds of rewind.
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

- HUD (y 0..7): score as 6 digits in the built-in 8x8 font at x=0; a
  status slot at x 48..63 (weapon letter + level, e.g. `F3`; `<<` blinking
  there during any rewind playback); the
  fuel bar at x 68..99 (1 px Anti-White frame, y 1..6; Coral fill 30x4
  inside, red below the hardcore floor); rewinds as Snouty-head icons 12x8
  right-aligned at x 100..159 (up to 5 shown), or `HARD` in Coral in
  hardcore.
  Background Anti-Black. In DEMO, "DEMO" is drawn over the fuel bar every
  other half second; in the first 60 ticks after a takeover or an auto
  rewind, "GO!" on the message line.
- Rewind overlay (section 5.1): Anti-Black bar y 52..67 across the screen,
  bug message centered in Coral at y=56; frame dimmed every other scanline
  during playback. Game over after a hit with no rewinds shows the same bug
  message above "GAME OVER".
- Title: "SNOUTY" (y 40) / "BUGHUNT" (y 52, Coral) in the 8x8 font over a
  slowly scrolling background (the `title.png` logo, 128x40 at (16, 20), is
  built but not drawn yet); the ship's level cell with its thruster loop
  bobbing 1 px at (64, 62); "A PLAY" (y 92) and "B HARDCORE" (y 104, Coral) blinking; small "Antithesis" in
  Coral at y=116 with Iris marks (reuse `iris_16.png` from snouty-badge).
- Game over: the fatal bug message, "GAME OVER" 8x8 font, score, best score
  this boot, then title.
- Pause: "PAUSED" over the frozen frame, dimmed by drawing every other pixel
  black (cheap, looks intentional).

## 11. Audio

All effects through `tone2`; each call cancels the previous one, so priority
order (later wins in the same tick): player death > rewind > extra life >
enemy death > player hit spark > zapper. The zapper is quiet (volume 0.3) and only
plays on every third bolt so it does not drown everything.

| Event         | Shape    | Frequency                          | Duration |
|---------------|----------|------------------------------------|----------|
| Zapper        | square   | 880 Hz                             | 0.04 s   |
| Enemy hit     | triangle | 1200 Hz                            | 0.03 s   |
| Enemy death   | square   | 220 Hz                             | 0.10 s   |
| Player death  | sawtooth | 110 Hz                             | 0.50 s   |
| Bug report    | sawtooth | 220 Hz                             | 0.30 s   |
| Rewind        | triangle | 110 to 880 Hz, retriggered every 4 ticks in 15 steps (no sweep in `tone2`) | 0.07 s each |
| Extra life    | major    | 660 Hz                             | 0.30 s   |
| Boss enters   | minor    | 82 Hz                              | 0.80 s   |

Select toggles sound. Sound starts off unless the cart is built with
`-Dsound=true` (`build_options.sound`, the repository rule in
docs/SOUND.md). The neopixels stay dark (section 2).

## 12. Asset manifest

Everything is 4-bit indexed (15 colors + transparent index 0) unless noted.
Exact production parameters for the art agent are in `ASSETS.md`; this table
is what the code expects. Sizes in bytes are the packed 4-bit index arrays.

| Sheet                 | Cell   | Frames | Sheet px  | Bytes  | Notes                                            |
|-----------------------|--------|--------|-----------|--------|--------------------------------------------------|
| `ship.png`            | 32x24  | 3      | 96x24     | 1,152  | level, bank up, bank down; cockpit hitbox marked  |
| `thruster.png`        | 8x8    | 4      | 32x8      | 128    | flame loop                                       |
| `bolt.png`            | 16x8   | 6      | 96x8      | 384    | zap flicker x2, assert beam x2, bisect seeker x2 |
| `bugs_small.png`      | 8x8    | 4      | 32x8      | 128    | gnat 2-frame wing loop, bullet round 2 frames    |
| `bugs.png`            | 16x16  | 10     | 160x16    | 1,280  | wasp x2, beetle x2, spider x2, moth x2, needle bullet, spare (was bomb pickup) |
| `boss.png`            | 48x48  | 5      | 240x48    | 5,760  | 4 idle wing frames + 1 flicker/teleport frame    |
| `fx_small.png`        | 16x16  | 8      | 128x16    | 1,024  | explosion x5, spark x3                           |
| `fx_big.png`          | 32x32  | 6      | 192x32    | 3,072  | big explosion                                    |
| `hud.png`             | 12x8   | 4      | 48x8      | 192    | Snouty head (rewind stock), retry shield, spare, heart |
| `pickups.png`         | 16x16  | 6      | 96x16     | 768    | crates: F, A, B, fork, retry, core hours          |
| `title.png`           | 128x40 | 1      | 128x40    | 2,560  | logo lettering                                   |
| `bg_far.png`          | 256x120| 1      | 256x120   | 15,360 | tileable horizontally; opaque, 8-bit allowed (30,720 B) |
| `bg_near.png`         | 256x24 | 1      | 256x24    | 3,072  | tileable horizontally; transparent over far layer |
| `iris_16.png`         | 16x16  | 1      | 16x16     | 128    | from snouty-badge, already exists                 |
| Total                 |        |        |           | ~34 KB | (~49 KB with an 8-bit far layer)                 |

Bullets and the fuel bar are the only things drawn procedurally besides text
and the starfield. Everything else is art.

## 13. Architecture

Fixed-size pools, no allocation, no floating-point transcendental calls at
runtime (a 256-entry sin table is built at comptime). f32 for positions and
velocities is fine: the RP2354's Cortex-M33 has an FPU and upstream's
`space-shooter` does the same.

### 13.1 The World and its history

Every piece of mutable play state lives in one plain struct, `World`, owned
by `world.zig`: player, enemy pool, bolt and bullet pools, fx pool, boss,
wave cursor, PRNG state, background scroll and star positions, the input
edge-detector's current and previous controls, and `game_tick`. Gameplay
modules keep their functions but operate on fields of the one global
`World`. Nothing in `World` is a pointer, so a snapshot is a struct copy and
two worlds compare with `std.mem.eql` on their bytes. Outside the world, and
therefore not rewound: the state machine, the rewind count (meta-state,
like lives), the rewind fuel (section 5.2: a rewind moves the World's
clock, so fuel inside it would be refunded by the rewind it paid for), best
score, `tick_total`, the sound toggle. Grants that come from world events
(graze fuel, the stage-clear refill, score rewinds) use a meta high-water
mark so a rewound-and-repeated event pays only once.

History (`history.zig`), the Antithesis part:

- Keyframes: a ring of 4 `World` copies, one saved every 60 game ticks just
  before that tick is simulated. At about 5 KB per `World` after M2 that is
  20 KB, and 240 ticks of coverage for a 120-tick rewind.
- Input log: a ring of 256 `u16` controls words, one per tick, written from
  whatever source drove the tick (hardware, autopilot, replay).
- `restore(tick)`: copy the newest keyframe at or before `tick` into the
  world, then feed the logged controls through `input.update` and run
  `simulate(.silent)` until `game_tick == tick`. Silent means no `tone2`; everything else (fx, score, spawns) runs, because
  it is all in the world. At most 59 catch-up ticks per restore.
- Reverse playback displays the world at `hit_tick - 2k` for k = 1..60, one
  `restore` per frame. Simulation without drawing is a few hundred entity
  updates and AABB checks, so 60 silent ticks should cost low single-digit
  milliseconds on the badge; the FPS overlay during a rewind is the check.
  Fallbacks if it dips: play back 3 or 4 ticks per frame, or save keyframes
  every 30 ticks (8 keyframes, ~40 KB).
- Determinism rules that make this work, already in force: tick-based
  timing, one seeded PRNG, no `cart.rand()`, no wall clock during play, and
  side effects (audio) derived from the world rather than stored in it.
  New code must keep to them; the identity test in section 14 catches slips.

```
cart/src/
  main.zig        start/update, game-state machine (TITLE/DEMO/PLAYING/PAUSED/GAME_OVER),
                  wasm shims (present_wasm, read_controls)
  input.zig       Controls source: hardware/sim, autopilot, or replay; edge detection
  draw.zig        draw_sprite (any cell size, index-0 transparency, optional white flash,
                  optional every-other-pixel skip), draw_bg (two scrolling layers), text helpers
  player.zig      ship state, movement, zapper, invulnerability, score
  enemies.zig     enemy pool, per-kind movement + fire programs, boss
  bullets.zig     enemy bullet pool + player bolt pool, movement, off-screen cull
  patterns.zig    ring/spread/aimed/spiral emitters writing into the bullet pool
  waves.zig       stage tables and the spawner
  collide.zig     AABB checks: bolts vs enemies, bullets/enemies vs hitbox, graze
  fx.zig          explosion/spark pool
  world.zig       the World struct and the one global instance (section 13.1)
  history.zig     keyframe ring, input log, restore(tick)
  rewind.zig      the hit -> bug report -> reverse playback -> resume sequence
  autopilot.zig   section 8.1
  replay.zig      section 8.2 (only if needed)
  audio.zig       tone2 wrappers with the priority rule
  hud.zig         HUD, title, game over, pause overlay
  rng.zig         xorshift32 seeded per game
tools/
  prepare_assets.py  alpha -> magenta key, strip assembly, palette checks, feet/anchor rows
  (preview.mjs, serve-cart.mjs, make_gif.py: shared, in ../../tools/)
```

Update order per tick: read controls -> state machine -> history (log the
controls, keyframe if due) -> spawner -> player -> enemies (move, fire) ->
bullets/bolts move -> collisions -> fx ->
draw (bg, near layer, bullets under sprites? no: enemies, ship, bolts, enemy
bullets on top so they are always visible, fx, HUD) -> audio ->
present.

Drawing order puts enemy bullets above everything except the HUD and fx.
Readability of bullets is the game.

## 14. Verification

- `zig build` (at the repository root) produces `zig-out/firmware/snouty-bugs.uf2` and
  `zig-out/bin/snouty-bugs.wasm`.
- `node ../../tools/preview.mjs ../../zig-out/bin/snouty-bugs.wasm --frames 3600 --every 6 --out out/`
  then `python3 ../../tools/make_gif.py out/ demo.gif --scale 3 --ms 100` gives a
  one-minute GIF of the demo. Every milestone ships one in `docs/`.
- Autopilot soak: `preview.mjs --frames 18000 --seed 1 --quiet` must not trap
  and the final frame must not be GAME OVER (a tiny pixel check against the
  HUD lives area, scripted in `tools/check_demo.mjs`).
- Input scripts: `--script inputs.json` drives all buttons per tick range
  so the takeover, pause and hold-B paths are exercised headlessly.
- Rewind identity: a wasm-only export `debug_history_check()` copies the
  current world aside, runs `history.restore(game_tick)` from the newest
  keyframe and the input log, and returns 0 only if the restored world is
  byte-identical. The harness calls it at several ticks of a scripted run
  and expects 0 every time. A second script flies the ship into a bullet and
  expects `debug_rewinds` to drop by one, `debug_state` to pass through
  REWIND and back to PLAYING, and the score after the rewind to equal the
  score 120 ticks before the hit.
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
- **M2 Bullet hell**: first the `World` refactor (section 13.1) while the
  code is still small, then all five enemy kinds, patterns, enemy bullets
  with their source kind, bombs, rewind stock in the HUD, explosions, graze.
  Getting hit spends a rewind but only grants invulnerability until M4.
  Balance pass on speeds.
- **M3 Stages and boss**: wave tables, the Heisenbug, stage loop, warning.
- **M4 Rewind**: history (keyframes, input log, restore), the bug-report
  and reverse-playback sequence, messages per enemy, the identity test,
  hardware timing check.
- **M5 Rewind bar**: the bomb goes; hold-B rewind paid from the fuel bar
  (5.2), hardcore mode (5.3), fuel HUD, title mode select.
- **M6 Powerups** (5.4): weapon crates (FUZZER, ASSERT, BISECT) stacking
  to level 5, the FORK ghost ships replaying the trail, RETRY shield, CORE
  HOURS fuel, drops from beetles, gnat strings and boss phases.
- **M7 Bullet hell for real** (5.5): rank, four stages, new bugs,
  midbosses and bosses, the pattern engine, power loss, the difficulty
  probe (bots in an endless god mode, PLAN.md M7 targets).
- **M8 Attract mode**: title, autopilot demo (grown from M7's probe
  dodger), takeover, game over, pause, deterministic soak test. The demo
  shows both rewinds.
- **M9 Polish**: Select sound toggle, title bestiary, tuning from
  hardware play.

Parallel tracks: art (external agent, per `ASSETS.md`) runs alongside M1 to
M3 using placeholder sprites; the asset prep script is written against the
brief so the real sheets drop in without code changes.

## 16. Open questions for Adrian

- Repo name and GitHub remote: scaffolded locally as `snouty-bugs`; rename
  before pushing if you want something else.
- Sound default off, on-badge toggle on Select: agreed 2026-09-30 for every
  cart (root docs/SOUND.md; the default comes from `-Dsound`).
- Boss flavor name "Heisenbug" and the software-bug enemy names: keep, or go
  with plain insect names on screen?
- Graze scoring: kept (2026-09-27); a graze also refills fuel (5.2).
- Rewind takes the score back with everything else (section 5.1): agreed
  2026-09-27.
- Bombs: dropped 2026-09-27 for the hold-B rewind (5.2) and hardcore (5.3).
- The bug messages in section 5.1: happy with the six, or different ones?

## Status

- 2026-09-26: M0 scaffolded. Build verified on the VM.
- 2026-09-26: M1 built and tagged `m1`: flying, zapper, gnats, collisions,
  score, pause, placeholder art (`docs/preview_m1.gif`). See PLAN.md.
- 2026-09-26: Rewind mechanic designed (section 5.1, 13.1): lives become
  rewinds, a hit names the bug and replays the last two seconds backward.
  Milestones renumbered: M4 Rewind, M5 Attract, M6 Polish.
- 2026-09-26: M2 built and tagged `m2`: `World` refactor, all five enemy
  kinds with their patterns, enemy bullets that record their source, bombs,
  graze, rewind stock in the HUD (a hit spends one; the sequence itself is
  M4), death, looping stage-1 spawner, `tools/check.sh` regression gate
  (`docs/preview_m2.gif`). See PLAN.md.
- 2026-09-26: M3 built and tagged `m3`: stage flow (WARNING at 66 s, boss
  at 72 s, clear, 120-tick breather, loop with the section 9 modifiers),
  the Heisenbug with its three fire phases and teleport, boss HP bar, +500
  and STAGE n pops, god/warp test hooks, nine regression scripts
  (`docs/preview_m3.gif`). See PLAN.md.
- 2026-09-26: M4 built and tagged `m4`: history keyframes (4 x World every
  60 ticks) and a 256-tick input log, exact restore, the bug-report /
  reverse-playback / `GO!` sequence, field-by-field identity check green on
  every frame of every script, twelve regression scripts
  (`docs/preview_m4.gif`). Bomb stock moved into the World (13.1). Hardware
  FPS check during a rewind still to do on the badge.
- 2026-09-27: Adrian played m4 locally and confirmed the rewind timing. The
  bomb is dropped for a hold-B rewind paid from a fuel bar (5.2) and a
  hardcore mode (5.3). Milestones renumbered: M5 Rewind bar, M6 Attract,
  M7 Polish.
- 2026-09-27: M5 built and tagged `m5`: the bomb is gone, hold-B rewind on
  the fuel bar (5.2), hardcore mode (5.3), fuel HUD, A/B title
  (`docs/preview_m5.gif`). See PLAN.md.
- 2026-09-29: Adrian: the 8x8 Snouty head icon (rewind stock, title card)
  looked like a rat. `hud.png` cells are 12x8 now (10x6 visible head with
  a round ear, a 2x2 eye and a blunt snout tube). A 48x48 bust portrait
  was tried for the title card and dropped the same day: the title card
  draws the game's ship sprite instead. The game's title is "Snouty
  Bughunt" (was "Snouty vs. the Bugs"; repo, cart and doc names unchanged).
  Review image `docs/snouty_icons_2026-09-29.png`.
- 2026-10-02: Powerups designed (5.4) at Adrian's request: Raiden-style
  stacking weapon crates as testing tools plus the FORK (ghost ships
  replaying the player's own trail), RETRY and CORE HOURS. M6 Powerups;
  attract mode becomes M7, polish M8. See PLAN.md M6.
- 2026-10-02: M6 built and tagged `snouty-bugs/m6`: crates, the three
  weapons, forks, retry, core hours, drops (`docs/preview_m6.gif`). See
  PLAN.md M6 and its status entry. Next: M7 attract mode.
- 2026-10-04: Adrian: far too easy, especially holding A with powerups.
  M7 "Bullet hell for real" designed (5.5, PLAN.md M7); attract mode
  becomes M8, polish M9.
