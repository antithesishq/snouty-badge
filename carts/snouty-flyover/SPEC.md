# Snouty Flyover: voxel heightfield cart (idea note)

Owner: Adrian Hatch (Antithesis). Target: SYCL Badge V2, 160x128 RGB565.
Status: idea only, not scheduled. Recorded 2026-09-30 so it is not lost;
it started as `carts/snouty-reflections/SPEC.md` section 14. Nothing here
is built and the root `build.zig` does not list this directory. Before any
work starts this becomes a full SPEC.md plus PLAN.md like the other carts.

## One paragraph

A Comanche-style ("Voxel Space", NovaLogic 1992) flight over a
mountainous landscape, drawn by casting one ray per screen column across
a 2D heightmap and filling vertical spans bottom to top with an occlusion
line per column. It is the classic way 1990s PCs drew terrain far beyond
what polygons of the day could, and it fits the badge well: the cost is
per column and per step, not per pixel, so 30 fps at full resolution is
realistic and 60 fps may be. The feat here is scale (kilometres of
terrain to the horizon, rolling hills, a lake in the valley) rather than
per-pixel cost; snouty-reflections remains the per-pixel feat.

## Rendering sketch

- Map: 256x256 `u8` heights plus 256x256 `u8` colour indices (a 256-entry
  palette with lighting baked in by the host generator: sun shading,
  ambient occlusion, shadows). 128 KB of read-only data, wrapping, so the
  flight never reaches an edge.
- Per frame: for each of 160 columns, march from the camera outwards with
  a step that grows with distance (level of detail), project each
  sample's height to a screen row, draw the span above the column's
  current occlusion row, stop at the far distance or when the column is
  full. About 160 x 250 steps x 15 to 20 cycles is roughly 5 ms, which
  leaves most of the frame for effects.
- Sky: gradient plus sun, shared idea with snouty-reflections.
- Distance fog blended toward the sky colour, through the same ordered
  dither as snouty-reflections so the fog has no bands.
- Camera: pitch by shifting the horizon row, roll by shearing the
  per-column horizon (Comanche's trick), altitude kept above the terrain
  under and ahead of the camera.

## Options that would make it more than a tech demo

- Lakes: map cells below a water level reflect. Reflect the column's ray
  in the water plane and march again (snouty-reflections' water: ripples,
  Fresnel, dither), cheapest as a second march at half the column
  resolution.
- Terrain from a host generator (fractal noise plus hydraulic erosion,
  committed as generated files; no heavy comptime, see root CLAUDE.md on
  the Mac OOM). A Vancouver/Howe Sound look would tie it to
  snouty-reflections' skyline: fjord, North Shore mountains, the Lions.
- Snouty flying (paraglider or a small plane) as a sprite in the lower
  third, banking with the stick; rings to fly through for a light game,
  or pure attract flight with the stick taking over.
- Time scrub or rewind, as in the other Snouty carts.

## Memory

128 KB of map data is over the 120 KB `.text` + `.data` budget a RAM cart
uses elsewhere in this repository. Choices: a 256x192 map (96 KB), 4-bit
colour indices packed two per byte with height, or the XIP cart mode
(`-Dcart-mode=xip`, 256 KB flash window; untested on hardware so far).
Flash reads in XIP mode are slower than RAM, so the march would need
benchmarking there.

## Open questions (for when it is scheduled)

1. Pure attract flyover, or a light game (rings, a landing)?
2. Generated terrain, a real DEM of the Vancouver area, or both?
3. Worth lakes with real reflections (shared water code) at the cost of
   frame rate?
4. RAM cart with a smaller map, or XIP with the full 256x256?
