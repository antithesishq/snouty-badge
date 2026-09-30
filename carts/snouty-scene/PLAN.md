# Snouty Scene: plan

`SPEC.md` is the design; this file is the contract for the milestone in
progress. Worktree `/home/exedev/snouty-badge-scene`, branch `scene/m0`
(M1 parts get `scene/m1-<part>` branches from the m0 tag and are merged
back). Every milestone ends with: `zig build -Dcart=snouty-scene`, `zig
build test`, `zig build check-float`, badge-bench numbers, a preview GIF
in `docs/`, an annotated tag `snouty-scene/mN`, and a "pull and run this"
section in the hand-off message.

## M0 scaffold (2026-09-30) — DONE, tag `snouty-scene/m0`

Status: built and benched 2026-09-30 (six commits). Eleven timeline
entries (0 Intro .. 10 Ending, as SPEC section 3), placeholders for parts
3 to 10. Worst frame 2.45 ms (Intro fade-out), `.text` 39.7 KB, `.bss`
28.5 KB, 22 host tests. Numbers in `docs/PERF.md`, GIF `docs/preview_m0.gif`.
`preview.mjs` needs `--raw-colors` to show badge colours.

Goal: the cart exists, loops through Intro, Plasma and Copper + scroller
with fades, A skips, Select opens a picker, badge-bench runs it, and the
preview GIF shows all three parts.

### Tracks

**Track A, scaffold and first parts** (one agent). Owns:

- `carts/snouty-scene/build.zig` (module `pub fn add`, modelled on
  `carts/snouty-maze/build.zig` without the asset converter: no build-time
  generation, the `gen/` files are committed), the root `build.zig`
  `carts` table entry `.{ .dir = "snouty-scene", .binary = "snouty-scene", ... }`,
  the root `README.md` table row, `badge-bench/carts/snouty-scene.toml`
  (`budget_ms = 16.7`, `frames = 900`).
- `cart/src/main.zig`: `start()` (vsync 60, `no_copy_full_frame`, every
  part's `init()`, `timeline.start(scene_part)`), `update()` (input,
  picker, timeline step, render, fades, overlay, `present_wasm`), the
  wasm debug exports of SPEC section 7, the badge export `scene_part`,
  `read_controls`, `present_wasm` (copy from snouty-maze).
- `cart/src/timeline.zig`: `Part` (name + fn pointers, `Part.of(module)`),
  the `entries` table `{ part, bars }` for the ten parts of SPEC section
  3 (parts not yet written point at `parts/placeholder.zig`, which draws
  its index as a big digit on a dark gradient so the timeline is complete
  from M0), bars-to-frames, `step()`, `skip()`, `goto(i)`, fade level
  per frame (15 out, 15 in), loop.
- `cart/src/picker.zig`: the list overlay (8x8 font, highlighted row,
  up/down/A/Select/B) drawn over the dimmed frame.
- `cart/src/input.zig`, `cart/src/rng.zig` (copies from snouty-maze),
  `cart/src/math.zig` (copy plus `isin`: `pub fn isin(a: u32) i32`, table
  of 1024 `i16` filled at `init()` from `sin_turns`, `icos`),
  `cart/src/palette.zig`, `cart/src/fx.zig`, `cart/src/text.zig`,
  `cart/src/overlay.zig` (timing overlay, from snouty-reflections).
- `cart/src/parts/intro.zig`, `cart/src/parts/plasma.zig`,
  `cart/src/parts/placeholder.zig`.
- `cart/src/host_tests.zig` and the tests of SPEC section 7 that concern
  these modules.
- `docs/RUNNING.md` (from snouty-maze's, adapted), `tools/bench_parts.sh`.
- Integrates Track B's `parts/copper.zig` and `gen/*.zig` when they land
  (they are in the same worktree; fix compile errors there if needed and
  say so in the report).

**Track B, generators and the scroller** (one agent). Owns:

- `assets/snouty.png` (32x32, frame 0 of `snouty-art/out/maze/snouty.png`),
  `assets/iris.png` (32x32 from `snouty-art/out/maze/iris.png`),
  `assets/iris_big.png` (64x64 from `snouty-art/ref/iris_mark.png`,
  flattened on black), committed.
- `tools/gen_textures.py` (Pillow) -> `cart/src/gen/textures.zig`,
  committed: `pub const snouty: [32][32]u16`, `iris: [32][32]u16`,
  `iris_big: [64][64]u16`, values are RGB565 bit patterns
  `(r5 << 11) | (g6 << 5) | b5`, indexed `[y][x]`, with a doc comment
  telling the reader to convert through `cart.Pixel.from_color(@bitCast(v))`
  at `init()`.
- `tools/gen_font.py` (Pillow, DejaVu Sans Bold 16 px on the VM) ->
  `cart/src/gen/scroller_font.zig`, committed: ASCII 32..95 (space,
  punctuation, digits, upper case), 16 rows, variable width (1 px
  spacing baked in, space 6 px), as
  `pub const Glyph = struct { width: u8, columns: []const u16 };`
  `pub fn glyph(c: u8) Glyph` (unknown chars map to '?'), bit 0 of a
  column is the top row. Under 8 KB of data.
- `cart/src/parts/copper.zig`: copper bars (six sine-moving horizontal
  bars with a bright core and dark edges, over a dark blue background,
  drawn per row) and the sine scroller: a greetings string moving right
  to left at 2 px per frame, each glyph column drawn at
  `y = 56 + 24 * sin(...)` with a 3-px black drop shadow, 16 rows tall,
  colour cycling along the string. Text: "SNOUTY SCENE  *  ANTITHESIS
  PRESENTS A SYCL BADGE PRODUCTION  *  GREETINGS TO THE SYCL CREW, THE
  ZIG COMMUNITY AND EVERYONE AT THE BOOTH  *  " (looping). Follows the
  part interface of SPEC section 4 exactly; imports only `cart-api`,
  `../math.zig`, `../fx.zig`, `../gen/scroller_font.zig`.
- Host tests for the font (`zig test` on the generated file with a
  separate `--cache-dir`; Track A wires them into `host_tests.zig`).

Track B does not run `zig build` (Track A owns the build in this
worktree); it checks its Zig files with `zig fmt --check` and `zig test`
on the standalone files.

### Interfaces (fixed for both tracks)

```zig
// parts/<name>.zig
const cart = @import("cart-api");
pub const name: []const u8 = "Copper";
pub fn init() void {}
pub fn enter() void {}
pub fn render(t: u32, fb: cart.FramebufferPtr) void { ... }

// math.zig additions
pub fn init_tables() void;             // fills the isin table; main.start() calls it first
pub fn isin(a: u32) i32;               // a & 1023 -> sin in -32767..32767
pub fn icos(a: u32) i32;

// palette.zig
pub const Palette = [256]cart.Pixel;
pub const Key = struct { pos: u8, rgb: u32 };            // 0x00RRGGBB
pub fn gradient(keys: []const Key) Palette;              // keys sorted by pos, first 0, last 255
pub fn rotate(p: *const Palette, n: u8) Palette;
pub fn lerp(a: *const Palette, b: *const Palette, t: u8) Palette; // t 0..255

// fx.zig
pub const Indices = [80][64]u8;                          // column-major like the framebuffer
pub fn upscale2x(src: *const Indices, pal: *const Palette, fb: cart.FramebufferPtr) void;
pub fn fade(fb: cart.FramebufferPtr, level: u8) void;    // 16 = unchanged, 0 = black
pub fn clear(fb: cart.FramebufferPtr, px: cart.Pixel) void;
pub fn hline(fb: cart.FramebufferPtr, y: u8, px: cart.Pixel) void;
pub fn text2x(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void; // 8x8 font doubled
```

Framebuffer indexing is `fb[x][y]`, x in 0..159, y in 0..127, `y` the
fast axis in memory: inner loops go down a column.

### Definition of done (M0)

- `zig build -Dcart=snouty-scene` from the root writes the uf2, elf and
  wasm; `zig build test` and `zig build check-float` pass.
- `node tools/preview.mjs zig-out/bin/snouty-scene.wasm --frames 1800
  --every 6 --out carts/snouty-scene/out/m0` runs without a trap;
  `docs/preview_m0.gif` made from it shows Intro, Plasma and Copper with
  fades, then the placeholder digits.
- `preview.mjs --press A:100-101 --at "150 debug_part == 1"` and
  `--call debug_goto:2 --at "0 debug_part == 2"` pass.
- `badge-bench/bench.sh zig-out/firmware/snouty-scene.elf --frames 900
  --every 60 --symbols`: worst frame of Intro, Plasma and Copper under
  12 ms busy; numbers recorded in `docs/PERF.md`.
- ELF `.text` under 60 KB at M0 (there is room for the seven M1 parts).

## M1 the effects (next)

Seven parts, each one module and one agent, in worktrees
`/home/exedev/snouty-badge-scene-<part>` on branches `scene/m1-<part>`
from tag `snouty-scene/m0`: rotozoomer, tunnel, twister, metaballs,
voxel, head, fire. Each agent replaces the placeholder in the timeline
entry for its part, proves its worst frame under 12 ms with
`tools/bench_parts.sh <index>`, writes `docs/preview_<part>.gif`, and
reports RAM (`.bss` delta) and the numbers. Merge order: cheapest first.
Contract details are in SPEC.md sections 3 to 5; the agent brief adds
per-part parameters.

## M2 the show

Ending part, credits, pacing and palette pass, picker polish,
`tools/check_timeline.mjs` with goldens, `docs/PERF.md` table, full-loop
GIF. Single agent plus review.
