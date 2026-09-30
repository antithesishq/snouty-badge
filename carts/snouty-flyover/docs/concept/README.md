# Memory Lane concept renders

`python3 ../../tools/concept.py --out . --stills --gif` rebuilds everything here (about 15 s): seven 160x128
stills at 4x, `montage.png` (the stills plus the palette), and `concept.gif` (90 frames at 15 fps, 2x, about 1.1 MB).
The GIF flies bus -> HEAP (the GC wall sweeps towards the camera and flattens unreferenced blocks behind it) -> bus -> PIPELINE lake.

- `heap.png`: amber allocated mesas (0xFFA030 tops, 0xE06020 sides), teal freed blocks (0x20C0B0) in a canyon down the middle with the cyan free-list chain, and the white GC wall beyond with rubble behind it.
- `sort.png`: 24 quicksort snapshots, one row per pass. Near rows are partly sorted with the white pivots of that pass; the far rows form the finished rainbow staircase.
- `tree.png`: a binary tree from 200 cells up. The root spine is at the far end, 45-degree forks come towards you, the amber search path runs from root to leaf.
- `hash.png`: magenta 10x10 buckets on a 32-cell grid, with collision chains stepping down behind them (0xA030A0 and dimmer) and cyan insert lanes from the strip edge; the amber rehash seam and the denser, half-height table are behind.
- `stack.png`: inside the call-stack canyon: red terraced frames (0x501020 -> 0xFF4040, 8 cells each, pale lips), plateau 90, floor stepping down to 10 and back up, the return signal on the floor.
- `pipeline.png`: skimming the lake 8 cells above the water, with the channels, dams and springs beyond. The Iris sun and the skyline reflect upside down.
- `bus.png`: on the 32-wide raised bus (0x202848, 4 dash lanes, cyan/amber, alternating direction) looking at the HEAP skyline.

Renderer parameters: screen 160x128; FOV tan 0.8 (about 77 degrees), projection scale 100; view 280 cells; steps start at 1.0 and grow x1.007 (about 160 steps);
face = height jump > 2 cells along the ray (walls facing -y use the side entry; walls facing +-x use side mixed 35% toward top); fog from z=60 to 280, curve f^1.4, 8 levels,
4x4 Bayer between levels, colour 0x3A2258, glowing indices fogged at half strength; reflection = second march to 200 cells with h' = 2w - h, per-row ripple
on the mirrored slope, water tint 0x0C2C66, grazing Fresnel 0.45..0.9. Output is quantised to RGB565; the sky is Bayer-dithered before quantising.
Cameras: GIF altitude follows the terrain (max ahead + 26, +10 over water), horizon row 52, slalom +-3 cells with roll from yaw rate (max 0.25 rad).
Floor 28 +-6 (value noise), water 16, cache-line grid every 64 cells. Sky 0x06040F -> 0x2A1A5E -> warm band 0x7A3A2A; Iris sun 66 px, centre 20 px above the horizon, core 0xFFB040.

Palette layout (256 entries; the cart copies this):
- 0-15: noise floor, 0x141833..0x1E2450. 16-19: grid, 0x283060..0x34407A. 20-23: GC rubble. 24-27: water (24 = 0x1050A0, only 24 is written to the map). 28-30: spare. 31: white (GC wall).
- 32-47: pulse A comet, cyan 0x40E0FF -> head 0xE8FFFF, rotates 1 index per frame. 48-63: pulse A dash, rotates 2 per frame.
- 64-79: pulse B comet, amber 0xFFB040 -> head 0xFFF4D0, rotates 1 per frame. 80-95: pulse B dash, rotates 2 per frame.
- 96-255: district (top, side) pairs, top at the even index (112 of 160 entries used). A path cell is `base + distance % 16`, so rotating the range moves the pulse.
- Each pulse range has one fixed wall colour (A comet teal 0x0E6A64, B comet tree green 0x1C7040, dashes road 0x121830), not a darker pulse.

What looked bad and what changed:
- Walls striped in the pulse colour. A ray sample that lands on a path cell inside a ridge draws the whole wall in that cell's colour. Fix: each pulse range got a fixed wall colour, the heap free list only paints cells lower than 20 above the floor, and the tree path only paints inside a ridge (this also removed the grey/cyan stripe at the left edge of HEAP).
- TREE read as green walls. With heights 96..36, the fronts of the ridges filled the screen and the tops were slivers. The tree is now low (30, 24, 19, 15, 12, 10 above the floor, ridges 12..4 wide), built leaves-first so heights rise away from the camera, and seen from far above.
- SORT with 256 bars of 1 cell was confetti beyond 40 cells, so it uses 64 bars of 4 cells.
- A low sun could not reflect: the far shore blocked it. The lake is now 110 rows (the brief said about 80), it sits at the near end of the district (springs at the far end), and the still is taken low.
- HASH at 16-cell spacing was a pink forest, so buckets are now 10x10 on a 32-cell grid. It is still dense, because the view wraps the 256-wide strip.
- Near fog dither showed as dots on big walls, so fog now starts at 60 cells.
