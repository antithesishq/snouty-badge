# Art brief: Snouty vs. the Bugs

This file is written to be handed to the pixel-art agent as-is, together with
the attachments listed in section 1. Sections 2 to 6 are the parameters. The
per-asset table in section 7 is the order. Section 8 is the delivery format.
`SPEC.md` section 12 is the code's view of the same manifest; if the two ever
disagree, this file wins and the code adapts.

## 1. Attach with the brief

1. `Snouty_Run_Study_05` (zip from `../snouty-run/assets/`): the approved
   Snouty. The ship's pilot must read as this character: same head, ears,
   snout, eye, purple fur shades, the Iris chest emblem where visible.
2. `snouty_palette.gpl` from that study (the 15-color master palette, listed
   in section 3).
3. `../snouty-run/assets/logo/*.png`: the Antithesis Iris logo marks (white,
   black, coral), for the HUD, title and any emblem.
4. Brand colors: Anti-Black `#16031B`, Anti-White `#FCFBF9`, Coral `#F18271`.
5. A screenshot or GIF of the v3 `snouty-badge` cart for the tone of the
   Genesis-style rendering that was approved (`docs/preview_v5.gif`).

## 2. Target and style

- Platform: SYCL Badge V2, 160x128 LCD, RGB565, seen from 30 to 60 cm on a
  lanyard. Small details vanish; silhouettes and 2 px outlines survive.
- Style: 16-bit era (Sega Genesis) pixel art, matching Run Study 05. Hard
  edges, no anti-aliasing, no gradients other than hand-placed bands, no
  sub-pixel effects. Dark 1 px outlines on characters (`#17121e` from the
  master palette). Selective dithering is fine on backgrounds only.
- Every asset is drawn at native resolution. No downscaling from a larger
  drawing. Previews use nearest-neighbor at integer scales.
- Facing: the ship faces right. Enemies face left (they fly toward the
  ship). Bullets are symmetric.
- Mood: comic, not gross. The bugs are software bugs drawn as insects; they
  should be a little goofy. Snouty is the hero and stays cute.

## 3. Palette rules

The badge converter builds one palette per PNG sheet, with at most 15 opaque
colors plus one transparent index. So:

- Each sheet in section 7 may use at most 15 opaque colors. Count them per
  sheet, not per frame.
- Start from the master palette below. Every sheet should use at least the
  outline `#17121e` and one Snouty purple so the game reads as one world.
  Sheets may swap up to 6 colors for their own (e.g. bug greens/yellows,
  explosion oranges), but list the final palette per sheet.
- Backgrounds (`bg_far.png`) may use up to 255 colors if it helps; prefer 15.
- Do not use pure `#FF00FF` anywhere. The build flattens transparency to
  that magenta.
- Transparency is binary: alpha 0 or 255 only.

Master palette (Run Study 05):

```
#17121e outline      #29232f dark       #42364b mid-dark
#462174 purple 1     #662bb8 purple 2   #8e42de purple 3   #be7af3 purple 4
#f4efdf cream        #958d9d grey
#ee453c red          #91322f dark red
#60391f brown 1      #99622f brown 2    #cd934b tan        #f0c37c light tan
```

Suggested additions per family (pick, do not exceed 15 per sheet):
bugs: `#3c8a2e` green, `#8fd14f` light green, `#e6c229` yellow;
fx: `#ffffff` white, `#ffd166` yellow, `#ff7b2e` orange;
background: deep blues `#0b1030`, `#182552`, `#2c3d7a` and one teal `#3fb8af`
for circuit traces.

## 4. Cells, anchors and sheets

- Every animation is delivered as one horizontal strip PNG of equal-size
  cells, no gutters, no margins, frame 0 on the left. The code indexes cells
  by `index * cell_width`.
- Cells have the sizes in section 7. The visible drawing may be smaller than
  the cell; keep at least 1 px of empty border inside the cell so outlines
  never touch the cell edge (prevents bleeding when clipped).
- Anchor: the cell's top-left is the anchor. The code positions the cell,
  not the drawing, so keep each frame's drawing at the same place within the
  cell across all frames of one strip. No per-frame trimming or recentering.
- For the ship, additionally mark the hitbox: report the cell-relative
  rectangle of the cockpit (6x6) in the metadata JSON. The game uses that
  exact rectangle as the collision box. It must be inside Snouty's head or
  chest, never on the wings or thruster.
- Frame timing is given per strip in section 7 in ticks (1 tick = 1/60 s).
  Loops play frame 0..N-1 forward and wrap. Never ping-pong, never append a
  duplicate of frame 0.

## 5. Readability rules for a bullet-hell

- Enemy bullets must be the highest-contrast objects on screen: light core,
  1 px dark outline, on any background. Round bullet: 6x6 visible in an 8x8
  cell, cream/white core with a colored rim. Needle: 8x4, drawn horizontally.
- Player bolts are a different hue from all enemy bullets (Coral core,
  cream tip) so the player never confuses them.
- Enemies read as silhouettes: each of the five kinds has a distinct
  outline shape (gnat = dot with wings, wasp = arrow, beetle = shield/dome,
  spider = round body with legs, moth = triangle with big wings).
- Nothing important is drawn in the darkest two palette entries; the badge
  LCD crushes shadows.

## 6. Animation notes

- Idle loops: 2 to 4 frames, 4 to 6 ticks per frame. Wing loops can be 2
  frames.
- Explosions: start compact and bright, expand, then fade to dark
  outline-only debris. Last frame is small so the pop reads.
- Ship banking: the up and down frames are the level frame with the wing
  tilted and Snouty's head shifted 1 px; do not redraw the ship.
- Boss teleport frame: the boss drawn in a single flat mid-purple silhouette
  with a lighter 1 px rim. The code adds a per-pixel flicker.

## 7. The order

| # | File            | Cell   | Frames | Ticks/frame | Contents and notes                                                                                   |
|---|-----------------|--------|--------|-------------|------------------------------------------------------------------------------------------------------|
| 1 | `ship.png`      | 32x24  | 3      | n/a (pose)  | Snouty in a small open-cockpit ship, facing right: 0 level, 1 banking up, 2 banking down. Snouty's head about 12 px tall, Iris emblem on the hull. Report the 6x6 hitbox. |
| 2 | `thruster.png`  | 8x8    | 4      | 3           | Flame loop, drawn to sit against the ship's tail at a reported offset (e.g. (-6, 10) from ship cell origin). |
| 3 | `bolt.png`      | 16x8   | 6      | 2           | Player bolts, two flicker frames each (M6). 0-1 FUZZER zap: Coral core, cream leading tip, 12x4 visible. 2-3 ASSERT beam segment: 2 px Anti-White bar at y 3..4 over x 1..14 with Coral caps and glow (the cart also draws beams as rects). 4-5 BISECT seeker: purple dart pointing right, cream nose, about 9x6 body centred, short flickering tail. |
| 4 | `bugs_small.png`| 8x8    | 4      | 4 (gnat)    | 0-1 gnat wing loop (6x6 visible, green). 2-3 round enemy bullet, 2-frame pulse (6x6 visible).       |
| 5 | `bugs.png`      | 16x16  | 10     | 5           | 0-1 wasp (yellow/black, arrow silhouette), 2-3 beetle (dome, dark green, tan belly), 4-5 spider (round, 8 legs, eyes), 6-7 moth (triangle, big pale wings), 8 needle bullet (8x4 visible, horizontal), 9 spare (was a bomb pickup; the bomb was dropped 2026-09-27, so any 16x16 bug-themed extra is welcome or leave it blank). |
| 6 | `boss.png`      | 48x48  | 5      | 6           | The Heisenbug: a big beetle/roach hybrid with a question-mark motif on its shell, facing left. 0-3 idle wing loop, 4 teleport silhouette (see 6). Visible ~44x40. |
| 7 | `fx_small.png`  | 16x16  | 8      | 3           | 0-4 small explosion, 5-7 hit spark (8x8 visible centered, white/yellow).                           |
| 8 | `fx_big.png`    | 32x32  | 6      | 4           | Big explosion for boss and player, orange/yellow/white, last frame dark debris.                    |
| 9 | `hud.png`       | 12x8   | 4      | n/a         | 0 Snouty head icon (rewind stock; 10x6 visible, see the 2026-09-29 notes), 1 RETRY shield (M6; Coral heater shield, cream rim, 8x6 visible, drawn centred above the ship cell at y - 6 while the shield is up), 2 spare (was a bomb icon; the fuel bar is drawn in code), 3 heart. 1 px transparent border. |
|10 | `title.png`     | 128x40 | 1      | n/a         | Lettering "SNOUTY BUGHUNT" in two lines ("SNOUTY" / "BUGHUNT"; the game was called "Snouty vs. the Bugs" until 2026-09-29), chunky 16-bit game logo style, Snouty purples with cream highlights and "BUGHUNT" in Coral. Transparent background. |
|11 | `bg_far.png`    | 256x120| 1      | n/a         | Opaque, tiles seamlessly left-right. Deep space with a faint nebula and a distant "motherboard planet" horizon along the bottom third. Low contrast: everything here sits behind bullets. Up to 15 colors preferred. |
|12 | `bg_near.png`   | 256x24 | 1      | n/a         | Transparent above, tiles seamlessly left-right. Circuit-board terrain: traces, pads, a chip or two, in teal and dark blue. Slightly higher contrast than far, still darker than any bullet. |
|13 | `pickups.png`   | 16x16  | 6      | n/a         | M6 crates (SPEC.md 5.4), see the note below: 0 FUZZER "F", 1 ASSERT "A", 2 BISECT "B", 3 FORK (branching path), 4 RETRY (shield), 5 CORE HOURS (CPU chip). 1 px transparent border. |
|16 | `bugs2.png`     | 16x16  | 12     | 5           | M7 bugs, see the M7 note below: 0-1 centipede head (Stack Overflow), 2-3 centipede segment, 4-5 flea (Null Pointer; 0 crouched, 1 leaping; faces right), 6-7 ladybug (Infinite Loop; 0 shell shut, 1 flying), 8-9 mite (Buffer Overflow; ground turret, two walk frames, feet on row 14), 10-11 zombie (Use After Free; the husk is cell 10 drawn dithered). |
|17 | `herd.png`      | 32x32  | 2      | 6           | M7 midboss Thundering Herd: an aphid queen, mother of the gnat swarms, facing left; wing loop. |
|18 | `boss2.png`     | 48x48  | 5      | 6           | Mandelbug (stage 2 boss): a top-down bug whose body is the Mandelbrot set facing left. 0-3 idle (halo colour cycle, legs), 4 alt = glowing / splitting. |
|19 | `boss3.png`     | 48x48  | 5      | 6           | Schrodinbug (stage 3 boss): a cat-eared bug peeking out of a cardboard box with a psi on it. 0-3 idle, 4 alt = collapse (popped out, eyes wide). |
|20 | `boss4.png`     | 48x48  | 5      | 6           | Bohrbug (stage 4 boss): an armoured rhinoceros-beetle tank with an atom on its hull. 0-3 idle (treads roll, electrons orbit), 4 alt = charge. |
|21 | `shots.png`     | 8x8    | 4      | 4           | M7 pellet bullet: 0-1 pellet pulse (4x4 dot at x 2..5, y 2..5, pink rim, white core), 2-3 Coral variant (spare). |
|22 | `orb.png`       | 16x16  | 2      | 4           | M7 orb bullet: 12x12 at x 2..13, hot-pink ring, Coral body, white core; 2-frame pulse. |


**Crates (`pickups.png`, M6).** Bugs drop crates that grant a weapon, a
fork, a retry shield or fuel (SPEC.md 5.4). Every crate is the same 14x14
chamfered box: 1 px `#17121e` outline, a lit top row and left column, a
shaded right column and bottom lip, and a 10x9 face carrying one bold
glyph (5x7 letters, 1 px strokes, a 1 px drop shadow in the crate's shade
tone). Colours: FUZZER Coral with a white `F`, ASSERT teal with a white
`A`, BISECT green with a white `B`, FORK purple with a white Y-shaped
branch (a fork in the path), RETRY cream with a Coral shield, CORE HOURS
yellow with a dark CPU chip and its pins (the datacenter's core hours).
Square, solid and boxy on purpose: enemy bullets are small round discs
and 8x4 needles, bugs are irregular silhouettes, so a crate reads as
neither. The six hues share their lit and shade tones to stay inside 15
colours. The cart collides crates against the whole 32x24 ship cell.

**M7 sheets (2026-10-04, PLAN.md "M7 Bullet hell for real").** Drawn by
`tools/prepare_assets.py` like the rest; review image
`docs/m7_art_review.png` (`--review`). Shared rules: enemies face left
except the flea; white, cream and Coral never fill a large area of a bug
or boss, so enemy bullets stay the brightest warm things on screen; every
cell keeps the 1 px empty border and its drawing at the same place in
every frame.

- **Enemy bullets are warm, the player's are not their colour.** Pellet
  (`shots.png`): a 4x4 dot at cell x 2..5, y 2..5 (draw at bullet centre
  - (4, 4)), 2x2 white core, light pink rim (frame 0) / hot-pink rim with
  dark corners (frame 1). Pink rather than Coral because the FUZZER zap in
  `bolt.png` has been Coral since M1; shape (dot vs 12x4 bar) and the pink
  keep them apart. Cells 2-3: the same dot with a Coral rim (frame 1 has
  red corners), spare for split children or revenge bullets. Orb
  (`orb.png`): 12x12 at x 2..13 (draw at centre - (8, 8)), dark outline,
  hot-pink ring, Coral body, white core with a pink rim and a glint; frame
  1 grows the core. Both read on bg_far, bg_near and over every boss.
- **Centipede** (`bugs2` 0-3), top-down. A segment is a tall teal plate
  (x 4..11, y 2..13 with outline, centre (7.5, 7.5)) cut into three
  stacked "frames" by two dark seams (the call stack), one tan leg pair
  above and below (x 4..11, rows 1 and 14) that swings between the two
  frames. The head is rounder and darker (centre (8.5, 7.5)), yellow eyes,
  tan fangs at x 2..3 and antennae reaching forward to x 1..2. Chain: draw
  the tail segment first and the head last, segment cells 8 to 9 px apart
  along the path (the review mock uses 9 with a sine weave); alternate
  cells 2 and 3 along the chain so the legs ripple.
- **Flea** (`bugs2` 4-5), side view facing RIGHT (it jumps in from behind
  the ship): a hunched brown oval with banded segments, a tiny head low at
  the front (red eye at x 13), the huge tan hind leg folded in a Z under
  the body (4, crouched/landed) or kicked out behind and down (5,
  airborne; the body is 1 px higher). Pick the cell by state, not by a
  loop.
- **Ladybug** (`bugs2` 6-7), top-down facing left: red shell, dark seam,
  four 2x2 black spots, black head with two cream eye dots; 7 has the wing
  cases parted and grey wings out (flying). Alternate 6/7 every few ticks
  while it flies its loops.
- **Mite** (`bugs2` 8-9), side view facing left, a ground turret: feet on
  cell row 14, so draw it at ground row - 15 (the near layer's top edge is
  at screen y 111..114 depending on the segment). Steel dome (x 3..14,
  y 5..11) with a yellow/dark hazard band, cream bytes spilling over the
  top, red eye at (5, 10). The gun barrel points up-left; its yellow
  muzzle is at cell (2..3, 3..4): emit from (3, 4). Two walk frames.
- **Zombie** (`bugs2` 10-11), top-down facing left: a sick-green moth gone
  undead, four ragged wing lobes with bites out of the trailing edges, a
  dark body, red eyes, two forelegs stretched straight ahead. The husk is
  cell 10 drawn with `skip_odd`; the wings are deliberately large flat
  pale fills (rows 1..14) so the shape survives the 50 % checkerboard (see
  the review image). The forelegs are 1 px and vanish in the husk; that is
  fine, the husk should read as a dead shell.
- **Thundering Herd** (`herd.png`), the midboss: an aphid queen facing
  left, x 2..30, y 1..30. Fat green pear abdomen (about x 9..30, y 9..26)
  with a row of light-green eggs along the flank (about x 12..28, y 20..23),
  two cornicle tubes with yellow tips on her back, a small head with a red
  eye and a yellow crown at x 2..10, long tan antennae swept back, grey
  wings up (0) and back (1). Suggested emitters: flowers from the cell
  centre (16, 16); gnat strings released from the egg row (about (18, 22)).
- **Mandelbug** (`boss2.png`): top-down, the body is the Mandelbrot set
  (sampled at 0.052 per px, the real axis on row 24): the main cardioid is
  the body (x 25..45, y 12..36), the period-2 bulb the head (x 15..24,
  y 20..28, yellow eyes at x 13..14), the filament on row 24 a long
  proboscis from x 1. Every smaller bulb is its own outlined segment and
  each component carries its own nested copies (multiplier level sets), so
  the bug is made of smaller copies of itself. The body's bright core (the
  cardioid's centre, c = 0) is at (39, 24): a good emitter, as is the cell
  centre (24, 24) at the neck. Two tan leg pairs reach rows 2..46. Cells
  0-3 cycle the 1 px escape-time halo (fractal colour cycling) and step
  the legs. Cell 4: the bulbs pushed 2 px off the body (splitting), the
  body lit, a wider yellow halo. Collision: the body, about x 14..45,
  y 12..36.
- **Schrodinbug** (`boss3.png`): a grey cat-eared bug in an open cardboard
  box, 3/4 view. Box front x 8..35, y 27..44 with a purple psi; side face
  x 36..42; flaps out to x 2 and x 41. Head centred (22, 20) (bobs 1 px),
  yellow slit eyes at x 17 and 26 looking left, purple ball-tipped
  antennae up to row 1, two claws over the rim, a striped tail curling up
  at x 35..46. The cell centre (24, 24) is the chin over the rim, a fine
  emitter. Big flat fills on purpose: both bodies are drawn dithered while
  superposed. Cell 4 (collapse): flaps blown flat, the bug popped 7 px up
  out of the box with its torso showing, eyes wide and round, mouth open.
  Collision: about x 8..42, y 10..44.
- **Bohrbug** (`boss4.png`): side view facing left, an armoured
  rhinoceros-beetle tank. Riveted gunmetal hull x 9..45, y 13..35 with two
  plate seams; tank treads x 5..43, y 35..45 (four road wheels, teeth that
  roll one step per idle cell, so 0-3 loop exactly); a visored head x 4..15
  with a yellow eye slit on row 28; a horn sweeping forward and up to its
  tip at about (5, 5) (the cannon muzzle). On the hull an atom: nucleus at
  (28, 23) (the natural emitter), three 1 px teal orbits, electrons a
  quarter turn further each cell. Cell 4 (charge): horn and seams yellow,
  visor bright, electrons flung onto wider orbits. No white anywhere.
  Collision: about x 6..45, y 13..45.

Optional, only after 1 to 13 are approved:

| # | File              | Cell   | Frames | Notes                                                              |
|---|-------------------|--------|--------|--------------------------------------------------------------------|
|14 | `snouty_portrait.png` | 48x48 | 1  | Title-screen Snouty waving from the cockpit, for the title card. Not currently wanted: a bust-only placeholder was tried 2026-09-29 and dropped; the title card draws the ship sprite. |
|15 | `bestiary.png`    | 16x16  | 5      | Clean single frames of each bug for the title bestiary.            |

## 8. Delivery format (per study, mirrors Run Study 05)

For each numbered study (start at Study 01; a revision is Study 02, etc.):

```
Bugs_Study_NN/
  README.md                what changed, per-sheet palettes, anchors, hitbox, timing
  sheets/<name>.png        RGBA strips exactly as in section 7 (alpha 0/255)
  sheets/<name>_indexed.png  same strip, indexed PNG, index 0 transparent
  frames/<name>_00.png ... individual RGBA cells
  contact_sheet.png        every sheet at 4x nearest-neighbor, cells numbered
  preview.gif              each animated strip looping at its tick rate, 4x
  mockup.png               one 160x128 frame composed as the game will look
                           (far bg, near bg, ship, 6 bugs, 20 bullets, HUD)
                           and the same at 4x. This is the review image.
  assets.json              per sheet: cell size, frame count, ticks per frame,
                           palette (hex list), transparent index, anchors
                           (thruster offset, ship hitbox rect), loop order
  palette_<sheet>.gpl      GIMP palette per sheet
  validate.py              checks: alpha binary, <=15 opaque colors per sheet,
                           cell bounds, no #FF00FF, strips match frames
```

Review is by the mockup first. Ask for a mockup with placeholder shapes
before drawing all sheets, so the sizes can be approved at badge scale.

## 9. What not to do

- No copyrighted sprites or recognisable references (no Sonic, no Gradius
  ships). Original art in the era's style.
- No text baked into sprites except the title logo. The game renders all
  other text with its built-in 8x8 font.
- No semi-transparency, glow, or blur. If a glow is wanted, draw it as a
  1 px lighter rim.
- No gutters, padding rows, or multi-row sheets. One strip per file.

## 10. Notes from the M1 placeholder pass (2026-09-26)

Found while drawing placeholder sheets to this brief; the code and
`tools/prepare_assets.py` follow the values below.

- Thruster offset: the code attaches the 8x8 flame cell at (-6, 8) from the
  ship cell origin (section 7 says "(e.g. (-6, 10))" as an example). Report
  the real offset in the metadata JSON; the script fails loudly if it differs
  from the code so it gets updated deliberately.
- Snouty's snout is purple in Run Study 05, only the eye is cream. Keep that.
- At 32x24 the cockpit rim hides Snouty's chest, so the Iris goes on the hull
  (section 7 already says so); do not expect a chest emblem on the ship.
- The 1 px empty border rule (section 4) cannot apply to the thruster's
  attach edge, which must touch the nozzle. State the attach column instead.
- Explosion last frames as "dark outline-only debris" vanish on a navy
  background; use mid-dark or grey debris.
- Backgrounds: give the far layer a value ceiling (nothing brighter than
  about `#5866a0`) and make the near layer's fill darker than the far
  planet so the two layers separate.
- The 8x8 Snouty-head life icon is at the limit of legibility: a profile
  silhouette with a single cream eye pixel is about what fits.
- Lives are now "rewinds" (SPEC.md 5.1): `hud.png` frame 0, the Snouty
  head, keeps that HUD slot for now. If a legible 8x8 rewind glyph (a
  counter-clockwise arrow in Coral) turns out possible, offer it as an extra
  frame; not required.

Notes from the M2 placeholder pass (`bugs.png`, `fx_big.png`):

- Needle: the code always draws it horizontally, whatever direction it
  travels (moth needles are aimed, so usually diagonal). Keep it symmetric
  and 8x4 including its outline, centred in its 16x16 cell at x 4..11,
  y 6..9; the code draws the cell at bullet centre - (8, 8) and collides
  8x4 centred. A rotated needle would need more cells and code; not asked.
- Round bullet pulse frames are in `bugs_small.png` cells 2-3 (8x8, drawn at
  centre - (4, 4)); the needle is in `bugs.png` cell 8. Two bullet shapes,
  two sheets: keep both cores in the same cream/white so they read as one
  "enemy bullet" family.
- Bullet contrast: on the placeholder navy backgrounds a white core with
  the `#17121e` outline is the brightest thing on screen except the fx and
  the pale moth wings; do not make moth wings as white as bullet cores
  (placeholder moth is cream with light-tan edges for that reason).
- Wasp and moth both point left and both read as "arrow" shapes; the brief
  says wasp = arrow, moth = triangle with big wings. The placeholder keeps
  them apart by size and colour (thin yellow chevron vs. cell-filling pale
  delta). The real art should push the difference in silhouette too.
- Spider: the cart draws the thread at cell x 8 down to the cell top. The
  body sits centred on x 7.5 with a 3 px thread stub at x 8, rows 1..3;
  leg tips reach x 1 and x 14, so the spider uses the full cell width.
- Beetle and spider legs are single pixels; beetle legs are outline colour
  (they read as part of the silhouette), spider legs grey so they survive
  on the dark background.
- fx_big: brief section 6 says the last frame is "dark outline-only
  debris", section 7 says "dark debris"; as with `fx_small`, the placeholder
  uses grey and mid-dark smoke (frame 4 a broken ring, frame 5 a small puff
  with two orange embers) because outline-dark pixels vanish on navy.

Notes from the Snouty icon revision (2026-09-29, `hud.png`, title card):

- Adrian: the 8x8 head icon read as a rat (a snout tapering to a point and
  a 1 px ear). The HUD cell is 12x8 now, so the head has 10x6 visible
  pixels: a round 2 px ear on the back of the dome, a 2x2 cream eye with
  the pupil forward, and a blunt snout tube 2 to 3 px thick that droops at
  the tip. Keep those four features in any real version; they are what
  separates Snouty from a rodent at this size. The code draws the icons at
  x 160 - 12 * (i + 1), so five fill x 100..159 right of the fuel bar.
- The title card no longer reuses the HUD icon: it draws the ship's level
  cell with the thruster loop at (64, 62), bobbing 1 px, under the two
  title lines ("SNOUTY" / "BUGHUNT" in the 8x8 font at y 40 and 52). A
  48x48 bust portrait was tried and dropped the same day; Adrian prefers
  the in-game ship.

Notes from the M3 placeholder pass (`boss.png`, `title.png`):

- Boss layout in its 48x48 cell (placeholder, side view facing left): the
  body (shell, pronotum, head, belly) sits at about x 4..44, y 13..37; legs
  hang to y 45, antennae and raised wings reach up to y 2. The whole drawing
  stays inside x 2..46, y 2..45 (so about 45x44 with appendages, 41x25 for
  the body), identically placed in all five cells. Keep the body fixed
  across cells 0-3; only wings, legs and antenna tips move.
- Emitter: the code fires every pattern from the cell centre (24, 24). The
  placeholder puts the "?" there (x 20..28, y 17..28), so bullets appear to
  come out of the question mark. The head and red compound eye are at the
  far left (eye about (5..10, 26..31)); if the real art wants bullets to
  come from the mouth, report an emitter offset instead of moving the body.
- Collision is a rectangle chosen by the code; report the body rectangle
  (not wings or antennae) in the metadata JSON.
- Teleport cell 4: flat `#8e42de` with a 1 px `#be7af3` rim, no outline
  colour and no interior detail at all (the code's per-pixel flicker and
  `skip_odd` only read on a flat fill). Its silhouette is cell 0's exactly.
- Boss palette is at the 15-colour limit (master outline, mid-dark, purples
  1-4, grey, red, dark red, browns 1-2, tan, plus bug yellow, green and
  light green for the "?"). The brightest pixels are the yellow "?" and the
  grey wing; nothing is cream or white, so round bullets and needles stay
  the brightest thing when they cross it. Keep it that way.
- Title: hand-placed 5x7 block glyphs scaled 3x ("SNOUTY") and 2x
  ("BUGHUNT", since 2026-09-29) with 45-degree chamfers on every diagonal
  step, banded purple 4/3/2 fill, cream top edge, purple 1 bottom edge,
  1 px outline; the second line is Coral with red/dark-red shading. The two lines share
  one outline row (y 23) to fit 40 px. 9 colours. Never render the logo
  with a font rasteriser: its anti-aliasing blows the 15-colour budget.
