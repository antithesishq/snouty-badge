# Snouty GCP track packs (`.GCP`)

A track pack is one file, `NAME.GCP` (a FAT 8.3 name), copied onto the
badge's USB drive next to the emulator ROMs (SPEC 19). It holds one league:
its palette, tileset, horizon and props sheet, one to four race tracks and
at most one BATTLE arena. Packs are data only (SPEC decision 15): they place
the hazard kinds the cart already runs, with their own numbers and art.

The cart side is `cart/src/pack_format.zig` (this layout as Zig, the
version, the checks) and `cart/src/pack.zig` (the drive scan, the loader).
`tools/build_pack.py` writes packs. The test pack
`cart/src/gen/packs/TEST.GCP` (from `tools/test_pack/`) is the Dumps art
with Landfill Loop and The Sandbox, to prove the path.

## Copying a pack onto a badge

1. Plug the badge into a computer with USB. Its drive (`SYCLBADGE`) mounts
   like a USB stick.
2. Copy the `.GCP` file into the drive's top folder (not a sub-folder),
   for example `assets/packs/dead_mall/DEADMALL.GCP`. Keep the 8.3 name.
3. Eject the drive properly before unplugging (an unflushed copy is a
   damaged pack), then start Snouty GCP.
4. Open QUICK RACE (or GARBAGE COLLECTION): the track row lists the
   built-in tracks first, then each pack's tracks with the pack's league
   name. A pack arena shows in BATTLE's arena row after THE SANDBOX.
   CIRCUIT stays built-in only.
5. A bad file is listed with a reason and cannot be picked: `PACK
   DAMAGED` (CRC or a section fails its checks), `NOT A PACK` (no `GCPK`
   magic), `PACK TOO NEW` (a format version this cart does not know),
   `PACK TOO BIG` (over the 128 KB cap), `NEEDS NEWER CART` (a hazard kind
   this cart does not run), `RECOPY PACK` (the file is split over the
   drive: see RAM below). Copy it again or rebuild it.

Link play: both badges need the same pack (same name and CRC). The host
cannot pick a pack track its partner lacks: its rules row reads `PARTNER
LACKS PACK`.

Up to 8 `.GCP` files are listed; the drive holds 1,280 KB, and a pack is
about 40 to 80 KB.

## Pack source layout (what `tools/build_pack.py` reads)

A pack is built from a directory, by convention `assets/packs/<pack>/`
(Track B's packs) or `tools/test_pack/` (the test pack):

```
<dir>/pack.toml           the manifest (below)
<dir>/pal.bin             512 B: 256 x u16 RGB565, entry 0 the fog colour   (build_tracks.py <league>_pal.bin)
<dir>/tiles.bin           128 tiles x 64 B, packed like a map            (<league>_tiles.bin)
<dir>/horizon.bin         12,352 B packed: front 512x32 4bpp, back 256x32 4bpp,
                          front pal 16 x u16, back pal 16 x u16          (<league>_horizon.bin)
<dir>/attr.bin            128 B: one attribute per tile index            (<league>_attr.bin)
<dir>/<id>_map.bin        per track and arena: the packed 128x128 map    (<track>_map.bin)
<dir>/<id>_center.bin     256 samples x 6 B                              (<track>_center.bin)
<dir>/<id>_feat.bin       hazard records, 20 B each (may be empty)        (<track>_feat.bin)
<dir>/<id>_arena.bin      the arena only: the arena blob                  (sandbox_arena.bin)
<dir>/props.png           the props sheet (optional; below)
```

Every `.bin` is exactly the file `tools/build_tracks.py` /
`tools/build_arena.py` writes for a built-in league, track or arena, so a
pack's generator runs the built-in rasterizer (a per-pack `LEAGUES`
entry: palette, tile painter or tiles from PNG, background, horizon) and
writes its files into the pack directory. `build_pack.py` only packages
them: it checks them as the cart will, adds the props, the directory, the
header and the CRC.

`pack.toml`:

```toml
file = "DEADMALL"            # the 8.3 base name: DEADMALL.GCP (A-Z 0-9 _ -, 1..8)
name = "DEAD MALL"           # the pack's name in menus, <= 16 characters
league = "DEAD MALL"         # the league name under each track, <= 16

[props]                      # optional; no section, no props
sheet = "props.png"
cell = [32, 48]              # cell width (even, <= 32) and height (<= 48)
count = 8                    # cells, left to right then top to bottom, <= 16

[[track]]                    # 1 to 4, in menu order
id = "anchor_store"          # the file stem: anchor_store_map.bin, ...
name = "ANCHOR STORE"        # <= 16 characters
laps = 3                     # 1..9, default 3
props = [                    # optional: [cell, x, y, radius], world px
  [0, 412, 220, 6],          #   the prop's foot at (x, y); radius > 0 is a
  [3, 430, 236, 0],          #   solid circle (a wall), 0 is decoration
]

[[arena]]                    # 0 or 1
id = "food_court"
name = "THE FOOD COURT"
props = []
```

Names are printable ASCII (the cart font has all of it); `build_pack.py`
upper-cases them, and the cart shows any other byte as `?`.

### Tiles

Packs keep the shared 128-tile index layout of `tools/leagues.py`, so the
rasterizer and the cart read every tile index the same way in every
league (edges, walls, ramps, start and sector seams, pads, kickers, jumps,
the hazard fittings, pits). A pack's tileset is 128 tiles: 256-tile
tilesets do not fit the shared 8 KB slot and are refused. Fixed slots a
pack must not repurpose: 16..27, 32..88, 92..120 (and 1..15 are its
background). Pinned for M7:

| Tiles | Use | Attribute |
|---|---|---|
| 121 | breakable crust, intact | 12 `crust` |
| 122 | crust, cracked (about to break) | 12 `crust` |
| 123 | crust, broken (looks like a pit) | 12 `crust` |
| 28..31, 89..91, 124..127 | free: the pack's own floors | the pack's `attr.bin` |

A map places only tile 121 for crust; the cart swaps 121, 122 and 123 in
its RAM copy of the map as a crust region cracks, breaks and heals, and
the sim reads only the attribute and the World, so a link race stays in
sync whatever each badge draws.

### Props sheet

`props.png`: cells of `cell` px in a grid, left to right then top to
bottom, `count` of them. At most 15 colours plus the transparent key
`#FF00FF` (an indexed PNG may instead keep index 0 as transparent and its
own order). The cell is drawn as a billboard standing on its foot (the
bottom centre), scaled like a car (a 24 px car sprite is a car's length),
through the cars' depth-sorted blit; props count against the 64-object
sprite cap, farthest dropped first. A solid prop is a circle of `radius`
px at its foot that acts as a wall for cars.

A crossing mover may use a props cell as its sprite (below); then it has
no separate hazards sheet.

## Hazards

The kinds a pack may use (SPEC 19.4), set in its `feat.bin` records and
attributes; the header's hazard mask lists them and the cart refuses a
pack with a kind it does not run.

| Kind | Mask bit | Where | Parameters |
|---|---|---|---|
| timed blast | 1 | feat kind 1 | build_tracks.py `vent`: mouth, lane, width, period, on, warn, phase, damage, push |
| crossing mover | 2 | feat kind 2 | `sweeper`: ends A and B, speed, size, period, warn, phase, damage, push; sprite: feat byte 0 bits 4..7 = props cell + 1 (0: the cart's Sweeper) |
| turret | 3 | feat kind 3 | reserved: this cart refuses it (`NEEDS NEWER CART`) |
| breakable crust | 4 | feat kind 4 + tiles 121..123 | below |
| slick | 5 | attribute 4 `coolant` | grip 0.97 (any tile with that attribute) |
| pit | 6 | attribute 0 `off` | a fall (a wreck), as an open edge or a ramp gap |

A feat record (20 B, little endian, as `track.zig` `hazard_record`): kind
u8, warn u8, size u8, damage u8, x0 y0 x1 y1 u16, period u16, on u16,
phase u16, push u8, speed u8 (1/32 px/tick). Up to 4 per track.

**Crust record** (kind 4): `x0, y0` to `x1, y1` is the region's rectangle
in world px (x1, y1 exclusive; whole tiles); `warn` the ticks from the
first touch of a car on the ground (its centre on a crust tile of the
region) to the break, while the cracked tile shows; `period` the ticks it
stays broken (300 is a good value), then it heals. While broken, a car on
the ground whose four footprint corners are all on broken crust (or off
the track) falls, as into a pit (a wreck; kill credit as for a pit).
Airborne cars never touch it. size, damage, on, phase, push and speed
are 0.

`warn` must let the car that cracked the region get off it: at least
(band depth along the travel + 24 px of car) / its slowest speed there,
in px per tick. A 16 px band crossed at 1.7 px/tick needs 24 ticks; use
24 or more (Track B's packs and the test pack use 24; 12 let the cracking
car fall through its own crack, PLAN L131).

## Binary format, version 1

Little endian. Offsets are from the start of the file; every section
starts on a 4-byte boundary.

**Header** (64 B at 0):

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `GCPK` |
| 4 | 1 | format version: 1 |
| 5 | 1 | header bytes: 64 |
| 6 | 1 | race tracks, 1..4 |
| 7 | 1 | arenas, 0..1 |
| 8 | 1 | hazard mask (bits above; 0 and 7 are zero) |
| 9 | 1 | props cell width (even, 2..32; 0 = no props) |
| 10 | 1 | props cell height (1..48) |
| 11 | 1 | props cells (0..16) |
| 12 | 16 | pack name, ASCII, space padded |
| 28 | 16 | league name, ASCII, space padded |
| 44 | 4 | file size in bytes |
| 48 | 4 | CRC-32 (zlib's) of bytes 64 .. file size |
| 52 | 12 | zero |

**League block** (64 B at 64): six sections, each offset u32 then length
u32: palette (512), tiles (packed, unpacks to 8,192), horizon (packed,
unpacks to 12,352), attributes (128), props cells (cells x w x h / 2: each
cell row-major at 4 bpp, the left pixel in the low nibble), props palette
(32: 16 x RGB565, entry 0 unused: transparent). Then 16 zero bytes.

**Track records** (64 B each from 128: the race tracks, then the arena):

| Offset | Size | Field |
|---|---|---|
| 0 | 16 | name, space padded |
| 16 | 1 | laps (race 1..9, arena 0) |
| 17 | 1 | kind: 0 race, 1 arena |
| 18 | 2 | zero |
| 20 | 40 | five sections (offset u32, length u32): map (packed, unpacks to 16,384), centerline (1,536), feat (n x 20, n <= 4), arena blob (arena only, else 0, 0), props (n x 6, n <= 24) |
| 60 | 4 | zero |

A **props record** (6 B): cell u8, radius u8 (0 decoration, else a solid
circle of that many px), x u16, y u16 (world px, the foot).

The **arena blob** is `track.zig` `parse_arena`'s (tools/build_arena.py).

### What the cart checks (`pack_format.zig`)

At the scan (menu open): the magic (`NOT A PACK`), the version (`PACK
TOO NEW`), the header (counts, cell size, reserved bytes zero, the file
size equal to the directory entry's) and every section's bounds and
length (`PACK DAMAGED`), the size cap of 128 KB (`PACK TOO BIG`), the
hazard mask (`NEEDS NEWER CART`); then
the CRC in the background, a few KB a frame (`PACK DAMAGED`). A pack is
pickable once its CRC is in. At load: each packed stream must decode to
exactly its size without reading past its section, tile indices under
128, the centerline sane (sample 0 on a start tile, each sample on
drivable floor except over a ramp gap, consecutive samples under 48 px
apart, half widths 8..120), feat kinds in the mask, props cells under the
count, the arena blob parses, the in-place sections each in one run of
clusters (`RECOPY PACK`). A pack that fails any of these is refused
with its message and the menu stays on the built-in tracks; nothing in a
pack can crash the cart.

### RAM

A pack loads into the slots the built-in leagues use: the tiles into the
8 KB tile slot, the horizon into the 12 KB horizon slot, the map into the
16 KB map buffer (the floor loop reads those per pixel, so they are always
in RAM). Every other section (the palette, attributes, centerline, feat,
props records, the arena blob, the props cells and their palette) is read
in place from the drive's flash window, as the emulator carts read their
ROMs: RAM is short (PLAN M7, L100). So each of those sections must lie in
one run of drive clusters. A file copied onto a drive with gaps (files
deleted earlier) can be split; the cart then refuses it with `RECOPY PACK`
(delete it, empty the drive's trash, copy it again, or copy it onto a
freshly emptied drive). There is no per-track RAM budget for props.
