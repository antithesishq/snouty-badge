# Snouty Zero assets

The sprite sheets in `assets/gen/*.png` are code-drawn by
`tools/prepare_assets.py`. Per the art policy (root `CLAUDE.md`) this
placeholder art counts as final unless Adrian swaps a sheet. The track data
(`assets/gen/*.bin`) is a separate pipeline: `tools/build_tracks.py`, formats
in `PLAN.md`.

## Regenerating

```sh
python3 tools/prepare_assets.py      # from carts/snouty-zero/
```

It draws every sheet, validates it against the manifest (exact size, cell
grid, at most 15 opaque colours after the converter's RGB565 cut, key
usage, cell borders, floor row, the four machine body colours) and writes
`docs/sprites_contact.png` (every sheet at 4x plus a 1x/2x mockup on a floor
colour; `--contact PATH` writes it elsewhere). A failing sheet is not
written and the exit status is non-zero. Output is deterministic (fixed
seeds, no time input). Then rebuild: `zig build -Dcart=snouty-zero` from the
repository root.

How the machines are made: each is a small 3D model of ellipsoids and
convex slabs ray-cast orthographically at one sample per pixel (camera
looking down `CAM_PITCH` = 26 degrees, the same for both sheets), Lambert
shading quantised onto fixed colour ramps, then a 1 px outline at the
silhouette and at depth steps. The rival yaws and the Anteater leans are
views of one model, so they read as the same vehicle turning. The Snouty
head (`snouty_head.png`) and the effects are drawn directly.

## Manifest

All sheets are RGB PNGs, one row of equal cells, 4 bits per pixel in the
`gfx` module (`build.zig` `images`), `transparent = true`.

| File | Size | Cell | Frames |
|---|---|---|---|
| `anteater.png` | 160x24 | 40x24 | 0 straight, 1 lean left (banked into a left turn, nose yawed 8 degrees left), 2 lean right, 3 hop (nose dipped 10 degrees, skids folded, cyan hover pads showing underneath) |
| `shadow.png` | 32x6 | 32x6 | 0 the ellipse (one colour, 0x101014) |
| `machine.png` | 160x16 | 32x16 | 0 rear, 1 rear-quarter left (nose turned 45 degrees toward screen-left; we see the left side and the rear), 2 rear-quarter right, 3 side left (nose points screen-left), 4 side right |
| `fx.png` | 96x16 | 16x16 | 0..3 spark burst (white flash, expanding white/yellow rays, yellow/coral, fading coral), 4 exhaust flame small, 5 exhaust flame large (cyan/white, round end up, tail pointing down) |
| `snouty_head.png` | 24x8 | 12x8 | 0 normal, 1 hit (eye squeezed shut, tongue out); profile facing right, for the HUD |

Placement rules:

- **Borders.** Every cell keeps a 1 px transparent border, except that the
  Anteater and machine cells sit on their **bottom row** (skids or hull on
  the floor; place the cell's bottom row on the floor row), and the shadow
  fills its cell.
- **Horizontal anchor.** Each Anteater and machine cell is centred on its
  own silhouette, so put the cell's centre column on the machine's screen x.
  Measured extents (cell-relative x, y): Anteater 0: x 7..32 y 2..23;
  1 and 2: x 7..33 y 1..23; 3: x 7..32 y 6..23. Machine 0: x 5..26 y 3..15;
  1, 2: x 3..29 y 2..15; 3, 4: x 4..28 y 2..15.
- **Effects** are centred on (7.5, 7.5) in their cells (sparks) or hang from
  the top (flames: put the flame's top under a thruster).
- **Snouty in the cockpit** is baked into every Anteater frame (we see the
  back of his purple head and ears through the canopy glass). The hit
  head in `snouty_head.png` is a profile for the HUD, not an overlay for
  the cockpit.

## Colour conventions

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
- **Anteater.** Outline `0x241C22`; body `0x7E6E5A` / `0xB4A48C` /
  `0xECE2CC` (the flyover anteater's tan and cream); shoulder band and
  thruster cones `0x3A3038`; coral accents `0xF18271` / `0xA8504A`; thruster
  and hover-pad glow `0x4FD6E8` / `0xE8FCFF`; canopy glass `0x1E3446`;
  Snouty's fur `0x662BB8` / `0x8E42DE` / `0xBE7AF3` (study05 FUR_DARK, FUR,
  FUR_LIGHT).
- **Snouty head.** study05 outline `0x17121E`, fur as above, eye
  `0xF4EFDF`, glasses `0x958D9D`, tongue `0xF18271`.
- **Shadow.** `0x101014`; the cart draws it with a checkerboard skip for
  translucency.

## Colour counts (opaque, after RGB565, max 15)

| Sheet | Colours |
|---|---|
| `anteater.png` | 13 |
| `shadow.png` | 1 |
| `machine.png` | 9 |
| `fx.png` | 7 |
| `snouty_head.png` | 7 |
