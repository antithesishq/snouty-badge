<!-- Forked from snouty-zero/ASSETS.md at f8f6962. -->
# Snouty GC engine assets

The engine half of the cart's art: what M0 forked from Snouty Zero. The
racers' own art (portraits, the six car sets, weapons, pickups, effects) is
the art track's: `tools/draw_art.py` into `assets/gen/art/`, described in
`ASSETS.md`. M1 wires those sheets in and retires the placeholders below.

## The engine's sprite sheets (Zero's, copied)

`assets/gen/shadow.png` and `exhaust.png` are Zero's sheets copied byte
for byte (drawn by `carts/snouty-zero/tools/prepare_assets.py`, not
forked). Since M1 (Track B) the cart uses them as:

- `shadow.png`: under every car (checkerboard skip).
- `exhaust.png` (Zero's `fx.png`, renamed because the art track's
  `art/fx.png` owns the `gfx.fx` name): only the BURST flame, frames 4
  and 5. Its sparks (0..3) are superseded by the art's.

M1 retired `machine.png` (the M0 re-paletted placeholder cars: the art
track's `car_<racer>.png` replaced them) and `snouty_head.png` (the
placeholder splash: the eyepatched portrait replaced it). The manifest
below is Zero's and still names them.

### Manifest (Zero ASSETS.md)

All sheets are RGB PNGs, one row of equal cells, 4 bits per pixel in the
`gfx` module (`build.zig` `images`), `transparent = true`.

| File | Size | Cell | Frames |
|---|---|---|---|
| `shadow.png` | 32x6 | 32x6 | 0 the ellipse (one colour, 0x101014) |
| `machine.png` | 160x16 | 32x16 | 0 rear, 1 rear-quarter left (nose turned 45 degrees toward screen-left; we see the left side and the rear), 2 rear-quarter right, 3 side left (nose points screen-left), 4 side right |
| `fx.png` | 96x16 | 16x16 | 0..3 spark burst (white flash, expanding white/yellow rays, yellow/coral, fading coral), 4 exhaust flame small, 5 exhaust flame large (cyan/white, round end up, tail pointing down) |
| `snouty_head.png` | 24x8 | 12x8 | 0 normal, 1 hit (eye squeezed shut, tongue out); profile facing right, for the HUD |

Placement rules:

- **Borders.** Every cell keeps a 1 px transparent border, except that the
  machine cells sit on their **bottom row** (skids or hull on
  the floor; place the cell's bottom row on the floor row), and the shadow
  fills its cell.
- **Horizontal anchor.** Each machine cell is centred on its own
  silhouette, so put the cell's centre column on the car's screen x.
  Measured extents (cell-relative x, y): machine 0: x 5..26 y 3..15;
  1, 2: x 3..29 y 2..15; 3, 4: x 4..28 y 2..15.
- **Effects** are centred on (7.5, 7.5) in their cells (sparks) or hang from
  the top (flames: put the flame's top under a thruster).

### Colour conventions (Zero ASSETS.md)

- **Key.** `#FF00FF` is transparent; `convert_gfx` puts it at palette index 0
  of every sheet. No opaque pixel quantises onto it.
- **Index order.** The converter assigns the other indices in first-seen
  pixel order (row-major over the whole sheet), so indices change whenever a
  sheet is redrawn. Never hard-code an index; match colours by value.
- **Machine body ramp.** The rival/traffic body uses exactly these four RGB
  values, dark to light, and no other pixel of any sheet uses them (the
  validator checks this, also after quantisation):

  | RGB | after `convert_gfx` (r5, g6, b5) | `DisplayColor.rgb()` of the same value |
  |---|---|---|
  | `0x3C3C50` | 7, 14, 9 | 7, 15, 10 |
  | `0x6A6A8C` | 12, 26, 17 | 13, 26, 17 |
  | `0x9A9AC0` | 18, 38, 23 | 19, 38, 24 |
  | `0xD0D0F0` | 25, 51, 29 | 26, 52, 30 |

  The converter quantises with `floor(31 * v / 255)` / `floor(63 * v / 255)`,
  while `DisplayColor.rgb()` truncates (`v >> 3`, `v >> 2`). They differ for
  these values, so the per-rival recolour must compare `gfx.machine.colors`
  entries against the middle column (or compute the converter's formula),
  not against `DisplayColor.rgb(0x3C3C50)`. In today's sheet the body
  entries are `gfx.machine.colors[6, 7, 2, 5]` (dark to light), but find
  them by value at start-up.
- **Machine non-body colours.** Outline and skids `0x141018`, canopy
  `0x203C50`, canopy glint `0x8CE8F0`, thruster glow `0x4FD6E8`, thruster
  core `0xE8FCFF`.
- **Snouty head.** study05 outline `0x17121E`, fur as above, eye
  `0xF4EFDF`, glasses `0x958D9D`, tongue `0xF18271`.
- **Shadow.** `0x101014`; the cart draws it with a checkerboard skip for
  translucency.

### Colour counts (opaque, after RGB565, max 15)

| Sheet | Colours |
|---|---|
| `shadow.png` | 1 |
| `machine.png` | 9 |
| `fx.png` | 7 |
| `snouty_head.png` | 7 |

## The floor: the Dumps league

The floor art is generated, not drawn: `tools/build_tracks.py` with the
league painters in `tools/leagues.py` writes `assets/gen/dumps_tiles.bin`
(128 tiles of 8x8 at 8 bpp, 8 KB; SPEC 13.2), `dumps_pal.bin` (52 colours,
entry 0 the smog fog colour) and `dumps_horizon.bin` (front layer: heaps of
monitors with lit screens, entry 15 blinking; back layer: a smog sky, a low
sun and smoke columns), plus Landfill Loop's map, attributes and
centerline. Formats in `PLAN.md`; the tile index list is
`docs/dumps_tiles.txt`, the contact sheet `docs/dumps_tiles.png`, the
horizon `docs/dumps_horizon.png`, the whole map `docs/landfill_loop_preview.png`.

Looks: CRT-glass sand with glints, shards, keys, cables and board scrap,
2x2 scrap heaps and monitors off the track; the road is flattened circuit
boards (green, with a 16 px trace rhythm, solder-pad lane dots and scattered
cable ruts); wreckage walls with a yellow and black hazard face; open edges
are a crumbling lip into a black pit; a teal coolant puddle band, a ramp
plate, a checker start line and lit sector seams.
