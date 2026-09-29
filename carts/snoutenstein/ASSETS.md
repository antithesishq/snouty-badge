# Art brief: Snoutenstein 3D

Hand this file to the pixel-art agent as-is, together with the attachments
listed in section 1. Sections 2 to 6 are the parameters, section 7 is the
order, section 8 the delivery format. `SPEC.md` section 14 is the code's
view of the same manifest; if the two ever disagree, this file wins and the
code adapts. `docs/placeholders.png` shows the current stand-in art for
every sheet at 3x, plus three 160x128 mockups. It shows sizes, layout and
frame order. It is not a style target.

## 1. Attach with the brief

1. `../snouty-run/assets/Snouty_Run_Study_05/` (or `Snouty_Run_Study_FINAL.zip`
   next to it): the approved Snouty, a purple anteater in a black shirt
   with the Coral Iris on the chest. The HUD portrait and the paw on
   the weapons must read as this character: same purples, cream eye with
   a dark pupil, long snout, round ears.
2. `../snouty-run/assets/Snouty_Run_Study_05/snouty_palette.gpl`: the
   15-colour master palette, listed in section 3.
3. `../snouty-run/assets/logo/White Logo Mark.png`, `Black Logo Mark.png`,
   `Coral Logo Mark.png`: the Antithesis Iris mark, for the mural wall, the
   title and any emblem. `assets/gen/iris_16.png` in this repo is the
   existing 16x16 pixel version.
4. Brand colours: Anti-Black `#16031B`, Anti-White `#FCFBF9`, Coral
   `#F18271`, Iris purple `#8E42DE` (purple 3 of the master palette).
5. `../snouty-bugs/docs/preview_m3.gif` and `../snouty-run/docs/preview_v5.gif`:
   the tone of the two carts already on the badge.
6. `docs/placeholders.png` from this repo: the stand-ins and mockups.

## 2. Target and style

- Platform: SYCL Badge V2, 160x128 LCD, RGB565, seen from 30 to 60 cm on
  a lanyard. The 3D view is 160x104 (horizon at y 52), and below it is a 24 px
  status bar. Small details vanish. Silhouettes, flat colour areas and
  2 px features survive.
- Game: Wolfenstein 3D style first-person raycaster. Snouty walks a
  **server room / build farm** (racks, cable trays, monitors, pipes) and
  swats software bugs drawn as insects. The theme is Antithesis: Iris marks
  and Iris purple as accents, never as an advert. Mood: **comic, not gross**.
  The bugs are goofy, deaths are cartoon (X eyes, legs up), no gore, no
  splatter.
- Style: 16-bit era (Sega Genesis) pixel art matching Run Study 05. Hard
  edges, no anti-aliasing, hand-placed shading bands, dark 1 px outlines
  (`#17121e`) on sprites. Dithering only on large wall areas and mist.
- **Draw at native size. No downscaling from a larger drawing.** Previews
  use nearest-neighbour at integer scales.
- **Every sprite always faces the camera.** There are no rotation frames:
  enemies, pickups and projectiles are billboards seen head-on from any
  side. Draw bugs from the front, symmetric or nearly so.

### Why 32x32 textures (SPEC.md section 5)

A wall that fills the view's height is one texture tall. Wolf3D drew 64
texel textures on a 200 px tall view, about 0.32 texels per screen pixel
at full height. We draw 32 texel textures on a 104 px view, about 0.31.
So a 32x32 wall at badge scale carries the same detail per screen pixel as
Wolf3D's 64x64 did on a PC. Draw the textures at 32x32 exactly. Every
texel counts, and a detailed 64x64 drawing scaled down turns to mush.
Enemies use the same density: a 32x32 enemy cell is exactly one wall
height (floor to ceiling) at any distance.

## 3. Palette rules

The build (`cart/build/convert_gfx.zig`) makes **one 16-entry palette per
PNG** from the RGB565-quantised pixels:

- Transparent sheets (everything except walls and doors): at most **15
  opaque colours per sheet** plus transparency (index 0). Count per sheet,
  not per frame.
- `walls.png` and `doors.png` are opaque: **16 colours per sheet**, no
  transparency. All eight wall textures share **one** 16-colour palette.
  The renderer derives its lit, dark, dim and tinted sets from it, so
  choose these 16 for the whole server room.
- Colours that differ only in their lowest bits merge in RGB565. Keep
  colours at least 8 apart per channel.
- Never use `#FF00FF`. The build flattens transparency to it.
- Transparency is binary (alpha 0 or 255).
- Start from the master palette. Every sheet uses the outline `#17121e`,
  and every sheet except walls/doors uses at least one Snouty purple.

Master palette (Run Study 05):

```
#17121e outline      #29232f dark       #42364b mid-dark
#462174 purple 1     #662bb8 purple 2   #8e42de purple 3   #be7af3 purple 4
#f4efdf cream        #958d9d grey
#ee453c red          #91322f dark red
#60391f brown 1      #99622f brown 2    #cd934b tan        #f0c37c light tan
```

Additions used by the placeholders (pick, never exceed the per-sheet limit):
steel `#6d6a86` (the mid grey the master palette lacks, for metal),
teal `#3fb8af` (LEDs, screens, zapper), Coral `#F18271`, gold `#e6c229`,
bug greens `#24552a` `#3c8a2e` `#8fd14f`.

The placeholder `walls.png` palette, a good starting point:
`#17121e #29232f #42364b #6d6a86 #958d9d #f4efdf #462174 #662bb8 #8e42de
#be7af3 #91322f #ee453c #60391f #99622f #cd934b #3fb8af`.

Key colours must be unmistakable at 20 cells in dim light: **Coral**
(`#F18271` with `#91322f` shadow, cream highlight), **Iris** (purple 3
with purple 1 shadow, purple 4 highlight), **Gold** (`#e6c229` with brown 2
shadow, cream highlight). Use the same three ramps on the lock plates, the key
pickups and the HUD key icons.

## 4. Cells, anchors and sheets

- Each sheet is one horizontal strip PNG of equal cells, frame 0 on the
  left, no gutters, no margins, one row. The code indexes `i * cell_w`.
- Sprite cells keep **1 px of empty border** on all four sides.
  Exceptions:
  - `bug_spider.png`: the thread runs up to the top edge in column
    **x 15**. It is the only pixel column allowed to touch the edge (frames 0 to 4;
    frames 5 and 6 have no thread).
  - `weapons.png`: the arm comes in from below, so every frame **touches the
    bottom edge** and keeps the other three edges clear.
- Anchors (the code positions the cell, never the drawing; keep the drawing
  at the same place in every frame of a strip, no per-frame trimming):
  - **Enemies (32x32)**: the cell spans floor (row 31) to ceiling (row 0)
    at the enemy's position, centred horizontally. Walkers (beetle, boss)
    stand on row 30. Flyers (gnat, wasp) hover with their body in rows
    about 6 to 26. The spider hangs from the ceiling with its body in the upper
    half. The boss is drawn at 1.5x (see section 10).
  - **Pickups (16x16)**: same texel density as walls, so half a cell tall.
    Bottom centre on the floor: the drawing rests on row 14.
  - **Projectiles (8x8)**: centre anchor, drawn at about mid-height.
  - **Weapons (48x32)**: bottom centre of the 3D view (x 56..103,
    y 72..103), bobbing up to 2 px with walking.
  - **Face (24x24)**: centred in the status bar (x 68..91, y 104..127).
    The code draws a 2 px frame around it.
  - **HUD icons (8x8)**, **title (128x40)**: top-left.
- Wall and door textures are opaque and use the whole 32x32. **Wall
  textures must tile horizontally and vertically**: neighbouring wall cells
  place the texture side by side, and the left and right edges must meet
  with no break. Design them top to bottom the same way. Bevelled panel
  edges are fine, a feature cut off at the edge is not.
- Doors are single panels (no tiling needed) that slide sideways into the
  wall, so give them a clear frame on both vertical edges.

## 5. Readability rules for a first-person view

- **Light is baked into the textures.** Wolf3D's look comes from lit
  top/left edges and dark bottom/right edges drawn into every texture
  (bevels, brick highlights, rack-unit shadows). The renderer adds only
  a flat darkening for walls facing north/south and for distance (> 6 and
  > 10 cells), so the texture itself must carry the light/dark structure.
  Do not rely on the palette for it.
- The eight textures must be tellable apart at 10 cells (about 10x10
  screen pixels). Give each a distinct large-scale structure: horizontal
  rack units, horizontal cable bands, brick courses, a square grille, the
  big Iris mark, a 2x2 screen grid, vertical pipes, the lit sign.
- Doors: the **lock plate and a full-width stripe are in the key colour**
  (plain door: steel plate, dark groove). A player must be able to tell
  Coral, Iris and Gold doors apart from across a room. The exit
  elevator must look unlike every other door: two leaves and a teal "go"
  light.
- Enemies read as **distinct silhouettes**: gnat = small round body with
  big wings, wasp = tall hourglass with a raised V of wings, beetle = wide
  low dome with legs to the floor, spider = round body hanging from a
  thread with eight legs, boss = the biggest, with a shield and long
  antennae.
- Projectiles are the highest-contrast things in the view: light core, dark
  outline. Spit is green, web is cream.
- Nothing important in the darkest two palette entries. Distance
  shading and the LCD crush them.
- Weapons are seen **from behind and below**: Snouty's purple paw (in a black
  shirt sleeve) holds the weapon, pointing into the screen. Keep them
  compact and centred so they do not hide enemies, at most about 40x30 of
  the 48x32 cell.

## 6. Animation notes

- Enemies, seven frames (boss eight), in this order: **walk 0, walk 1,
  attack, pain, death 0, death 1, death 2**, boss adds **flicker** as
  frame 7. Walk frames alternate legs or wings (2-frame loop, about 8 ticks
  each). Attack is the wind-up pose that the code holds while the attack
  lands. Pain is a flinch (eyes squeezed, body pulled in). The code also
  flashes enemies white for 2 ticks on a hit, so pain need not be bright.
  Death 0 to 2 is one cartoon fall: hit (X eyes, sagging), on its back
  (legs up), flattened remains that stay on the floor for the rest of the
  level. Keep death 2 small and dark enough not to look alive.
- Boss flicker frame: frame 0's silhouette in flat purple 3 with a 1 px
  purple 4 rim, no interior detail. The code flickers it before teleporting.
- Weapons, per weapon **idle, fire 0, fire 1** (swatter: idle, swing 0,
  swing 1): fire 0 is the big moment (bolt, mist, swat), fire 1 the
  recovery. The code shows each fire frame about 4 ticks.
- Portrait: nine still frames, no animation of their own. The code picks
  one per tick.
- Pickups, projectiles: projectiles have two-frame loops (pulse, spin).
  Pickups are single frames.
- Loops play forward and wrap. Never ping-pong, never repeat frame 0 at
  the end.

## 7. The order

Every sheet in `SPEC.md` section 14 except `iris_16.png` (kept from
snouty-badge). Sizes are exact.

| # | File              | Cell   | Frames | Sheet px | Frame order and notes |
|---|-------------------|--------|--------|----------|-----------------------|
| 1 | `walls.png`       | 32x32  | 8      | 256x32   | Opaque, one 16-colour palette, every cell tiles in x and y. 0 server rack (front of a 19" rack: rails, drive bays, switch ports, LEDs), 1 cable tray (bundled coloured cables on trays across the wall), 2 brick (old building wall, running bond), 3 vent (louvred grille in a steel panel), 4 Iris mural (the Antithesis Iris mark on purple tiles), 5 monitor wall (screens: log, graph, a red failure, an Iris progress bar), 6 pipes (copper, steel, red sprinkler, floor to ceiling), 7 exit sign strip (lit EXIT sign over a hazard band; the only wall with text). |
| 2 | `doors.png`       | 32x32  | 5      | 160x32   | Opaque, 16 colours. 0 plain (steel, plain plate), 1 Coral lock, 2 Iris lock, 3 Gold lock (lock plate and stripe in the key colour, keyhole), 4 exit elevator (two leaves, teal light). |
| 3 | `bug_gnat.png`    | 32x32  | 7      | 224x32   | Off-by-one: small round green bug, big cream eyes, buzzing wings. One antenna one pixel longer than the other. Hovers. walk 0, walk 1, attack (bite, mouth open), pain, death 0-2. |
| 4 | `bug_wasp.png`    | 32x32  | 7      | 224x32   | Race Condition: yellow/black wasp, dark red compound eyes, raised wings, striped abdomen curled toward the camera. attack = charge pose, stinger aimed at the viewer, wings swept flat. |
| 5 | `bug_beetle.png`  | 32x32  | 7      | 224x32   | Memory Leak: wide low green dome on the floor, red eyes, tan mandibles, a small purple drip (the leak). attack = mandibles open with a green glob of spit. |
| 6 | `bug_spider.png`  | 32x32  | 7      | 224x32   | Deadlock: round purple spider on a grey thread (column x 15, up to the top edge in frames 0-4), gold padlock on its abdomen, four red eyes, eight grey legs. attack = drops a little, front legs up, fangs open. Death 1 falls (no thread), death 2 lies on the floor. |
| 7 | `bug_boss.png`    | 32x32  | 8      | 256x32   | Heisenbug: big purple roach head-on, yellow "?" on the shield, huge red eyes, long antennae, spiky brown legs. Drawn at 1.5x. walk 0-1, attack (spit), pain, death 0-2, 7 flicker (section 6). |
| 8 | `pickups.png`     | 16x16  | 8      | 128x16   | 0 Coral key, 1 Iris key, 2 Gold key, 3 hotfix (health: medkit or patch), 4 zapper charge (cell with a bolt), 5 bug spray can, 6 rewind battery (Iris purple, a `<<` mark), 7 Debugger cartridge (M6: grey cartridge, grip ridges, cream label with the red breakpoint dot). Standing on row 14. |
| 9 | `projectiles.png` | 8x8    | 6      | 48x8     | 0-1 spit (green glob, pulse), 2-3 web (cream strands, spin 45 degrees), 4 Debugger bolt (red breakpoint dot, cream core, dark outline; drawn at 0.25 cells), 5 Debugger burst (red and cream ring with rays filling the cell; drawn at 1.0 cell, display only, no loop). |
|10 | `weapons.png`     | 48x32  | 12     | 576x32   | From behind/below, bottom edge touched by the arm. 0 swatter idle, 1 swing 0 (wind-up), 2 swing 1 (swat, big, streaks); 3 zapper idle, 4 fire 0 (teal bolt), 5 fire 1; 6 spray idle, 7 fire 0 (mist), 8 fire 1; 9 Debugger idle (boxy steel breakpoint gun, big red dot on its back face, short wide muzzle slab), 10 fire 0 (red bolt leaving the muzzle in a Coral/cream flash), 11 fire 1 (recoil: kicked down 2 px, sparks). |
|11 | `face.png`        | 24x24  | 9      | 216x24   | Snouty head-on, Doom-face style: 0 healthy, 1 hurt (HP < 60: bruise, plaster, worried brows), 2 critical (HP < 25: bandage, heavy lids, sweat), 3 ouch (eyes squeezed, mouth open), 4 grin (pickup: happy squint, grin), 5 glance left, 6 glance right (pupils only), 7 rewind (eyes spiralling), 8 dead (X eyes, tongue out). Same head position in all nine. |
|12 | `hud.png`         | 8x8    | 9      | 72x8     | 0-2 keys Coral/Iris/Gold (drawn lit, the code dims missing ones), 3 zapper charge icon, 4 spray icon, 5 clock, 6 `<<` (rewind), 7 heart, 8 Debugger ammo (red dot in a small grey box). 1 px border. |
|13 | `title.png`       | 128x40 | 1      | 128x40   | Logo lettering "SNOUTENSTEIN" over a big "3D", chunky 16-bit logo style, Snouty purples with cream highlights, "3D" in Coral, Iris marks optional. Transparent background; the code writes "PRESS A" and the "powered by deterministic replay" tag line itself. |

## 8. Delivery format (per study, mirrors Run Study 05)

For each numbered study (start at Study 01, a revision is Study 02, and so on):

```
Snoutenstein_Study_NN/
  README.md                  what changed, per-sheet palettes, anchors, notes
  sheets/<name>.png          RGBA strips exactly as in section 7 (alpha 0/255;
                             walls and doors fully opaque)
  sheets/<name>_indexed.png  same strip as an indexed PNG, index 0 transparent
  frames/<name>_NN.png       individual cells
  contact_sheet.png          every sheet at 4x nearest-neighbour, cells numbered
  walls_tiled.png            each wall texture tiled 3x3 at 4x (seam check)
  preview.gif                enemies walking, weapons firing, at 4x
  mockup.png                 one 160x128 view as the game will look (corridor
                             of walls, a door, 3 enemies, a pickup, weapon,
                             status bar with face and icons), and at 4x.
                             Review starts here.
  assets.json                per sheet: {"cell": [w, h], "frames": N,
                             "palette": [hex...], "names": [...]}
  palette_<sheet>.gpl        GIMP palette per sheet
  validate.py                alpha binary, colour limits per sheet, sizes,
                             empty borders, no #FF00FF, wall tiling
```

The repo imports it with
`python3 tools/prepare_assets.py --study assets/Snoutenstein_Study_NN --contact docs/placeholders.png`,
which re-checks everything in this brief (sizes, colour limits after
RGB565, borders and their two exceptions, tiling, binary alpha, no
magenta) and refuses a sheet that fails. Ask for a mockup with rough shapes
first, before all sheets are drawn, so the sizes can be approved at badge
scale.

## 9. What not to do

- No copyrighted sprites or recognisable references: no Wolfenstein
  textures, no Doom face, no BJ, no swastikas or eagles. Original art in
  the era's style.
- No text baked into sprites except the title logo and the EXIT sign.
  The game renders all other text with its 8x8 font.
- No rotation frames, no side views of enemies, no perspective in the wall
  textures (they are flat surfaces, the raycaster does the perspective).
- No semi-transparency, glow or blur. Draw a glow as a lighter 1 px rim.
- No gore. Bugs die like cartoons.
- No gutters, padding rows or multi-row sheets. One strip per file,
  exact sizes.
- No 64x64 drawings scaled down to 32x32.

## 10. Notes from the M1 placeholder pass (2026-09-26)

Found while drawing the stand-ins. The code and `tools/prepare_assets.py`
follow these values.

- One palette for all eight walls: the converter builds one palette per
  PNG, so `walls.png` shares 16 colours across all eight textures. The
  master palette has no mid grey between `#42364b` and `#958d9d`, and metal
  needs one, so steel `#6d6a86` is in. The placeholder uses all 16
  entries. `doors.png` uses 15 (three key ramps plus steel and teal).
- Vertical tiling is a consistency rule. The renderer never stacks a
  texture vertically (a wall is exactly one texture tall). Horizontal
  tiling happens on every straight wall. The import check therefore
  treats a seam as fine when it is no sharper than the texture's own
  sharpest edge. Bevelled panels pass. A sign cut at the edge would not.
- Spider thread: the brief's 1 px border rule would cut the thread off the
  ceiling, so column x 15 is exempt at the top (cell centre is 15.5; a
  1 px thread cannot be centred in 32 px).
- Weapons: the arm must reach the bottom edge. With the ±2 px bob in
  SPEC.md section 4, the code should draw the weapon before the status
  bar so the bottom rows can sink under it, and never lift it so far that a
  gap opens below the sleeve.
- Boss at 1.5x: if the boss stands on the floor, 48 texels is 1.5 wall
  heights, so the top third rises above the ceiling line of nearby
  walls. The placeholder keeps the top rows to antennae and the "?"
  shield. The M3 renderer decides whether to allow that or to sink the boss.
- Sprite anchors are not in SPEC.md yet. Section 4 above proposes them
  (enemies floor to ceiling, pickups half-height standing on the floor,
  projectiles centred at mid-height). The M2 sprite pass should confirm or
  change them here.
- `pickups.png` cell 7 was a "spare" coffee mug until M6; it is now the
  Debugger cartridge (`PickupKind.debugger = 7`, legend `&`). The order of
  cells 0-7 matches `levels.zig` `PickupKind`.
- Colour budgets at the limit in the placeholders: `bug_boss.png` 15/15,
  `pickups.png` 15/15 (three 3-colour key ramps cost 7 entries alone),
  `weapons.png` 15/15 (paw purples, sleeve, four weapons). Real art will
  have to share ramps. `hud.png` 14/15. The M6 Debugger cells add no
  colours: they reuse red `#ee453c`, dark red `#91322f`, Coral, cream,
  steel and the greys already in each sheet (`projectiles.png` goes from
  5 to 8 opaque colours, the others are unchanged).
- The converter quantises with `floor(v * 31 / 255)` (f32), not `v >> 3`.
  They differ for some values, so near-identical colours can land on
  different sides. The validator counts both ways and uses the larger count.
- Death 1 and 2 in the placeholders are death 0 flipped and squashed by
  code. Real art should draw them properly. The wasp's flip in particular
  reads poorly.
- The face's 1 px transparent border leaves 22x22 for the head. The head
  and ears fill it, and the shirt collar shows along the bottom.
- Doors have no jamb texture. Wolf3D drew a special texture on the side
  walls of a door cell. Here the door's side walls show the neighbouring
  wall. If that looks wrong on hardware, a jamb texture would be wall 9
  (cell values 9..63 are reserved for more wall textures).
