# Snouty GC: assets

## Art (M0 Track B)

Every sheet in `assets/gen/art/` is drawn by one command from the
repository root:

```
python3 carts/snouty-gc/tools/draw_art.py
```

It needs Python 3 and Pillow only, and it is deterministic: two runs give
byte-identical PNGs. The script validates every sheet and exits non-zero
on a violation, and it does not write a failing sheet. The checks are:
size, at most 15 opaque colours after the converter's RGB565 cut, no
opaque colour that collapses onto the key, no empty cells, and no key
pixels in the opaque portraits. The code lives in `tools/draw_art.py`
(manifest, validation, review images) and `tools/art/`: `raster.py` (the
canvas, stamps, outline, spherical shading, the 3x5 and 8x8 fonts),
`portraits.py`, `cars.py` (a pure-Python port of Zero's ray caster) and
`items.py`. The art policy applies: code-drawn art counts as final.

The script also writes two review images:

- `docs/art_contact.png`: every sheet at 3x on a checkerboard, labelled,
  with cell dividers, plus the six portraits at half scale (24x24
  nearest), the size used in the race taunt pop-up.
- `docs/art_select_mock.png`: a 160x128 mock of the racer select (SPEC
  8.1) for each of the six racers, at 3x. The text is the cart's real
  8x8 font (`carts/snouty-zero/assets/gen/font.bin`, bit 7 = leftmost
  pixel, checked by rendering). The mock has the portrait at top left,
  the name and car to its right, the car's rear-quarter view on a
  plinth, SPD/ARM/DMG bars, the front weapon (A) and the rear weapon
  (down arrow + A), the 4-line bio, and `< A PICK >`, with everything
  kept 4 px clear of the edges. The stat values are mock values: SPD and
  ARM come from the chassis, and DMG is a guess at the loadout.

### Format (all sheets)

- RGB PNGs. `#FF00FF` is the transparent key (palette index 0 when
  `transparent = true`). Each sheet has its own palette of at most 15
  opaque colours, so a sheet works at `bits = 4` with or without the key.
- A sheet is a horizontal strip of equal cells, as Zero's `machine.png`
  is. Frame `i` starts at `x = i * cell_w`.
- No sheet depends on exact colour values at run time. Unlike Zero's
  `machine.png`, nothing is recoloured by matching colours: every car has
  its own sheet and palette.

### Sheets

| File | Cell | Cells | Bytes at 4 bpp | Notes |
|---|---|---|---|---|
| `portrait_snouty.png` ... `portrait_botnet.png` | 48x48 | 1 each | 1,152 each | opaque, own palette each (13-15 colours) |
| `car_<racer>.png` (6) | 32x16 | 5 each | 1,280 each | own palette each (9-13 colours) |
| `weapons.png` | 8x8 | 11 | 352 | |
| `decals.png` | 16x8 | 7 | 448 | flat, drawn as seen from above |
| `pickups.png` | 16x16 | 20 | 2,560 | 15 colours |
| `fx.png` | 24x24 | 11 | 3,168 | |
| `claw.png` | 24x32 | 2 | 768 | |
| `hud.png` | 12x12 | 10 | 720 | |

The art totals about 22.6 KB of `.rodata` (portraits 6.9 KB, cars 7.7
KB, the rest 8.0 KB), against SPEC 13.2's 7 + 9 + 8 = 24 KB.

#### Portraits: `portrait_<racer>.png`, 48x48, one per racer

They are in SPEC 4.1 order: `snouty`, `legacy`, `kiddie`, `sysadmin`,
`rootkit`, `botnet`. Each is a single 48x48 cell with an opaque backdrop
in the racer's colour, so at half scale it reads as a comm window over
the race view. There is one sheet per portrait because each needs its
own 15 colours. All six were checked at 1:1 and at 24x24 nearest, at
both sample phases (even and odd pixels). Blit them opaque
(`transparent = false`), which also skips the key test.

- **SNOUTY**: the study05 rig's head and torso parts
  (`snouty-art/styles/study05/parts/head.png`, `torso.png`, composited at
  their rig positions and cropped), in the study05 palette. Code-drawn
  layers on top: a black **eyepatch** with a sheen over the near eye, the
  **strap** running back under the ear and up across the brow (clipped
  to the head), a pink **scar** with stitches running out from under the
  patch, and the far eye in what is left of his glasses lens, narrowed
  to a **squint** under a heavy lid. The backdrop is a smog-orange sky
  over a skyline of dead monitors (the Dumps). He faces right, toward
  the name on the select screen, so the patch is on the eye nearest the
  viewer, stage left of the face. In the car sprite the patch is on his
  left side.
- **LEGACY**: a battered fedora with a **punch card** (cream, slotted)
  tucked in the hat band, thick **bifocals** with the reading line
  across each lens and magnified, heavy-lidded eyes, bushy white brows
  slanting down into a scowl, a bulbous nose, a big grey **beard** with
  a frown under the moustache, a cardigan, and a pocket protector with
  pens. The backdrop is a green-screen terminal full of old code.
- **KIDDIE**: spiky hair, brass **welding goggles** pushed up on the
  forehead, wide eyes with raised brows, freckles, a big open grin with
  a **gap in the front teeth**, a lime hoodie with drawstrings, and a
  **thumbs-up** with a plaster on the short finger ("9 OF 10 FINGERS").
  The backdrop is teal forum-banner stripes.
- **SYSADMIN**: a messy bun with a **pencil** through it, a **headset**
  (band, ear cups, mic boom at the mouth), half-lidded eyes over dark
  **eye bags**, a flat done-with-it mouth, a red **flannel** shirt, and
  a white **mug with a skull** on it, steaming. The backdrop is two
  server racks with blinking green and amber LEDs.
- **ROOTKIT**: a pointed **hood in full shadow** over cloak shoulders,
  with a void for a face, the light-side rim of the opening picked out,
  **two green eyes** with bright cores, and a lopsided **smirk** with a
  single glinting tooth. The drawstrings have metal tips. The backdrop
  is falling green code.
- **BOTNET**: **four cousins** crammed into one frame (two back, two
  front, overlapping), with the same family face and big family nose
  and **mismatched hats**: a red beanie with a pompom (blank stare), a
  yellow hard hat (**asleep**, mouth open, `Zz` in the corner), a
  **tinfoil** cone (shifty eyes, wavy mouth) and a propeller cap (big
  grin). The backdrop is the bus interior and its window posts.

#### Cars: `car_<racer>.png`, 160x16, 5 cells of 32x16

| Cell | View |
|---|---|
| 0 | rear: driving straight away from the camera |
| 1 | rear quarter: nose turned 45 degrees to screen **right** |
| 2 | side: nose to screen **right** |
| 3 | wreck: upside down, charred palette, embers (the burning hulk; add `fx.png` flames and smoke on top) |
| 4 | airborne: rear view, nose up 3 degrees, wheels hanging on extended suspension (the renderer lifts it) |

Mirror cells 1 and 2 for a nose to screen left. Drawings are
bottom-aligned, so the wheels sit on the cell's bottom row, and centred
horizontally: anchor the sprite at bottom-centre, as Zero does. The
models are ray-cast with Zero's camera, 26 degrees look-down and light
from the upper left, at one world scale (9.5 px per model unit), so the
MAINFRAMEs are visibly bigger than the THIN CLIENTs. A view that would
overflow 32x16 is shrunk in quarter steps. Three frames are affected:
ANTEATER's wreck is 5% smaller, and the two mainframes' rear quarter
views are 3% smaller.

| Sheet | Racer, car, chassis | Look | Minimap colour (suggested) |
|---|---|---|---|
| `car_snouty.png` | SNOUTY, ANTEATER, WORKSTATION | Zero's Anteater colours (tan, cream, coral waterline), the giant anteater's dark shoulder band as a chevron, a long **snout ram prow** with a dark nose, and **Snouty** (purple, ears, the eyepatch strap round his head, the patch on his left) in the open cockpit | `#8E42DE` |
| `car_legacy.png` | LEGACY, BIG IRON, MAINFRAME | IBM blue slab armour, a beige band, roof vents, **two tape reels** on the tail, and a barred **cow-catcher plough** | `#4A7AD0` |
| `car_kiddie.png` | KIDDIE, CTRL-V, THIN CLIENT | lime dune buggy plastered in pink, yellow and cream **stickers**, a big yellow **spoiler** on struts, a roll hoop, and KIDDIE's hair and goggles band in the cage | `#7CD040` |
| `car_sysadmin.png` | SYSADMIN, UPTIME, WORKSTATION | flannel red, a closed canopy, and a **rack of blinking LEDs** (green and amber) bolted to the rear deck | `#E04040` |
| `car_rootkit.png` | ROOTKIT, PERSIST, THIN CLIENT | **matte black**, where only the green lights show: tail lights, headlights, an underglow strip, and two green eyes in the driver's hood | `#40F070` |
| `car_botnet.png` | BOTNET, ZOMBIE, MAINFRAME | a **patched school bus** (yellow, black stripe, grey and rust patches) with **heads in the windows**: three hatted heads in the rear window and a row along each side, a spare tyre and salvage on the roof, and a small plough | `#F0C030` |

The minimap colours are a suggestion for the M1 HUD. They are not in
any sheet, and they are distinct on purpose (purple, blue, lime, red,
green, yellow).

#### `weapons.png`: 88x8, 11 cells of 8x8 (projectiles and world objects)

| Cell | Name | What |
|---|---|---|
| 0 | ping | PING pellet: a bright cyan blip (draw two side by side for the twin shot) |
| 1 | broadcast | BROADCAST pellet: an orange spark, one per pellet of the fan |
| 2 | phish_rear | SPEAR PHISH from behind: round body, tail fins, exhaust |
| 3 | phish_side | SPEAR PHISH side, nose right: a silver fish, spear tip forward, exhaust at the tail |
| 4 | phish_quarter | SPEAR PHISH three-quarter, nose up-right |
| 5 | logic_bomb | LOGIC BOMB armed: a mine marked `if`, red light on |
| 6 | logic_bomb_off | LOGIC BOMB blink frame, light off (alternate 5/6 once armed) |
| 7 | fork_bomb | FORK BOMB child: a round bomb with `&`, fuse lit |
| 8 | kernel_panic | KERNEL PANIC packet: a blue packet with `:(` |
| 9 | ddos_drone | DDOS drone: a 4x4 red quad, centred in the cell |
| 10 | duck | RUBBER DUCK on its tether: side view facing right, outlined |

Pick the SPEAR PHISH view from the missile's heading relative to the
camera, as for the cars (mirror cells 3 and 4 for the left).

#### `decals.png`: 112x8, 7 cells of 16x8 (flat, top-down)

Draw these with SPEC 10's squashed blit: full width, height times the
squash factor.

| Cell | Name | What |
|---|---|---|
| 0 | leak_a | MEMORY LEAK puddle: green ooze with leaked bits |
| 1 | leak_b | MEMORY LEAK shimmer frame (alternate 0/1 every 8 to 16 ticks; scale with the radius 6 to 18) |
| 2 | bitrot | BIT ROT caltrop: a rusted jack (one per caltrop, 6 across the lane) |
| 3 | spaghetti | SPAGHETTI CODE tangle: yellow cable loops |
| 4 | firewall_base | FIREWALL base: a strip of bricks (a firewall, literally); tile it along the 64 px wall, flames from `fx.png` on top |
| 5 | chip | CYCLE chip: a little CPU, worth 10 CYCLES |
| 6 | scorch | scorch mark, left under a wreck or a LOGIC BOMB blast |

#### `pickups.png`: 320x16, 20 cells of 16x16 (HUD box icons and crates)

The pickup icons follow SPEC 6.3 order, so `pickup id == cell` if the
cart numbers pickups in table order:

| Cell | Pickup | Icon |
|---|---|---|
| 0 | PREFETCH | a cyan fast-forward double chevron |
| 1 | HONEYPOT | a honey pot, honey running over the rim |
| 2 | RUBBER DUCK | a rubber duck |
| 3 | HOT PATCH | a plaster with a red cross, glowing hot |
| 4 | SPAGHETTI CODE | spaghetti with a meatball, on a plate |
| 5 | FORK BOMB | a black bomb marked `&`, fuse lit |
| 6 | BIT FLIP | a cosmic-ray bolt striking `0 1` |
| 7 | DEADLOCK | a padlock chained to both sides |
| 8 | DDOS | red packet drones closing on a target |
| 9 | HEISENBUG | a purple bug drawn on alternate rows only (you can't quite observe it) |
| 10 | RACE CONDITION | two crossing arrows, cyan and orange: swap places |
| 11 | KERNEL PANIC | a blue screen showing `:(` on a monitor stand |
| 12 | CAPTCHA | a 3x3 picture grid with traffic lights in three squares and a green tick |
| 13 | SUDO | root's `#` under a crown |
| 14 | ZERO-DAY | a calendar page reading `0` (a slashed zero) |
| 15 | PROMPT INJECTION | a syringe of green fluid stuck into a `>_` prompt |
| 16 | roulette blank | three dots (`FETCHING...`); show it between rolls or when empty |
| 17 | RMA crate | the crate (3/4 view, a white `RMA` label); also the world sprite |
| 18 | HONEYPOT crate | the fake crate: the same, with the label one shade off (cream) |
| 19 | HONEYPOT crate, `?` frame | the fake with an orange `?` on the label: alternate 18/19 on odd frames |

#### `fx.png`: 264x24, 11 cells of 24x24

| Cell | What |
|---|---|
| 0-3 | explosion: flash, fireball, burning smoke, dying smoke with embers (about 4 ticks each) |
| 4, 5 | smoke puff, small and big (grey puffs below 50% armour; the dark ring reads as black smoke) |
| 6, 7 | spark burst, two frames (wall hits, `ACK` hits) |
| 8 | muzzle flash, pointing up the screen (forward from a car seen from behind) |
| 9, 10 | FIREWALL flame tongues, two frames; the flame's foot is on row 22 |

#### `claw.png`: 48x32, 2 cells of 24x32

| Cell | What |
|---|---|
| 0 | GC claw, open: cable from the top, a hazard-striped hoist block with a red light, three prongs |
| 1 | GC claw, closed (holding: draw it over the collected car's sprite, then lift both) |

#### `hud.png`: 120x12, 10 cells of 12x12

| Cell | Name | What |
|---|---|---|
| 0 | reticle | SPEAR PHISH reticle, searching: a grey fish hook |
| 1 | reticle_lock | locked: a red hook in corner brackets |
| 2 | reticle_lock2 | locked, pulse frame: brackets pulled in (alternate 1/2) |
| 3 | burst_pip | BURST charge: a cyan bolt |
| 4 | ammo_pip | rear ammo pip |
| 5 | ack | `ACK` in green, popped over a car you hit |
| 6 | panic_tag | KERNEL PANIC `:(` screen over a frozen car |
| 7 | sudo_tag | SUDO `#` over a rooted car |
| 8 | captcha_tag | the CAPTCHA grid over a stopped car |
| 9 | honey_tag | an orange `?` (for any marker that wants one) |

The SPEC 10 drawn-in-code items stay in code: the blue screen, the
CAPTCHA mini-game grid, `MARKED`, `BEHIND` and the kill feed (all text
in the 8x8 font), the beams and the chains.

### What M1 must wire into `build.zig`

Append these to the cart's `images` list (the converter is Zero's
per-cart `convert_gfx`, and paths are relative to `assets/gen/`). Each
becomes `gfx.<stem>`, for example `gfx.portrait_snouty`, `gfx.car_kiddie`
or `gfx.pickups`:

```zig
    // art track (tools/draw_art.py); see ASSETS.md
    .{ .file = "art/portrait_snouty.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_legacy.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_kiddie.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_sysadmin.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_rootkit.png", .bits = 4, .transparent = false },
    .{ .file = "art/portrait_botnet.png", .bits = 4, .transparent = false },
    .{ .file = "art/car_snouty.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_legacy.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_kiddie.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_sysadmin.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_rootkit.png", .bits = 4, .transparent = true },
    .{ .file = "art/car_botnet.png", .bits = 4, .transparent = true },
    .{ .file = "art/weapons.png", .bits = 4, .transparent = true },
    .{ .file = "art/decals.png", .bits = 4, .transparent = true },
    .{ .file = "art/pickups.png", .bits = 4, .transparent = true },
    .{ .file = "art/fx.png", .bits = 4, .transparent = true },
    .{ .file = "art/claw.png", .bits = 4, .transparent = true },
    .{ .file = "art/hud.png", .bits = 4, .transparent = true },
```

Notes for the wiring:

- The stems do not clash with Zero's (`machine`, `fx`, `anteater` ...)
  unless the fork keeps Zero's `fx.png` too. If it does, drop Zero's
  `fx.png` from the list, because `art/fx.png` replaces it (its sparks
  and exhaust flames are superseded), or rename one of them.
- A racer's assets are indexed by `racer` (0..5, SPEC 4.1 order), so a
  `[6]` table of `gfx.portrait_*` and one of `gfx.car_*` in
  `racers.zig` is all the select, results, HUD and sprite code need.
- The cars replace the placeholder Zero `machine.png` liveries from M0.
  Zero's `shadow.png` still works under them (32x6).
- Portraits are opaque. To blit one at half scale, sample every other
  pixel; both phases were checked.

### Proposed roster text changes (for the lead to apply to SPEC 4.1)

All six bios fit 4 lines of 19 characters as drafted, and the mock
renders them in the cart's font. One line is tightened, keeping the
joke:

| Racer | SPEC 4.1 draft | Proposed |
|---|---|---|
| SYSADMIN | NO SLEEP SINCE THE / AIS CAME ONLINE. / RUNS ON SPITE AND / RECYCLED COFFEE. | NO SLEEP SINCE THE / **MACHINES WOKE UP.** / RUNS ON SPITE AND / RECYCLED COFFEE. |

The reason: in an all-caps 8x8 font, `AIS` reads as a word ("ais")
rather than the plural of AI. The other five bios are unchanged and
appear in the mock exactly as in SPEC 4.1.
