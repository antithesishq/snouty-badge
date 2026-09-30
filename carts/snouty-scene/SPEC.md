# Snouty Scene: a demoscene production for the SYCL Badge V2

Status: spec, 2026-09-30. Supersedes `NOTES.md` (kept for the history of
the idea). Working title "Snouty Scene"; the on-screen title is
**SNOUTY SCENE** with "Antithesis presents" above it.

## 1. What it is

A non-interactive demo of about two minutes: a sequence of classic
real-time effects ("parts"), each 8 to 14 seconds, cut on a fixed 120 BPM
frame clock, with fades between parts, a sine scroller of greetings, and
an ending on the Iris mark reflected in water. It loops forever, which is
the booth mode. The attendee can:

- press **A** or **Start** to skip to the next part,
- press **Select** to open the **part picker** (a list of the parts; up and
  down move, A jumps to that part, Select or B closes) so someone at the
  booth can show the one they like,
- with `-Ddebug_overlay=true`, press **B** to toggle a timing overlay
  (render microseconds, part index, frame in part).

Nothing else. No neopixels (`docs/NEOPIXELS.md`), **no audio at all**
(Adrian, 2026-09-30: the speaker is not worth development time; the
NOTES.md tracker idea is dropped, the beat lives on as a frame clock so
cuts still feel musical). The OS owns Start+Select (exit) and the stick
click (fps overlay); the cart never binds either.

Everything on screen is a pure function of the frame number within the
current part plus the part's `enter()` state, so a preview run, a
badge-bench run and the badge show the same frames, and the picker is free.

## 2. Hardware facts the design rests on

- 160x128 RGB565 at 60 Hz, 16.7 ms per frame. Column-major framebuffer
  `cart.framebuffer[x][y]` of `cart.Pixel` (a `u16`; `Pixel.from_color`
  byte-swaps on wasm, so palettes are built through it, never as raw
  bit patterns).
- Cortex-M33 at 150 MHz with a single-precision FPU (add/mul 1 cycle,
  div and sqrt about 14). `f64` is soft-float and never appears in the
  cart (`zig build check-float`). Fixed-point `i32`/`u32` for the
  per-pixel inner loops (they must match bit-for-bit between wasm and
  thumb); `f32` is fine for per-frame and per-row set-up.
- Cart RAM is 307 KB for code, data, bss and stack together
  (`cart_ram.ld`); the two framebuffers are the OS's. Budget for this
  cart: `.text` + `.rodata` under 110 KB, `.bss` under 190 KB (raised from
  150 KB at M1: the tunnel's 200x168 sway window costs 67 KB and the
  measured total, 78 KB text + 169 KB bss, leaves 60 KB for the stack;
  the fallback if RAM gets tight is fixed-centre 160x128 tunnel LUTs,
  27 KB less). RAM cart, no XIP.
- 2.5 M cycles per frame at 60 Hz. The perf rule is the monorepo's:
  **every part's worst frame under 12 ms in calibrated badge-bench** (72%
  of budget), so a demo never drops a frame. Half-resolution render
  (80x64 indices upscaled 2x through a palette) is the standard escape
  hatch and is how the expensive parts were done on 1990s hardware.

## 3. The parts and the timeline

The frame clock is 120 BPM: 30 frames per beat, 120 frames per 2-second
bar. Part lengths are whole bars. Each entry has a `cut`, its hand-over to
the next part, applied by the timeline, not by the parts: `.fade` (5
frames of black, then a 20-frame fade, on each side of the bar line;
`fx.fade`), `.dissolve` (the same timing with 4x4-pixel blocks dropping
out in 8x8 Bayer order; `fx.dissolve`) or `.seamless` (no veil either
side: the Ending's last frame is the Intro's first). Skipping or the
picker cuts to a part's frame 0, which then fades in.

| # | Part | Bars | Seconds | Cut out | What it shows | Method |
|---|---|---|---|---|---|---|
| 0 | Intro | 3 | 6 | fade | Starfield warp, "Antithesis presents", **SNOUTY SCENE** slams in | 3D star points, 8x8 text at 2x |
| 1 | Plasma | 5 | 10 | fade | Sum-of-sines plasma cycling through three palettes | 8-bit index field at half res, 2x upscale, palette rotates |
| 2 | Copper + scroller | 6 | 12 | dissolve | Copper bars behind a 16-row sine scroller of greetings | per-row colour bars, per-column glyph blit with sine y offset |
| 3 | Rotozoomer | 5 | 10 | fade | The Snouty sprite tiled to infinity, rotating and zooming | fixed-point affine step per pixel, 32x32 texture, `& 31` wrap |
| 4 | Twister | 4 | 8 | fade | A twisted four-faced column, shaded, over a moving gradient | per-row: 4 edge positions from sin, fill spans |
| 5 | Tunnel | 4 | 8 | fade | Flying down a tunnel textured with Iris marks | angle/depth LUTs at init (u8 each), texture scroll per frame |
| 6 | Metaballs | 5 | 10 | fade | Five blobs merging and splitting, warm then cool | half-res field sum with a 1/r^2 LUT, threshold + palette, 2x |
| 7 | Voxel landscape | 7 | 14 | dissolve | Comanche-style fly-over of a Green Hill Zone island | 128x128 height + colour maps (procedural at init), column ray-march |
| 8 | Snouty head | 5 | 10 | fade | A flat-shaded low-poly Snouty head tumbling, lit | scanline triangle fill with a z-sorted (painter's) face list, no z buffer |
| 9 | Fire | 4 | 8 | fade | The classic cooling-map fire with the Iris mark floating in it | 80x64 heat buffer, spread + cool + rise, palette, 2x |
| 10 | Ending | 7 | 14 | seamless | The Iris mark rising over a night sea, reflected in rippling water, credits | 2D reflection with per-row sine displacement (not the ray tracer), text |

Total 55 bars = 110 s, then loop to part 0 (M2 pacing pass: order and
lengths changed from the M1 table, reasons in PLAN.md's M2 section). The
Intro is also where the loop closes, so the title comes back every two
minutes.

Design intent per part is in the module's doc comment; the palette and
pacing decisions are reviewed on the M2 GIF (section 9 risk 1).

## 4. Part interface

Each part is one file in `cart/src/parts/`, exposing exactly:

```zig
pub const name: []const u8 = "Plasma";   // picker label, at most 14 chars
pub fn init() void {}                      // once, from start(): LUTs into this module's own globals
pub fn enter() void {}                     // when the timeline enters the part: reset all mutable state
pub fn render(t: u32, fb: cart.FramebufferPtr) void; // t = frames since enter(); writes every pixel
```

Rules:

- `render` is deterministic in `t` and the state `enter()` set. A part
  may keep state across frames (fire needs its heat buffer) but `enter()`
  resets it, so jumping to a part from the picker or the loop always
  shows the same sequence.
- A part writes **every pixel** of `fb` (no reliance on the previous
  frame's contents: the OS double-buffers).
- No allocation, no `f64`, no `std.fmt`, no `cart.tone2`, no neopixels.
- Sine and cosine only through `math.sin_turns`/`cos_turns` (table) or
  the integer `math.isin` (1024-entry i16 table, for fixed-point loops).
- Randomness only through `rng.zig` seeded with a constant inside
  `enter()`; never `cart.rand()` (it would break determinism).
- Heavy tables are computed at `init()` into the module's globals
  (Mac comptime OOM rule: no big comptime loops), or generated on the
  host and committed under `cart/src/gen/`.

`timeline.zig` holds the ordered table of `{ part, bars }` and drives
`enter`/`render`, the fades, skipping and the picker's jumps. `Part` is a
struct of function pointers plus the name, built with `Part.of(module)`.

## 5. Shared modules

- `math.zig`: copied from snouty-maze (f32 sine table in turns, fract,
  lerp, smoothstep, Angle u16) plus `isin(a: u32) i32` (a in 0..1023,
  result in -32767..32767) and `iatan2`-free helpers.
- `palette.zig`: `Palette = [256]cart.Pixel`; builders `gradient(keys)`
  (piecewise-linear through RGB888 key colours), `rotate(pal, n)`,
  `lerp(a, b, t)`; all evaluated at `init()` or per frame, never at
  comptime.
- `fx.zig`: `upscale2x(indices: *const [80][64]u8, pal, fb)`,
  `fade(fb, level 0..16)` (multiplies every pixel, level 16 = unchanged,
  0 = black), `clear(fb, pixel)`, `blit_text2x` (8x8 font at 2x via
  `cart.text` into a scratch or by run-length rects).
- `text.zig`: 8x8 font wrapper for hints, credits and the picker
  (`cart.text` with a background colour).
- `rng.zig`: xorshift32 (copied from snouty-maze).
- `gen/scroller_font.zig` (committed, generated by `tools/gen_font.py`
  from DejaVu Sans Bold at 16 px): 1-bit 16-row glyphs for ASCII 32..95,
  variable width, `glyph(c) -> { width, columns: []const u16 }`, so
  the scroller draws column by column.
- `gen/textures.zig` (committed, generated by `tools/gen_textures.py`
  from `assets/*.png`): `snouty: [32][32]u16` (RGB888 packed as RGB565
  bits, converted through `Pixel.from_color` at `init()` so the wasm byte
  swap is respected), `iris: [32][32]u16`, `iris_big: [64][64]u16`.
  Assets come from `snouty-art/out/maze/` (snouty.png frame 0, iris.png)
  and `snouty-art/ref/iris_mark.png` downscaled.
- `lib/iris_mark.zig` for the 24x24 Iris mark in Fire and the Ending.

## 6. Controls and states

```
running --A/Start--> next part (immediate cut, no fade-out; fade-in kept)
running --Select--> picker (demo keeps rendering underneath, dimmed by fade(8))
picker  --Up/Down--> move; --A--> jump to part, close; --Select/B--> close
running --B (debug_overlay build only)--> toggle overlay
```

Inputs are edge-triggered through `input.zig` (copied from snouty-maze).

## 7. Determinism, tests and tooling

- Wasm debug exports (`main.zig`): `debug_frame` (global frame),
  `debug_part`, `debug_part_frame`, `debug_pixel_checksum`,
  `debug_render_us`, `debug_goto(part)`, `debug_picker` (0/1).
- Badge build exports the global `scene_part: u8` so badge-bench can
  `--poke scene_part=N` to start on part N (the timeline honours it in
  `start()`); wasm has `debug_goto` for the same via `preview.mjs --call`.
- `tools/bench_parts.sh`: runs badge-bench once per part (`--poke
  scene_part=N --frames <part length + 60>`) and prints a table of
  worst frames; the table is copied into `docs/PERF.md` at each
  milestone. `badge-bench/carts/snouty-scene.toml`: the plain loop,
  `frames = 900`.
- Host tests (`cart/src/host_tests.zig`): timeline arithmetic (bars to
  frames, loop, goto), palette builders, `fx.fade` at 0 and 16, the
  scroller font (every glyph has width > 0, columns fit 16 rows), the
  integer sine.
- `tools/check_timeline.mjs`: headless run of one full loop at
  `--every 30`, asserting `debug_part` advances through every part in
  order and the checksum of each part's first frame is stable (golden
  numbers in `tests/golden.json`); produces the review GIF frames.

## 8. Milestones

- **M0 scaffold**: build registration, `main.zig`, timeline, part
  interface, shared modules, font and texture generators, parts 0 to 2
  (Intro, Plasma, Copper + scroller), picker in its simplest form (list,
  jump), bench toml, `docs/RUNNING.md`, preview GIF. Tag `snouty-scene/m0`.
- **M1 the effects**: parts 3 to 9 (Rotozoomer, Tunnel, Twister,
  Metaballs, Voxel, Snouty head, Fire), each under 12 ms worst in
  calibrated badge-bench, each with a preview GIF. Built in parallel,
  one module each. Tag `snouty-scene/m1`.
- **M2 the show**: the Ending, credits, transitions and pacing pass over
  the whole timeline, picker polish, `check_timeline.mjs` goldens,
  `docs/PERF.md`, full-loop review GIF. Tag `snouty-scene/m2`.
- **M3 polish**: whatever Adrian's GIF review asks for (palettes, order,
  lengths). Tag `snouty-scene/m3`.

Hardware gate: show day, as for every cart (calibrated badge-bench is
the reference until then).

## 9. Risks

1. Taste: pacing and palettes decide whether it reads as a demo. The M2
   full-loop GIF is the review point; M3 exists for that.
2. Voxel and Snouty head are the two parts that may not make 12 ms.
   Fallbacks: voxel at half horizontal resolution with 2-px columns and
   a shorter view distance; the head as a dodecahedron (12 faces) if a
   low-poly Snouty mesh does not read at 160x128.
3. RAM: tunnel 40 KB, voxel 32 KB, heat buffer 5 KB, index buffer 5 KB,
   palettes about 6 KB, textures 12 KB: about 100 KB plus code, inside
   the 307 KB with margin. If it grows, parts share one scratch arena.
4. The scroller font generator depends on a host TTF (DejaVu Sans Bold,
   present on the VM); the generated file is committed so nobody else
   needs it.

## 10. Decisions taken on NOTES.md section 8 (2026-09-30)

1. Length: about two minutes, looping (110 s since the M2 pacing pass). Short enough for
   a booth, long enough for ten parts.
2. Parts: the ten above (the NOTES pick plus twister, metaballs, fire
   and copper bars, which are cheap and classic).
3. Music: none (badge speaker decision). Beat is a frame clock.
4. Ships as its own cart, `snouty-scene`, binary `snouty-scene`.

Adrian can overturn any of these at the M0 or M2 review; the timeline
table makes order and length one-line changes.
