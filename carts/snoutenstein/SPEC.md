# Snoutenstein 3D: game spec

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565, 60 Hz.
Third cart for the badge, alongside `snouty-badge` (running Snouty) and
`snouty-bugs` (bullet hell). Working title only; see section 17.
Status and milestones are at the bottom.

## 1. One paragraph

A Wolfenstein 3D style first-person shooter. Snouty walks through a maze of
textured walls (a server room, drawn 16-bit style), swatting and zapping
software bugs drawn as insects. Doors slide open when walked into; some
need a colored key. Three weapons with their own ammo, a Doom-style status
bar with Snouty's portrait reacting to damage, three short levels of our
own plus an importer for Wolfenstein 3D map files, so any Wolf3D level or
fan mapset can be dropped in. The
twist, and the Antithesis joke: holding B rewinds time. The world runs
backwards, kills un-happen, damage un-happens, and when B is released play
continues from that moment. There are no lives: dying freezes time and asks
you to rewind. Under the hood the rewind is deterministic replay from
keyframes plus a recorded input log, which is literally the Antithesis
pitch, so the badge can say so on the title screen.

## 2. Hardware facts the design leans on

- RP2354B, Cortex-M33 at 150 MHz with a single-precision FPU and hardware
  integer divide. Core 1 runs only the cart; `present()` waits for the
  previous LCD flush, so the cart gets essentially the full 16.7 ms.
- Screen 160x128. The framebuffer is column-major (`framebuffer[x][y]`), so
  a raycaster's vertical wall slices are contiguous 16-bit stores. This is
  the single biggest reason the design is feasible at 60 Hz.
- On hardware `Pixel` is a plain bitcast of `DisplayColor` (no byte swap);
  on wasm it is swapped. All palettes are converted to `Pixel` at comptime
  or in `start()`, so inner loops do a table lookup and a store, nothing else.
- Cart RAM is 307 KB (`0x20035100..0x20080000`), binary at most 256 KB.
  Budget for this cart: ELF `.text`+`.data` at most 140 KB, `.bss` at most
  120 KB, measured with `size -A` every milestone. Section 13 has the table.
- Inputs: joystick 4-way, A, B, Start, Select. Start+Select (250 ms) and
  joystick click are OS-owned; never bound.
- Audio: `tone2`, one voice. Neopixels: 5, off: the cart never writes a
  non-zero value; the LED effects are compiled out unless built with `-Dneopixels=true` (section 12).
- Rendering: `.no_copy_full_frame`, full redraw every frame, as in both
  existing carts. Upstream `blit` is not used at all; every pixel comes
  from our own loops.

## 3. Controls

| Input          | Title / intermission | Playing                                     | Dead (time frozen)        |
|----------------|----------------------|---------------------------------------------|---------------------------|
| Up / Down      | (nothing)            | Walk forward / back                         | (nothing)                 |
| Left / Right   | (nothing)            | Turn                                        | (nothing)                 |
| A              | Start game           | Fire / swat                                 | (nothing)                 |
| B              | Start game           | Hold: rewind time                           | Hold: rewind (mandatory)  |
| Select         | Toggle sound         | Next weapon (skips empty ones)              | (nothing)                 |
| Start          | Start game           | Pause / unpause                             | (nothing)                 |

Tank controls, no strafe (open question, section 17). Turn 2.5 degrees per
tick (150 deg/s). Walk 0.045 cells per tick (2.7 cells/s), back at 0.03.
Player is a circle of radius 0.25 cells; collision is axis-separated so you
slide along walls. Doors open when you walk into them; no "use" button.

## 4. Screen layout

```
y   0..103   3D view, 160x104. Horizon at y=52.
y 104..127   Status bar, 24 px, Anti-Black background.
```

Status bar, left to right:

```
x   0.. 31   HP: "100%" in the 8x8 font over a 30x4 bar
x  32.. 63   Ammo of the current weapon: icon 8x8 + number
x  64.. 95   Snouty portrait 24x24 (Doom face), centered, 2 px frame
x  96..119   Keys: three 8x8 slots (Coral, Iris, Gold), dim when missing
x 120..159   Rewind meter: 36x6 bar in Iris purple + a small clock glyph
```

The first-person weapon sprite (48x32) sits at the bottom center of the
view, bobbing +-2 px with walking. During rewind the whole view is tinted
(section 9) and the status bar shows `<<` and the level clock running back.

## 5. Rendering

Classic grid raycaster (Lode Vandevenne's algorithm), one ray per screen
column, 160 columns, FOV 66 degrees.

- Angles are `u16` (65,536 per turn). `sin`/`cos` come from a comptime
  1,024-entry table. Per-column camera-space ray offsets are a comptime
  table too; each frame rotates them with two multiply-adds per column.
- Rendering may use `f32` (the M33 has an FPU). The simulation may not
  (section 9.3).
- Walls: DDA through the `u8` cell grid until a solid cell or the range
  cap of 24 cells (beyond it the column is filled with the darkest shade:
  fog, which is also why 64x64 maps do not raise the ray cost). Perpendicular
  distance -> slice height `h = 104 / dist`. Texture x from the hit
  fraction; texture y stepped in 16.16 fixed point. Inner loop:
  `column[y] = shade[idx_tex[tx][ty >> 16]]`, where wall textures are
  unpacked at `start()` into column-major `u8` arrays so the loop is
  stride-1 on both sides.
- Textures 32x32. That matches Wolf3D's ratio of texture height to view
  height (64/200 vs 32/104), so it reads as the same fidelity at this
  size and keeps the art small.
- Shading: each texture has 4 `Pixel` palettes (16 entries each): lit,
  dark (used for the two wall orientations, like Wolf3D), and two dimmer
  levels chosen by distance bands (> 6 and > 10 cells). Free at runtime,
  hides tiling, and the rewind tint is just a fifth palette set.
- Floor and ceiling: flat fills per column from a 52-entry per-row color
  table (darker toward the horizon). Each of the 16,640 view pixels is
  written exactly once per frame.
- Doors: Wolf3D-style thin doors on the cell's midline, offset by their
  open fraction. The DDA treats door cells specially: it tests the
  midline and skips through if the ray passes the open part.
- Sprites (enemies, pickups, projectiles): billboards sorted back to front,
  scaled by `1/dist`, clipped per column against a 160-entry depth buffer
  from the wall pass. Enemy sheets are 32x32 (same ratio argument as
  walls); the boss is drawn at 1.5x in code. Sprites stay 4-bit packed
  in the ELF and are read a nibble at a time; a frame draws a few
  thousand sprite pixels at most, so this is cheap.
- No enemy rotation frames: every enemy always faces the player. Bugs are
  symmetric enough that nobody will notice.

Cost estimate at 150 MHz: rays 160 x ~16 DDA steps x ~30 cycles = 0.5 ms;
wall and floor writes 16,640 x ~8 cycles = 0.9 ms; sprites and HUD under
1 ms; simulation under 0.2 ms. Roughly 3 ms of a 16.7 ms frame. If
hardware disagrees (M1 measures it), the fallbacks in order are: cast 80
rays and draw 2 px wide slices (exactly what Wolf3D did at its lower
detail settings), then drop the distance shading, then render at 30 fps.

## 6. World and levels

- Grid 64x64 cells (the Wolf3D size; smaller maps are padded), one `u8`
  per cell: 0 floor, 1..8 wall texture, 64..127 door number into the
  level's door table (kind and orientation live there), the rest
  reserved. 4 KB per level. PLAN.md M0 has the exact encoding. There is no
  aesthetic reason to stay at 32: the range cap in section 5 fogs far
  walls, so a long corridor looks better, not worse. The 64 limit is a
  maximum; our own levels stay compact.
- Levels are ASCII files in `cart/src/levels/*.txt` (under the module root so
  `@embedFile` can see them), parsed at comptime into cell
  arrays and spawn lists (`@embedFile` + `@setEvalBranchQuota`). Legend:

```
#  wall, texture from the level's default     1-8  wall with that texture
.  floor                                       S    player start, facing the arrow after it (^v<>)
D  door                                        C I G   door locked with Coral / Iris / Gold key
E  exit door (walk in to finish the level)     c i g   key pickups
X  secret door (looks like the wall beside it; walk into it; stays open)
a  gnat   w wasp   b beetle   s spider   H Heisenbug (boss)
+  hotfix (health +25)   %  ammo for the zapper   $ ammo for the spray   *  rewind battery (+3 s)
```

- Levels come from two sources, both ending up as the ASCII format above:
  hand-written files, and `tools/import_wolf.py` (section 6.1) for
  Wolfenstein 3D maps.
- Three levels of our own, 2 to 4 minutes each: **Build Farm** (learn walking,
  doors, one key, gnats), **Staging** (two keys, wasps and spiders,
  first rewind-battery hunt), **Production** (three keys, all enemies,
  the Heisenbug behind the Gold door). Level end: an intermission card
  with time, kills, rewinds used, then the next level. After Production:
  a victory card, then the title.
- Doors slide open over 30 ticks when walked into, stay open 180 ticks,
  close unless something stands in them. Locked doors need the matching
  key; bumping one without it flashes the key slot in the HUD and plays a
  buzz.
- Secret doors (`X`, Adrian 2026-09-29) are Wolf3D pushwalls: closed, the
  cell renders as a flush wall with the texture of the wall beside it (no
  recess, no seam); walking into it slides it open like a door, it never
  closes again, and enemies cannot open it. Build Farm hides its single
  spray can behind one (under the Iris mural); Staging and Production get
  one each for the Debugger (section 7, M6).

### 6.1 Wolfenstein 3D map import

`tools/import_wolf.py MAPHEAD.WL1 GAMEMAPS.WL1 --level 0 --difficulty medium
--out levels/wolf_e1m1.txt` reads the original format: `MAPHEAD` holds the
RLEW tag and 100 level offsets, `GAMEMAPS` holds per-level headers (three
plane offsets and sizes, 64x64, 16-byte name) and planes that are
Carmack-compressed then RLEW-compressed. Plane 0 is walls and doors,
plane 1 is objects and actors, plane 2 is unused. The code tables are
those of `WL_GAME.C` (`ScanInfoPlane`) in the released source; the same
files are produced by every Wolf3D editor (WDC, ChaosEdit, HWE), so this is
also the "real editor" path for our own levels.

Mapping, in the direction Wolf3D -> ours:

| Wolf3D                                             | Ours                                                    |
|----------------------------------------------------|---------------------------------------------------------|
| Wall codes 1..63 (each is a light/dark texture pair)| Textures 1..8 via a mapping file (`levels/wolf_walls.json`), default groups by Wolf3D texture family; unmapped codes fall back to texture 1 |
| Doors 90/91 (plain), 92/93 (gold lock), 94/95 (silver lock) | `D`, `G` (Gold), `I` (Iris); Coral is only used by our own levels |
| Elevator doors 100/101, elevator switch wall       | `E` exit door                                           |
| Player start 19..22 (N/E/S/W)                      | `S^` `S>` `Sv` `S<`                                     |
| Gold key 43, silver key 44                         | `g`, `i`                                                |
| Food 47, medkit 48                                 | `+` (hotfix)                                            |
| Ammo clip 49, machine gun 50, chaingun 51          | `%` zapper charge, `$` spray can, `$`                   |
| Treasure 52..55, extra life 56                     | `*` rewind battery for the extra life; treasure dropped (no score) |
| Guard, dog, SS, officer, mutant (per difficulty)   | gnat, wasp, beetle, spider (officers, so a turret sits where a patrol was), beetle |
| Hans Grosse and the other bosses                   | Heisenbug                                               |
| Pushwalls (object 98), ambush tiles, floor codes   | Ignored: the wall stays solid; areas are not used (we wake enemies by sight and gunfire) |

The importer applies one difficulty tier so enemy counts stay sane and
warns when a level exceeds the pools in section 8 (it then drops the
lowest-value enemies farthest from the start). The original `.WL1`/`.WL6`
files are never committed; converted levels are (section 18, item 9).

## 7. Weapons

| # | Name       | Type                              | Damage        | Rate       | Ammo            | Sprite frames |
|---|------------|-----------------------------------|---------------|------------|-----------------|---------------|
| 1 | Swatter    | Melee, reach 1.2 cells, 30 deg cone | 4             | every 24 t | none            | idle, swing x2 |
| 2 | Zapper     | Hitscan, ray to first enemy       | 3             | every 12 t | charge, start 40, max 99 | idle, fire x2 |
| 3 | Bug Spray  | 5 hitscan pellets in a 20 deg cone, reach 6 cells | 2 per pellet | every 36 t | cans, start 0, max 30 | idle, fire x2 |

Select cycles 1 -> 2 -> 3 -> 1, skipping weapons with no ammo. Picking up
the spray in Staging switches to it and triggers the portrait's grin. A
fourth weapon, "the Debugger", is planned for M6 (PLAN.md): a slow splash
projectile found behind the secret doors of Staging and Production.

## 8. Enemies (the bugs)

Sprites 32x32, seven frames each: walk x2, attack, pain, death x3. Every
enemy always faces the camera. HP, speeds in cells per tick.

| Name (flavor)          | HP | Speed | Behaviour                                                                                          | Attack                                            |
|------------------------|----|-------|----------------------------------------------------------------------------------------------------|---------------------------------------------------|
| Off-by-one (gnat)      | 3  | 0.05  | Wakes on sight or gunfire within 8 cells; zig-zags toward the player                               | Melee bite 4, every 40 t within 0.8 cells (tuned M5.1) |
| Race Condition (wasp)  | 6  | 0.07  | Waits; when it sees you it charges in a straight line, overshoots, turns, charges again            | Melee 10 on contact during a charge               |
| Memory Leak (beetle)   | 20 | 0.02  | Slow, walks straight at you, soaks damage                                                          | Spits a 0.08 cells/t projectile, 10 damage, every 90 t |
| Deadlock (spider)      | 8  | 0     | Stationary turret on the ceiling; only visible from within 6 cells                                 | Web projectile 0.06 cells/t: 6 damage and freezes your movement for 45 t (turning still works). Rewind is the counter. |
| Heisenbug (boss)       | 80 | 0.04  | If you look at it for 90 ticks straight it flickers and teleports to a spawn point behind you; never flinches (no pain state) | Spit x3 fan, 10 damage each, only beyond 2.5 cells; melee 15, every 45 t |

AI is Wolf3D-simple and deterministic: a state machine (idle, alert,
chase, attack, pain, dead) with line of sight by grid ray, movement toward
the player with wall sliding and an eight-direction fallback when blocked.
No pathfinding. Pools sized for imported Wolf3D levels: 40 enemies, 12
projectiles, 64 doors, 256 pickups. Dormant (never woken) enemies cost
one line-of-sight check every 8 ticks and nothing else.

Damage to the player: HP 100, no armor. Damage flashes the view red for 4
ticks (palette set swap, free) and sets the portrait's "ouch" frame for
30 ticks. Enemies flash white for 2 ticks on hit.

## 9. Time rewind

### 9.1 Rules

- Hold B: time runs backwards at 1x while the rewind meter drains one
  second per second. Release B: play resumes from that moment and the
  discarded future is gone. Everything is consistent: enemies killed in
  the rewound span are alive again, ammo spent is back, doors and pickups
  revert. This is the whole game state, so it needs no special cases.
- Meter capacity 10 s. Refills 1 s per 6 s of forward play. Full at level
  start. Rewind batteries add 3 s.
- Dying (HP 0) freezes time: red view, "HOLD B TO REWIND", and the meter
  is topped up to at least 3 s (an emergency reserve, granted once per
  death). While frozen only B works. Releasing B at a moment where HP > 0
  resumes play. If the meter empties while still dead, the level restarts
  (the only "game over" in the game). No lives. (M4 note: with the
  reserve, one tick back always reaches HP > 0, so the restart only
  triggers when there is no history at all; it is kept as a safety net,
  holding B for one second while dead with nothing to rewind into.)
- Tension: rewinding to dodge a hit also un-does the kills you made since,
  so the meter is a resource, not a free undo. Combined with the spider's
  freeze web and the wasp's charge, that is the game.

### 9.2 Implementation: keyframes plus deterministic replay

The simulation is a pure function `step(state, controls) -> state` on a
plain-data `GameState` (no pointers, about 1.4 KB: player, 40 enemies, 12
projectiles, 64 doors, 256-bit pickup mask, PRNG, tick, stats).

- Every 30 ticks the live state is copied into a ring of 21 keyframes
  (10.5 s). Every tick the `Controls` word goes into a ring of 640.
- Entering rewind at tick T: take the keyframe at or before T, replay the
  logged inputs forward once into a 30-slot span cache (30 KB, at most 30
  `step` calls, a fraction of a millisecond), then play the cache
  backwards one tick per frame. Crossing a keyframe boundary refills the
  cache from the previous keyframe.
- Releasing at tick R: the cached state at R becomes live, keyframes and
  inputs after R are dropped, play continues.
- Memory: 30 KB keyframes + 42 KB span cache + 1.3 KB inputs. Section 13.
- This is the same machinery as the attract-mode demo (section 11): a
  demo is a keyframe (the level start) plus an input log.

### 9.3 Determinism rules (enforced, not hoped for)

- Simulation math is 16.16 fixed-point `i32` only. No `f32` in `step`,
  so a run recorded in the wasm simulator replays bit-identically on the
  Cortex-M33 (needed for shipped demos, and it removes a whole class of
  desync bugs). Rendering is free to use `f32`.
- No `cart.rand()`, no `micros_since_boot()` inside `step`. The PRNG
  (xorshift32) lives in `GameState`.
- Render-only state (weapon bob phase, screen flash timers, portrait idle
  glances) lives outside `GameState` and is not rewound.
- Self-check, wasm builds and debug hardware builds: at every keyframe,
  re-simulate from the previous keyframe with the logged inputs and
  compare with the live state; a mismatch increments `debug_desync`. The
  harness asserts `debug_desync == 0` on every scripted run. This is an
  Antithesis-style determinism check and stays in the repo forever.

### 9.4 Presentation

- View tinted Iris purple via the rewind palette set, every fourth row
  darkened (scanlines), a `<<` glyph at the top left, the status bar clock
  counting down. Enemies, doors and projectiles simply play backwards.
- Audio: a descending square sweep retriggered every 10 ticks. Neopixels:
  off (section 12); the dormant effect behind `-Dneopixels` pulses all
  five purple.

## 10. HUD portrait and feedback

Portrait sheet 24x24, nine frames: healthy, hurt (HP < 60), critical
(HP < 25), ouch, grin (weapon or key pickup, 45 ticks), glance left,
glance right (idle every 3 to 5 s), rewind (eyes spiralling), dead. Health
tier picks the base frame; events override it for their duration, ouch
beating grin.

## 11. Game flow and attract mode

```
boot -> TITLE (logo, "PRESS A", "powered by deterministic replay" tag line, 10 s)
     -> DEMO: replay a recorded input log on Production; "DEMO" blinks in the HUD
         (Adrian, 2026-09-29: the most interesting level; dying in the demo is fine)
         -> any A/B/Start/joystick input -> PLAYING from that exact state (takeover)
         -> log ends or 3 min -> TITLE
TITLE -> A/B/Start -> PLAYING, level 1, fresh state
PLAYING -> exit door -> INTERMISSION (5 s or A) -> next level, or VICTORY -> TITLE
PLAYING -> HP 0 -> DEAD (frozen; hold B) -> PLAYING, or meter empty -> level restart
PLAYING -> Start -> PAUSED -> Start -> PLAYING
```

Takeover keeps the world as is and hands the controls over on the next
tick, with the meter refilled (recorded as a rewind patch so the keyframe
self-check keeps agreeing). Select does not take over. The demo is a
fixed seed plus a run-length input log: authored as a `preview.mjs`
script (`tools/scripts/demo_build_farm.json`), baked into `.text` by
`tools/gen_demo.py` as `cart/src/demos/build_farm.zig` together with the
`sim.hash_gameplay` the simulator recorded after the last tick
(`tools/record_demo.sh`). When the log runs out the cart compares its own
hash with the recorded one and the title shows "DEMO OK" or "DEMO
DESYNC": the attract mode doubles as the hardware determinism test of
section 9.3. The demo also ends on a 3 min cap, after 2 s dead without a
rewind in the log, or once the level ends (no result in those cases; a
log that ends with the player dead still gets its hash compared).

## 12. Audio and neopixels

One voice through `tone2`; later calls in a tick win, priority: death >
player hurt > pickup > enemy death > door > weapon.

| Event          | Shape    | Frequency     | Duration |
|----------------|----------|---------------|----------|
| Swatter        | noise    | 200 Hz        | 0.05 s   |
| Zapper         | square   | 1,200 Hz      | 0.05 s   |
| Bug spray      | noise    | 120 Hz        | 0.15 s   |
| Enemy hit      | triangle | 900 Hz        | 0.03 s   |
| Enemy death    | square   | 180 Hz        | 0.12 s   |
| Player hurt    | sawtooth | 140 Hz        | 0.20 s   |
| Door           | triangle | 300 -> 500 Hz | 0.25 s   |
| Locked door    | square   | 90 Hz         | 0.20 s   |
| Pickup         | major    | 660 Hz        | 0.20 s   |
| Rewind (loop)  | square   | 800 -> 200 Hz | 0.17 s, retriggered |
| Death freeze   | minor    | 55 Hz         | 0.80 s   |

Sound defaults off, toggled with Select on the title screen only (Select
is the weapon key in game).

Neopixels are off (docs/NEOPIXELS.md at the repository root): the cart
never writes a non-zero value. A coworker's badge shows the LEDs are
unusably bright even at 1% (2026-09-29). The effects below are compiled
out; `zig build -Dcart=snoutenstein -Dneopixels=true` re-enables them for
development. `audio.write_pixels` is the only writer of `cart.neopixels`.

### Dormant neopixel effects (behind -Dneopixels)

All gated by `audio.enabled` too (Select on the title), capped at 10/255
per channel:
- HP as a green-to-red bar over the five LEDs (one per started 20 HP;
  green from 60, amber from 25, red below); dead: LED 0 dim red.
- Key pickup: all five white for 6 ticks.
- Rewind: all five Iris purple, pulsing 3/255 to 8/255 on blue over a
  30-tick triangle.

## 13. Memory budget

| Item                                   | Where   | Size     |
|----------------------------------------|---------|----------|
| Code (est. 4k lines of Zig)            | .text   | ~45 KB   |
| Art (section 14)                       | .text   | ~39 KB   |
| Levels (3 x 64x64 + spawns), tables    | .text   | ~15 KB   |
| Demo input log                         | .text   | ~3 KB    |
| Wall + door textures unpacked, 13 x 1 KB | .bss  | 13 KB    |
| Shade palettes 13 tex x 5 sets x 32 B  | .bss    | 2 KB     |
| Depth buffer, sprite sort scratch      | .bss    | 1 KB     |
| Live GameState + render state          | .bss    | 3 KB     |
| Rewind: 21 keyframes + 30 span + inputs| .bss    | 74 KB    |
| Total                                  |         | ~195 KB  |

Well inside 307 KB even with stack. If `GameState` grows past 1.4 KB, the
keyframe ring shrinks first (15 keyframes = 7.5 s is still fine). Extra
imported levels cost 4 KB each of `.text`; about 15 fit before the ELF
budget matters.

## 14. Asset manifest

4-bit indexed (15 colors + transparent index 0) unless noted; horizontal
strips of equal cells, frame 0 left. Bytes are packed indices. Production
details for the art agent go in `ASSETS.md` (M0).

| Sheet             | Cell   | Frames | Sheet px | Bytes  | Contents                                                        |
|-------------------|--------|--------|----------|--------|-----------------------------------------------------------------|
| `walls.png`       | 32x32  | 8      | 256x32   | 4,096  | server rack, cable tray, brick, vent, Iris mural, monitor wall, pipes, exit sign strip; opaque, 16 colors |
| `doors.png`       | 32x32  | 5      | 160x32   | 2,560  | plain, Coral lock, Iris lock, Gold lock, exit elevator          |
| `bug_gnat.png`    | 32x32  | 7      | 224x32   | 3,584  | walk x2, attack, pain, death x3                                 |
| `bug_wasp.png`    | 32x32  | 7      | 224x32   | 3,584  |                                                                 |
| `bug_beetle.png`  | 32x32  | 7      | 224x32   | 3,584  |                                                                 |
| `bug_spider.png`  | 32x32  | 7      | 224x32   | 3,584  | hangs from the ceiling; top of cell is the thread              |
| `bug_boss.png`    | 32x32  | 8      | 256x32   | 4,096  | as above plus one flicker/teleport frame; drawn at 1.5x         |
| `pickups.png`     | 16x16  | 8      | 128x16   | 1,024  | key x3, hotfix, zapper charge, spray can, rewind battery, spare |
| `projectiles.png` | 8x8    | 4      | 32x8     | 128    | spit x2, web x2                                                 |
| `weapons.png`     | 48x32  | 9      | 432x32   | 6,912  | swatter idle/swing/swing, zapper idle/fire/fire, spray idle/fire/fire |
| `face.png`        | 24x24  | 9      | 216x24   | 2,592  | section 10                                                      |
| `hud.png`         | 8x8    | 8      | 64x8     | 256    | key icons x3 (lit; dimmed in code), ammo icons x2, clock, `<<`, heart |
| `title.png`       | 128x40 | 1      | 128x40   | 2,560  | logo lettering                                                  |
| `iris_16.png`     | 16x16  | 1      | 16x16    | 128    | from snouty-badge                                               |
| Total             |        |        |          | ~39 KB |                                                                 |

Placeholders at these exact sizes are committed in M0 so code never waits
on art, as with `snouty-bugs`.

## 15. Architecture

```
cart/src/
  main.zig        start/update, top-level state machine (TITLE/DEMO/PLAYING/DEAD/PAUSED/
                  INTERMISSION), wasm shims (present_wasm, read_controls), debug exports
  fixed.zig       16.16 fixed point: mul, div, sin/cos tables, atan2 lookup
  state.zig       GameState (plain data), Player, Enemy, Projectile, Door
  sim.zig         step(state, controls): movement, doors, weapons, enemy AI, projectiles,
                  damage, pickups, level exit. No f32, no cart calls.
  levels.zig      comptime ASCII level parser -> cells + spawn lists
  rewind.zig      keyframe ring, input ring, span cache, self-check
  render/
    raycast.zig   per-column DDA, walls, doors, depth buffer
    floor.zig     floor and ceiling fills
    sprites.zig   billboard sort and draw with depth clipping
    textures.zig  unpack at start(), shade palette sets (lit/dark/dim/dimmer/rewind/hurt)
    hud.zig       status bar, portrait, weapon sprite, overlays, title, intermission
  audio.zig       tone2 priority wrapper, neopixels
  input.zig       Controls source: hardware/sim, demo replay; edge detection
  packed_int_array.zig  (upstream copy)
cart/src/levels/  build_farm.txt, staging.txt, production.txt, wolf_walls.json,
                  imported Wolf3D levels (free mapsets or our own editor output only)
demos/            build_farm.bin (recorded inputs)
tools/            prepare_assets.py, import_wolf.py (section 6.1), check_determinism.mjs
                  (preview.mjs, serve-cart.mjs, make_gif.py: shared, in ../../tools/)
```

Per tick: read controls -> top-level state machine -> (PLAYING) log input,
`step`, keyframe if tick % 30 == 0 -> (REWIND) pop from span cache ->
render: floor/ceiling + walls in one column pass, sprites, weapon, HUD,
overlays -> audio/LEDs -> present.

Debug exports (wasm only): `debug_state`, `debug_hp`, `debug_level`,
`debug_tick`, `debug_desync`, `debug_state_hash` (FNV over `GameState`),
`debug_render_us` (also shown in the HUD in debug builds on hardware, so
M1's timing check is one photo of the badge).

## 16. Verification

- `zig build` (at the repository root) gives `zig-out/firmware/snoutenstein.uf2` and
  `zig-out/bin/snoutenstein.wasm`; `size -A` against section 13.
- Headless: `preview.mjs --script tools/scripts/*.json --dump-exports ...
  --expect "debug_desync == 0"` for walk-through, door/key, combat,
  rewind-past-death and takeover scripts. Every milestone ships a GIF.
- `check_determinism.mjs`: runs a script twice with a rewind inserted in
  the second run and asserts equal `debug_state_hash` at the end;
  `check.sh` replays the embedded demo (`--call debug_start_demo`) and
  asserts `debug_demo_result == 1` (the recorded final hash matched).
- Hardware, M1 gate: FPS overlay reads 60 and `debug_render_us` stays under
  8,000 while facing the longest corridor in the test level with 6 sprites
  in view. Anything worse triggers the section 5 fallbacks before M2.
- Adrian reviews each milestone in the local simulator (`docs/RUNNING.md`,
  copied from snouty-bugs).

## 17. Milestones

Each milestone: a tag, a GIF in `docs/`, a "pull and run" note. Parallel
tracks go to Opus subagents with disjoint files, as before.

- **M0 Scaffold**: repo, toolchain copied from `snouty-bugs`, stub title,
  placeholder sheets at manifest sizes, `ASSETS.md` brief, this spec.
- **M1 Raycaster on hardware** (the risk milestone): fixed-point movement
  and collision, textured walls with orientation and distance shading,
  floor/ceiling fills, one test level, `debug_render_us` in the HUD.
  Tracks: A render (`render/raycast.zig`, `floor.zig`, `textures.zig`),
  B sim (`fixed.zig`, `state.zig`, `sim.zig` movement only, `levels.zig`),
  C tools (`preview.mjs` extensions, `docs/RUNNING.md`). Gate: Adrian
  flashes it and reports FPS and the microsecond readout.
- **M2 World**: doors and keys, pickups, sprites with depth clipping,
  status bar with portrait, swatter and zapper, level exit and intermission.
  Parallel tools track: `import_wolf.py` with a unit test on a hand-built
  Carmack/RLEW fixture, verified by walking an imported shareware level in
  the simulator (locally, not committed).
- **M3 Bugs**: all five enemies, AI, projectiles, damage, death freeze,
  bug spray, the three levels roughed out.
- **M4 Rewind**: keyframes, input log, span cache, B-hold rewind, death
  rule, tint and audio, determinism self-check and `check_determinism.mjs`.
- **M5 Attract and polish**: title, recorded demo, takeover, audio and
  LEDs, final art drop-in, Heisenbug tuning, hardware balance pass,
  optional fourth weapon.

## 18. Decisions and open questions

Decided by Adrian on 2026-09-26:

1. Name: Snoutenstein 3D. Repo `snoutenstein`.
2. Controls: tank controls only, no strafe.
3. Rewind: fully consistent; rewinding past a kill un-does it.
4. No lives. Death freezes time and the only way out is B.
5. Sound toggles with Select on the title screen only (neopixels are off,
   section 12).
6. Boss design (Heisenbug again or new) is deferred to M3/M5.
8. Title tag line "powered by deterministic replay": yes.
7. Wall textures 32x32. Independent of map import: Wolf3D maps carry wall
   codes, not textures, and the importer maps codes onto our eight sheets.
Level grid 64x64 with Wolf3D import (section 6.1): yes.

9. Imported Wolf3D levels: free mapsets and editor-made levels are
   committed. One converted shareware level may ship as a one-off demo
   (this cart runs on Adrian's own badge only); the `.WL1` files
   themselves are never committed.
10. One walk speed everywhere for now; revisit after playing an imported
    level on hardware.

## Status

- 2026-09-26: spec drafted, nothing built yet. Same day: level grid set
  to 64x64 and the Wolf3D `GAMEMAPS` importer added (section 6.1) at
  Adrian's request; pools and memory budget updated. Adrian settled
  all of section 18. M0 scaffold tagged `m0`; M1 (raycaster, sim with
  doors and pickups, placeholder art, Wolf3D importer with E1M1) tagged
  `m1` the same day, `docs/preview_m1.gif`. Awaiting the hardware gate.
- 2026-09-27: M2 (sprites, combat against standing bugs, status bar with
  portrait, first-person weapon, intermission and victory, rewind core
  module with host tests) tagged `m2`, `docs/preview_m2.gif`. Hardware
  gate still pending.
- 2026-09-27: M3 (enemy AI for all five bugs, projectiles, player damage,
  death freeze with a placeholder restart, Build Farm / Staging /
  Production, audio and neopixels, determinism harness) tagged `m3`,
  `docs/preview_m3.gif`. Levels are generated on the host now (the comptime
  parser broke the macOS compiler). Hardware gate still pending; the
  emulated benchmark shows 23% of the frame budget used at worst.
- 2026-09-29: M4 (hold-B rewind through the whole GameState, death rule
  with the 3 s reserve, Iris tint with scanlines and the `<<` marker,
  rewind sweep and purple neopixels, keyframe self-check on wasm/Debug
  builds, `check_determinism.mjs --rewind-at`) tagged `snoutenstein/m4`,
  `docs/preview_m4.gif`. Section 9.1's restart-on-empty-meter is a
  fallback only (note there). Hardware gate still pending.
- 2026-09-29: M5 (attract demo of Build Farm with takeover, DEMO OK /
  DESYNC hash readout on the title, gnat and Heisenbug tuning, enemy
  separation, neopixels off) tagged `snoutenstein/m5`, `docs/preview_m5.gif`.
  Hardware gate still pending; the demo readout is the first hardware
  determinism test once flashed.
- 2026-09-29: M5.1 (`snoutenstein/m5.1`): enemies hurt again at Adrian's
  request (section 8 table: gnat 4 every 40, spit 10, web 6, boss melee
  15 every 45); demo re-recorded.
