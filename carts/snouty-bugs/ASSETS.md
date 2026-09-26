# Art brief: Snouty vs. the Bugs

This file is written to be handed to the pixel-art agent as-is, together with
the attachments listed in section 1. Sections 2 to 6 are the parameters. The
per-asset table in section 7 is the order. Section 8 is the delivery format.
`SPEC.md` section 12 is the code's view of the same manifest; if the two ever
disagree, this file wins and the code adapts.

## 1. Attach with the brief

1. `Snouty_Run_Study_05` (zip from `snouty-badge/assets/`): the approved
   Snouty. The ship's pilot must read as this character: same head, ears,
   snout, eye, purple fur shades, the Iris chest emblem where visible.
2. `snouty_palette.gpl` from that study (the 15-color master palette, listed
   in section 3).
3. `snouty-badge/assets/logo/*.png`: the Antithesis Iris logo marks (white,
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
| 3 | `bolt.png`      | 16x8   | 2      | 2           | Zapper bolt: Coral core, cream leading tip, 12x4 visible. Frame 1 is a slight flicker of frame 0.  |
| 4 | `bugs_small.png`| 8x8    | 4      | 4 (gnat)    | 0-1 gnat wing loop (6x6 visible, green). 2-3 round enemy bullet, 2-frame pulse (6x6 visible).       |
| 5 | `bugs.png`      | 16x16  | 10     | 5           | 0-1 wasp (yellow/black, arrow silhouette), 2-3 beetle (dome, dark green, tan belly), 4-5 spider (round, 8 legs, eyes), 6-7 moth (triangle, big pale wings), 8 needle bullet (8x4 visible, horizontal), 9 bomb pickup (Iris mark in Coral inside a cream ring). |
| 6 | `boss.png`      | 48x48  | 5      | 6           | The Heisenbug: a big beetle/roach hybrid with a question-mark motif on its shell, facing left. 0-3 idle wing loop, 4 teleport silhouette (see 6). Visible ~44x40. |
| 7 | `fx_small.png`  | 16x16  | 8      | 3           | 0-4 small explosion, 5-7 hit spark (8x8 visible centered, white/yellow).                           |
| 8 | `fx_big.png`    | 32x32  | 6      | 4           | Big explosion for boss and player, orange/yellow/white, last frame dark debris.                    |
| 9 | `hud.png`       | 8x8    | 4      | n/a         | 0 Snouty head icon (life), 1 bomb icon (Coral Iris in a ring), 2 empty bomb slot (grey ring), 3 heart. 1 px transparent border. |
|10 | `title.png`     | 128x40 | 1      | n/a         | Lettering "SNOUTY vs THE BUGS" in two lines, chunky 16-bit game logo style, Snouty purples with cream highlights and a Coral "vs". Transparent background. |
|11 | `bg_far.png`    | 256x120| 1      | n/a         | Opaque, tiles seamlessly left-right. Deep space with a faint nebula and a distant "motherboard planet" horizon along the bottom third. Low contrast: everything here sits behind bullets. Up to 15 colors preferred. |
|12 | `bg_near.png`   | 256x24 | 1      | n/a         | Transparent above, tiles seamlessly left-right. Circuit-board terrain: traces, pads, a chip or two, in teal and dark blue. Slightly higher contrast than far, still darker than any bullet. |

Optional, only after 1 to 12 are approved:

| # | File              | Cell   | Frames | Notes                                                              |
|---|-------------------|--------|--------|--------------------------------------------------------------------|
|13 | `snouty_portrait.png` | 48x48 | 1  | Title-screen Snouty waving from the cockpit, for the title card.   |
|14 | `bestiary.png`    | 16x16  | 5      | Clean single frames of each bug for the title bestiary.            |

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
