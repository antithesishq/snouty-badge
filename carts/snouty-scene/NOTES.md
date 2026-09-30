# Snouty Scene: demoscene cart notes

Status: notes only (2026-09-30). Not a spec, not scheduled. "Snouty
Scene" is a working title. From the reflection on what is left: a classic
demoscene production for the badge. Low risk (no ROMs, no hardware we
have not used, every effect is a pure function of the frame number), high
sparkle, and the badge is exactly the class of machine the scene
celebrates: fixed screen, fixed clock, small memory, one speaker.

## 1. What it is

A non-interactive demo of about 2 to 3 minutes: a sequence of effects,
each 8 to 20 seconds, cut on the beat of a one-voice chiptune, with
transitions, a sine scroller of greetings, and an ending on the Iris mark.
A or Start skips to the next part; Select opens a part picker so people at
the booth can jump to the one they want to see. It loops.

The badge is 160x128 RGB565 at 60 Hz with a 16.7 ms frame; every part must
hold 60 fps in badge-bench with headroom (perf policy), because a demo
that drops frames is not a demo.

## 2. Parts (candidates, pick 8 to 10)

Classics, in rough order of how well they suit 160x128:

- **Plasma**: sum of sines through a palette LUT. Trivial, gorgeous,
  good opener.
- **Rotozoomer**: a tiled texture rotated and scaled per frame; fixed-point
  affine stepping, two adds per pixel. Texture: the Snouty sprite sheet
  from `snouty-art`, so the mascot rotates by the thousand.
- **Tunnel**: precomputed angle and depth LUTs (160x128x2 bytes each,
  40 KB total, computed at init into RAM), texture scroll per frame. Iris
  rings as the texture.
- **Twister**: a twisted column with 4 shaded faces, one line per row.
- **Metaballs**: 4 to 6 blobs, field summed per pixel at half resolution
  and upscaled 2x, threshold plus palette.
- **Voxel landscape** (Comanche-style heightmap fly-over): column
  ray-march over a 256x256 height and color map. The most "impressive"
  one and the most expensive; the Snoutenstein and Reflections work says
  we can budget it. Fly over a Green Hill Zone heightmap.
- **Flat-shaded 3D object**: the Snouty Maze rasterizer drawing a
  dodecahedron or a low-poly Snouty head, with a lit color ramp.
- **Copper bars and raster bars** behind the scroller.
- **Fire** (the classic cooling-map fire) under the Iris mark.
- **Particle fountain / starfield warp** as a transition device.
- **Ending**: the Iris mark from `lib/iris_mark.zig`, reflected in water
  using the Reflections ray marcher at its cut20 settings. Credits.

Rule: each part is a module with `init(seed)`, `render(frame, fb)` and a
cost recorded in badge-bench. Parts never keep state across frames beyond
what `frame` implies; that keeps the whole demo deterministic and makes the
part picker free.

## 3. Music

Badge V2 has one tone2 voice with a shape (square, triangle, sawtooth,
sine, major and minor chords). One-channel tracker tricks apply:
arpeggios for chords (or the built-in major/minor shapes as a cheat), fast
alternation between bass and lead, noise-free drums as short pitch drops.
A tiny pattern format (note, shape, length) in a comptime-free table,
driven by a 60 Hz tick so the beat is a frame count and parts can sync to
it exactly. The web simulator tone shim caveat applies (drive `tone`
directly). If the OS PCM path ever lands, the tracker becomes a real
4-channel mixer; keep the pattern data channel-agnostic so that upgrade
does not rewrite the song.

Sound respects the per-cart sound flag from `docs/SOUND.md` once decided.

## 4. Text and design

- The 8x8 font from the API for hints, a custom 16-row sine scroller font
  drawn by a host generator (Mac comptime OOM rule: generate on the host,
  embed bytes).
- Greetings: SYCL and the badge team, the Zig community, Antithesis. No
  neopixels (off by decision).
- Palette LUTs are 256-entry RGB565 tables generated at init.

## 5. Determinism and tooling

The demo is `render(frame)`, so a preview run is exactly the badge run:
`tools/preview.mjs` can dump every 60th frame to PNGs and `make_gif.py`
produces the review GIF from the same build. badge-bench gets a hot-part
table (one entry per part, worst frame) instead of a game input script.
This is also the simplest cart to use as the deterministic-replay proof
(same framebuffer hash on wasm, badge-bench and hardware) since it has no
inputs at all.

## 6. Budget and memory

- Flash: code plus textures and font, under 100 KB. RAM cart is fine;
  no XIP needed.
- RAM: LUTs computed at init (tunnel 40 KB, palette tables, heightmap
  64 KB + 64 KB color if the voxel part stays at 256x256; consider
  128x128 maps at 32 KB). Framebuffer double buffer as usual.
- Per-part worst frame must be under about 12 ms in calibrated
  badge-bench. Half-resolution render plus 2x upscale is the standard
  escape hatch for the expensive parts (metaballs, voxel).
- FPU is available (M33); fixed-point stays the default for anything that
  must match bit-for-bit in the wasm build, floats are fine for
  render-only math, as Snoutenstein's rules say.

## 7. Risks

- Taste: a demo lives or dies on pacing and palette, not on the effect
  count. Plan a GIF review round of the timeline before polishing parts.
- The voxel part might not fit at full resolution; half resolution is the
  fallback and is how it was done on real 1990s hardware anyway.
- One tone voice makes the music thin; the built-in chord shapes help,
  and a clear percussive pattern matters more than harmony here.

## 8. Open questions for Adrian

1. Length and loop: 2 to 3 minutes as a booth loop, or a shorter 60 s
   piece for attention spans?
2. Which parts are must-haves? (My pick: plasma, rotozoomer, tunnel,
   voxel landscape, 3D Snouty head, scroller, Iris-on-water ending.)
3. Music: write our own or adapt a public-domain tune?
4. Does this ship as its own cart or as an attract loop stitched into an
   existing one?

## 9. Milestone sketch

- M0 scaffold: part interface, timeline, tracker tick, three cheap parts
  (plasma, copper bars, scroller), preview GIF, badge-bench entry.
- M1 the expensive parts (tunnel, rotozoomer, voxel, 3D object) each with
  a badge-bench number.
- M2 music, transitions, part picker, Iris ending, timeline review.
- M3 polish pass from the GIF review; ship.
