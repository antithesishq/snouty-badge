# Snouty Cycles: cart spec

Status: spec 2026-10-04. Adrian asked for "a tron lightcycle game", built from
the best prior art, specced and then built with subagents. Every open choice
has a default in section 14; the build goes ahead on those defaults.

Light cycles and CPU cycles. A top-down light-cycle arena for the SYCL badge:
you ride a cycle that leaves a wall behind it, and so do up to three AI
programs. Hit a wall and you derez. When you crash, Antithesis-style time
travel rewinds the round (the trails pull back into the cycles) and you try
again.

## 1. Prior art and what we take from it

We used only well-regarded references. The research notes are summarised
here; links are for the reader.

| Reference | Why it counts | What we take |
|---|---|---|
| Gremlin **Blockade** (1976), Atari **Surround** (1977) | Started the genre; Surround was a highlight of the VCS launch | 90° turns on a grid, short rounds with a match target, Surround's option set (speed up, wraparound) as modifiers |
| Bally Midway **TRON** (1982), light-cycle sub-game | Coin-Op Game of the Year, about 10k cabinets | Top-down view of the whole arena; 1 to 3 enemy cycles; a level ladder **named after programming languages**; deterministic, learnable enemies; a crashed cycle's wall vanishes |
| **Armagetron Advanced** (2000 to now, GPL) | 25 years active, millions of downloads, tournament scene, "about as perfect as freeware gets" (RPS) | **Grinding** (speed up near walls, sparks), **rubber** (a short stall before a crash, from a draining meter), brake reservoir, 5% speed tax per turn, minimum time between turns, dead walls that stay up briefly, sumo's shrinking zone |
| **GLtron** (1999 to 2016, GPL) | Long-lived, widely ported | Booster button plus wall-ride, sharing one energy idea |
| **Achtung, die Kurve!** (1995) / Curve Fever | Cult LAN classic with tournaments | Random gaps in trails (modifier), one point per opponent outlived |
| **Google AI Challenge 2010: Tron** (a1k0n's winning bot), **CodinGame Tron Battle** | about 700 entries; the winner published a write-up; ladder running for over 10 years | Voronoi territory evaluation (cells plus edges), articulation-point "chambers", wall-hugging endgame fill with a parity bound, alpha-beta at shallow depth, paranoid search with several opponents |

What we deliberately skip:
- 3D and chase cameras. Reviews of Tron 2.0's spin-off and Tron: Evolution say the camera hid the trails and caused needless crashes. The badge shows the whole arena.
- Power-up pickups. The beloved games are pure; at most one resource, the energy bar.
- Monte Carlo tree search. The challenge showed it plays Tron badly.

## 2. Hardware facts the design leans on

- RP2354B Core 1, Cortex-M33 at 150 MHz. The budget at 60 fps is 2.5 M cycles per frame, and the gate is a worst calibrated badge-bench frame of 12 ms or less.
- 160x128 RGB565. The framebuffer is column-major, `cart.framebuffer[x][y]`.
- `.copy_forward` with dirty rects. Only new trail cells, cycle heads and effects are drawn each frame. Every write marks its rect, and `badge-bench --lcd` is part of the gate.
- RAM cart only (XIP was removed from the show firmware). The whole cart should fit in about 120 KB.
- No audio and neopixels off (repo policy).
- The OS owns Start+Select and the joystick click. The cart reacts to neither Start nor Select while both are held.

## 3. The arena

- Logic grid 80 x 60 cells, each cell drawn as 2x2 pixels. The arena is y 8..127; y 0..7 is the HUD strip.
- The rim is the outer ring of cells: x = 0, x = 79, y = 0, y = 59. A rim cell is a wall that never gives a grind boost.
- Cell value, one byte:
  - 0 = empty.
  - 1..4 = trail of cycle n.
  - 0x40 = rim.
  - 0x41 = block (arena layouts, sudden death).
  - Bit 7 is reserved for effects that the renderer reads, never the rules.
- Floor: near-black, with dark blue grid lines every 8 px (4 cells), like the films.
- **The picture is a function of the grid.** `paint_cell(x, y)` draws a cell from its value plus the floor pattern. Anything transient (cycle sprites, sparks, particles, banners over the arena) is erased by repainting the cells it covered. There is no saved-pixel overlay.

## 4. Cycles and movement

All rules are integer and deterministic. The simulation runs at 60 ticks per second, one tick per `update()`.

- **Cycle state:**
  - Cell (x, y), direction (U/R/D/L), progress `p` in 1/256 cell, speed in 1/256 cell per tick.
  - Rubber, energy, the turn queue (2 entries), alive/dying, and a trail log (cells in order).
- **Movement:** each tick, `p += speed`. When `p >= 256`, the cycle steps to the next cell. Before the step it applies the head of the turn queue if that turn is legal. Then `p -= 256`.
  - Base speed 68/256 cells per tick, which is 16 cells/s, so crossing the arena takes about 5 s.
  - Speed is capped at 2.2x base. That is well under one cell per tick, so a cycle never skips a cell.
- **Controls are absolute** (top-down, as in TRON '82): pressing a d-pad direction queues that heading.
  - Pressing the current heading does nothing.
  - **Pressing the opposite heading is a U-turn.** It turns toward the side with more free cells in a 3-cell lookahead (ties go right), then reverses on the next cell. It never crashes you outright.
  - Minimum gap between two applied turns: one cell. The queue holds 2 turns, so a fast double tap still lands.
- **Turn tax:** each turn multiplies speed by 0.95 (Armagetron's TURN_SPEED_FACTOR), only while above base. A straight line pays off.
- **Grinding (Armagetron's wall acceleration):** on entering a cell, look at the two lateral neighbours at distance 1 and 2.
  - A trail cell (any cycle, your own too, never rim or block) at distance 1 adds `grind1` acceleration; at distance 2 it adds `grind2`.
  - Defaults: `grind1` = 3/256, `grind2` = 1/256 per tick while it lasts.
  - Speed decays back to base slowly from above (1/512 of the excess per tick, so a boost lingers for seconds) and quickly from below.
  - While grinding at distance 1, sparks fly between the cycle and the wall. That is both the reward cue and the danger cue.
- **Energy bar (GLtron booster plus Armagetron brake, one bar of 0..1000):**
  - Hold A to boost: target 1.5x base, drains 10 per tick.
  - Hold B to brake: target 0.5x base, drains 6 per tick.
  - It recharges 2 per tick while neither is held.
- **Rubber (forgiveness):** if the next cell is a wall when `p` crosses 256, the cycle stalls at `p` = 255 and drains 1 rubber per tick. A turn pressed during the stall is applied at once if that cell is free.
  - Rubber 0 means a crash. The meter holds 12 ticks (0.2 s) and recharges 1 per 8 ticks.
  - While stalled, the head flickers and sparks.
- **Collisions (resolved after all cycles move, in a fixed order):**
  - Entering a wall: crash.
  - Two cycles entering the same empty cell on the same tick: both crash. The banner reads **RACE CONDITION**.
  - Two heads swapping cells (head-on, adjacent, facing): both crash, **DEADLOCK**.
- **Crash names (banner, 30 ticks):** your own trail = SEGFAULT; another trail = DEREZZED; rim = OUT OF BOUNDS; block = ACCESS VIOLATION.
- **Derez:** the cycle explodes in a particle burst (16 particles, 40 ticks). After `wall_stay` ticks (default 45) its trail fades from tail to head, `fade_rate` cells per tick (default 6). Faded cells become empty, so space opens mid-round, as in TRON '82, CodinGame and Armagetron.
- **Kill credit:** a cycle that dies against someone else's trail credits that trail's owner. A head-on credits no one.
- **Sudden death (Sumo-style shrinking):** 30 s into a round the rim starts closing.
  - Every 60 ticks the next ring in becomes block cells, painted warning red. Cells already holding trail stay trail.
  - A cycle inside the new ring derezzes (ACCESS VIOLATION).
  - A SUDDEN DEATH banner shows when it starts. Rounds always end.
- **Starting positions:** symmetric, chosen per player count. Cycles start facing toward the centre with a 3 s countdown (3, 2, 1, RUN). Inputs during the countdown set your first heading.

## 5. AI ("programs")

Each AI decides when its cycle reaches a cell boundary (every 4 ticks at base speed). It decides one tick ahead, so the decision can be split over ticks. The tiers follow the research:

| Tier | Name | Method | Cost per decision (estimate) |
|---|---|---|---|
| T0 | WANDER | Lookahead of 1 to 3 cells; a random turn 3% of the time; dodges a blocked cell ahead with probability 0.85, so it sometimes crashes on its own | ~0 |
| T1 | AVOID | For each of the 3 legal moves, a flood fill capped at 300 cells; most space wins; ties go to straight, then to more open neighbours | ~0.2 ms |
| T2 | TERRITORY | For each move, a multi-source BFS Voronoi from all heads (other cycles assumed to go straight); score = 0.055 x cells + 0.194 x edges (a1k0n's fit), minus a 3x3 cut-cell table penalty, plus aggression for claiming the cells 2-4 ahead of the player's head first; once separated (flood fill sees no rival), switch to the wall-hugging fill | ~1-3 ms |
| T3 | SEARCH | Iterative-deepening alpha-beta against the nearest rival (paranoid; other cycles assumed straight), Voronoi leaves in a 32x32 window around both heads, a parity-bounded endgame fill; out of budget = keep the last full ply's best move | <= 6 ms, split over the frames between decisions |

- **Human-feel knobs, per AI:** reaction delay (in cells), mistake rate, and a vision radius. These tune difficulty inside a tier.
- AIs never read the player's input, only the grid and the cycles, so a link game gets the same AI on both badges.
- **AI randomness:** a per-AI xorshift stream advanced only by that AI's decisions. This keeps rewind replays exact.
- Per-frame AI work is capped by a cycle budget (`ai_budget_us`, default 4000 µs). Exceeding it defers the rest to the next tick, never past the decision tick. In that case the tier falls back to the T1 answer.

## 6. Modes

- **Title and attract:** four T2 programs play a demo round behind the logo. Any button opens the menu.
- **GRID LADDER (1 player, the booth mode).** Twelve levels, named after programming languages as TRON '82 did, ending on Zig, the conference's language, and then production:

  | # | Level | Programs | # | Level | Programs |
  |---|---|---|---|---|---|
  | 1 | BASIC | 1x T0 | 7 | C++ | 2x T2 |
  | 2 | COBOL | 2x T0 | 8 | JAVA | T2 + 2x T1 |
  | 3 | PASCAL | 1x T1 | 9 | RUST | 2x T2, 1.1x speed |
  | 4 | FORTRAN | 2x T1 | 10 | ASM | 1x T3 |
  | 5 | LISP | 3x T1 | 11 | ZIG | T3 + T2 |
  | 6 | C | 1x T2 | 12 | PROD | T3 + 2x T2 |

  - You clear a level by being the last cycle alive. A program that crashes on its own still counts.
  - After PROD the ladder loops at +10% speed per loop.
  - From level 5 on, some levels have **block layouts** (pillars and bars) for variety.
  - **Snapshots (Antithesis time travel):** 3 per game, shown in the HUD. When you derez, time freezes for 20 ticks, then the round rewinds 2 s at 3x speed with the trails visibly retracting into the cycles, and play resumes after a short countdown.
  - With no snapshot left, a derez ends the game (CORE DUMPED, score card).
  - A level clear adds a snapshot, up to a maximum of 3.
- **SKIRMISH:** pick 1 to 3 programs, their tier and the arena. First to 3 round wins (Blockade/Surround match targets). No snapshots. Achtung scoring: +1 for each cycle you outlive.
- **LINK DUEL (M3):** two badges over the link cable (`lib/link.zig`), lockstep, 0 to 2 AI programs added, first to 3. No rewind.
- **OPTIONS (modifiers, all off by default):**
  - SPEED (SLOW, NORMAL, FAST).
  - TRAILS: FULL, or SNAKE (finite walls, 200 cells, Armagetron's WALLS_LENGTH).
  - GAPS: Achtung-style. A cycle leaves no wall for 3 cells every 40 to 80 cells. Gap cells are seeded per cycle.
  - WRAP: the rim opens and cycles wrap around, as in Surround.
  - HARDCORE: rubber 4, no snapshots.
- **Score (ladder):** 500 per kill credited to you, 250 per program that crashed on its own, plus a level clear bonus of 1000 x level number. At game over each snapshot left is worth 2000. The session high score is kept in RAM only (no flash saves).

## 7. Controls

| Input | Play | Menus |
|---|---|---|
| D-pad | heading (absolute); opposite = U-turn | move |
| A (hold) | boost | select |
| B (hold) | brake | back |
| Start | pause (RESUME / RESTART LEVEL / QUIT) | select |
| Select | nothing in play (left free) | back |

No input is displaced: this is a new cart.

## 8. Presentation

- **Colours (Tron Legacy-ish):**
  - Player: cyan. Programs: orange, magenta, yellow-green. Each trail is the cycle's colour.
  - Rim: bright blue.
  - Blocks: dim blue; sudden-death ring: red.
  - A white-hot core on the head cell.
- **Cycle sprite:** a 4x4 marker centred on the head cell (the cell plus a 1 px halo in the cycle's colour), with a nose pixel showing the heading. It is redrawn every tick and its old area repainted from the grid.
- **Trails:** 2x2 cells. The newest 3 cells of each trail are drawn brighter, then settle to the trail colour, which gives a glowing head streak for 3 cells of extra paint per tick.
- **Effects:**
  - Grind sparks: 1-3 pixels between the head and the wall, life 4-8 ticks.
  - Derez burst.
  - The tail-to-head fade.
  - The rewind: trails retract, with a scanline tint and a REWIND banner.
- **HUD (y 0..7), 8x8 font:** level name, score, energy bar (A/B), snapshot pips.
- **Title:** "SNOUTY CYCLES" in neon, the Iris mark (`lib/iris_mark.zig`), and "LIGHT CYCLES / CPU CYCLES" under it. The attract round plays behind.
- **Round banners:** level name and programs ("LEVEL 6: C - 1 PROGRAM"), RUN, the crash names, LEVEL CLEAR, CORE DUMPED.

## 9. Rewind (snapshots)

- **Exact:**
  - Keep a keyframe of the full sim state (grid, cycles, AI rngs, round clock) every 30 ticks, in a ring covering at least 4 s.
  - Keep the player's input byte per tick.
  - A rewind to tick T restores the keyframe at or before T and replays the inputs up to T. AIs are deterministic, so the replay is exact.
- **The visual retraction:**
  - For the 2 s being undone, take each trail log's cells with their tick stamps and pop them newest first at 3x speed.
  - Then restore the replayed state and repaint the arena.
  - Host test: rewind plus replay of the same inputs gives a state byte-identical to the original.
- **Memory:** about 8 keyframes x (4.8 KB grid + cycles) ≈ 40 KB. If that is tight, keyframe the trail log lengths instead of the grid (a trail log pop restores the grid), which costs under 1 KB per keyframe.

## 10. Link duel (M3)

- **Deterministic lockstep:** both badges run the same sim. Each packet carries a tick byte, the input bytes for t, t-1 and t-2 (heading press 3 bits, A, B), and a world CRC byte. That is 5 bytes, inside the link's safe 8 wire bytes.
- Input delay is 3 ticks. A stall shows WAITING.
- A CRC mismatch ends the round as NO CONTEST and resyncs from a fresh seed.
- The partner leaving: an AI takes their cycle for the rest of the round, then the menu.
- The seed and options are exchanged at the start of the match. The lower nonce is host and picks.
- **Gate:** two sims on `lib/link_virtual.zig` play 50 rounds with random inputs and no desync.
- The hardware check depends on the link cable working on two badges (docs/LINK.md; the handshake was still being debugged on 2026-10-04).

## 11. Code layout (`carts/snouty-cycles/`)

- `cart/src/main.zig`: `start`/`update`, wasm shims (`present_wasm`, `read_controls`), debug exports.
- `cart/src/sim.zig`: grid, cycles, movement, rules, round clock, sudden death. Pure, with no cart API, so it is host-testable.
- `cart/src/ai.zig`: tiers T0-T3 and the budget.
- `cart/src/history.zig`: keyframes, input log, rewind.
- `cart/src/game.zig`: modes, ladder, scoring, the state machine (title, menu, countdown, play, rewind, results).
- `cart/src/render.zig`: paint_cell, sprites, particles, HUD, banners, dirty rects. Generic over a sink, as Pipes does, so host tests can check every put is inside a marked rect.
- `cart/src/levels.zig`: the ladder table and block layouts (data).
- `cart/src/rng.zig`: rng streams.
- `cart/src/host_tests.zig`: the root for host tests.
- `tools/check.sh`: the gate (build, test, check-float, bench worst <= 12 ms, `--lcd`, goldens, bot checks).
- `tools/scripts/`: input scripts.
- `badge-bench/carts/snouty-cycles.toml`.

## 12. Performance targets

- **Typical frame:** 4 cycles move, about 10 cells painted plus sprite repaints, under 1 ms.
- **AI:** the T2/T3 decision cost is spread so that no frame exceeds `ai_budget_us`.
- **Full repaint** (rewind end, level start, layout change): 19,200 px of floor plus cells, at most 3 ms. Do it once, not every frame.
- **Worst frame:** 12 ms or less in calibrated badge-bench, across attract, a level 12 round with sudden death, and a rewind.

## 13. Milestones

- **M0, a playable slice.** Cart scaffold wired into the root build plus the badge-bench toml.
  - `sim.zig`: movement, turns, U-turn, collisions, derez with fade.
  - T1 AI.
  - Render: floor, cells, heads, HUD stub, dirty rects.
  - One round loop (countdown, play, result, next round).
  - Host tests, the bench, `tools/check.sh`, a preview GIF.
- **M1, the game.**
  - Grinding, rubber, the energy bar.
  - AI tiers T0-T3 with the budget.
  - Ladder, scoring, title and attract, menus, banners, effects, sudden death, block layouts.
  - A bot that plays the ladder headless, which is the content gate: every level is clearable.
- **M2, time travel and options.**
  - Snapshots and rewind (section 9, exact, with the retraction).
  - SKIRMISH, the OPTIONS modifiers, HARDCORE, the game-over card with high score.
- **M3, link duel.** Section 10 against the virtual cable; hardware check open.
- **Parked, not planned:**
  - A tilted 3D "grid cam" replay of the last derez (looks great, reviewers warn against playing in it).
  - Team modes.

## 14. Defaults taken without Adrian (override any)

1. Name **Snouty Cycles**, directory `carts/snouty-cycles`.
2. Top-down whole-arena view only; no 3D.
3. 80x60 logic grid, 2x2 px cells, 16 cells/s base speed.
4. Absolute d-pad controls; the opposite direction is a safe U-turn.
5. The rim gives no grind boost (Armagetron's RIM 0), so rim-hugging is not a free win.
6. Snapshots: 3 per game, auto-rewind 2 s on a derez, +1 per level cleared (max 3).
7. Ladder: the 12 language levels of section 6, ending on ZIG and PROD.
8. Kill credit to the trail owner; a head-on is RACE CONDITION and credits no one.
9. Sudden death at 30 s.
10. No audio, neopixels off, session-only high score.
11. LINK DUEL is built against the virtual cable and waits on the link's hardware check.
