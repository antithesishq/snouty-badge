# Demosnout: plan

`SPEC.md` is the design; this file is the contract for the milestone in
progress. Worktree `/home/exedev/snouty-badge-scene`, branch `scene/m0`
(M1 parts get `scene/m1-<part>` branches from the m0 tag and are merged
back). Every milestone ends with: `zig build -Dcart=demosnout`, `zig
build test`, `zig build check-float`, badge-bench numbers, a preview GIF
in `docs/`, an annotated tag `demosnout/mN`, and a "pull and run this"
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

- `carts/demosnout/build.zig` (module `pub fn add`, modelled on
  `carts/snouty-maze/build.zig` without the asset converter: no build-time
  generation, the `gen/` files are committed), the root `build.zig`
  `carts` table entry `.{ .dir = "demosnout", .binary = "demosnout", ... }`,
  the root `README.md` table row, `badge-bench/carts/demosnout.toml`
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
  colour cycling along the string. Text: "DEMOSNOUT  *  ANTITHESIS
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

- `zig build -Dcart=demosnout` from the root writes the uf2, elf and
  wasm; `zig build test` and `zig build check-float` pass.
- `node tools/preview.mjs zig-out/bin/demosnout.wasm --frames 1800
  --every 6 --out carts/demosnout/out/m0` runs without a trap;
  `docs/preview_m0.gif` made from it shows Intro, Plasma and Copper with
  fades, then the placeholder digits.
- `preview.mjs --press A:100-101 --at "150 debug_part == 1"` and
  `--call debug_goto:2 --at "0 debug_part == 2"` pass.
- `badge-bench/bench.sh zig-out/firmware/demosnout.elf --frames 900
  --every 60 --symbols`: worst frame of Intro, Plasma and Copper under
  12 ms busy; numbers recorded in `docs/PERF.md`.
- ELF `.text` under 60 KB at M0 (there is room for the seven M1 parts).

## M1 the effects — DONE, tag `snouty-scene/m1`

Status 2026-09-30: seven parts, one Opus agent each in worktrees
`snouty-badge-scene-<part>` (branches `scene/m1-<part>`), merged into
`scene/m0`. Every part under 6 ms worst (table in `docs/PERF.md`); voxel
runs full resolution (160 columns, 150 steps) at 5.59 ms, tunnel sways
its window over 200x168 LUTs (67 KB). Sizes: `.text` 77,624, `.bss`
169,016 (SPEC budget raised to 190 KB). Full loop verified headless:
6900 frames, `debug_part` back to 0 at frame 6870. Weak spots for M3
are listed per part in each agent's GIF review notes (PERF.md rows) and
summarised in the M2 hand-off. Merge note: `host_tests.zig` imports,
`timeline.zig` entries and `PERF.md` rows conflict on every merge; they
resolve mechanically (keep both / non-placeholder line / append rows).


Seven parts, each one module and one agent, in worktrees
`/home/exedev/snouty-badge-scene-<part>` on branches `scene/m1-<part>`
from tag `snouty-scene/m0`: rotozoomer, tunnel, twister, metaballs,
voxel, head, fire. Each agent replaces the placeholder in the timeline
entry for its part, proves its worst frame under 12 ms with
`tools/bench_parts.sh <index>`, writes `docs/preview_<part>.gif`, and
reports RAM (`.bss` delta) and the numbers. Merge order: cheapest first.
Contract details are in SPEC.md sections 3 to 5; the agent brief adds
per-part parameters.

## M2 the show — DONE, tag `snouty-scene/m2` (2026-09-30)

Status: Ending written (4.68 ms worst, .bss +5.5 KB), pacing pass below,
picker polish, `tools/check_timeline.mjs` + `tests/golden.json`, full
M2 bench table in `docs/PERF.md` (every part under 6 ms, full loop 5.56 ms
worst), review GIF `docs/preview_m2.gif` (every 10th frame of the loop).

Ending part, credits, pacing and palette pass, picker polish,
`tools/check_timeline.mjs` with goldens, `docs/PERF.md` table, full-loop
GIF. Single agent plus review.

### Pacing decisions (2026-09-30, from the full-loop contact sheet)

- Order is now Intro, Plasma, Copper, Rotozoomer, Twister, Tunnel,
  Metaballs, Voxel, Head, Fire, Ending: it alternates warm/cool and
  bright/dark at every boundary and splits the two purple full-screen
  textures (Rotozoomer, Tunnel) with the warm Twister.
- Metaballs now cross-fades warm to cool (was cool to warm): it follows
  the violet Tunnel in orange and hands its blue to the Voxel sky, so the
  dark-to-daylight jump into Voxel continues a hue instead of breaking one.
- Voxel stays just after Metaballs as the climax (the one daylight part);
  the Head after it is dark and slow, Fire is the last burst, and Fire to
  Ending is a match cut on the Iris mark (centre screen in both).
- Tunnel 5 to 4 bars: its look is set in the first seconds and it is the
  fastest motion in the show; 8 s keeps it a rush.
- Snouty head 6 to 5 bars: a single tumbling object, 10 s is enough.
  Loop is 55 bars = 110 s (was 57).
- Fades 15 to 20 frames with a 5-frame black gap on each side (10 black
  frames at a boundary): a gentler ramp on the LCD and a short breath
  between high-contrast palettes; still under a beat and a half.
- Copper to Rotozoomer and Voxel to Head use `fx.dissolve` (4x4 blocks in
  8x8 Bayer order) for variety: the blocks rhyme with the Rotozoomer's
  tiles, and the dissolve keeps the Voxel daylight crisp instead of
  passing through a muddy dim fade.
- Ending to Intro is `.seamless`: the Ending cross-fades into the Intro's
  frame 0 itself and neither side is veiled, so the loop is the smoothest
  cut in the show (pixel-identical frames). The Intro's title still lands
  at frame 180 and holds.

## M3 Adrian's review — DONE, tag `demosnout/m3` (2026-09-30)

Adrian ran M2 on the badge ("generally I love it") and asked for four
things, all in this milestone:

- Renamed to **Demosnout**: directory `carts/demosnout/`, binary
  `demosnout` (the badge menu shows it), bench toml, the Intro title (one
  line at 2x, gold), the scroller, the picker title and the first credit
  card. Older tags keep their `snouty-scene/` names.
- Copper 6 to 7 bars: the scroller (1463 px at 2 px per frame, plus the
  160 px entry) needs 812 frames to cross once; at 720 the dissolve cut
  the greetings off. At 840 the last glyph leaves the screen as the
  dissolve starts.
- Credits: "CODE + ART / CLAUDE", "PROMPTING + / HUMANING / ADRIAN" (the
  label over two lines; a 20-character line is the full screen width) and
  a new "SPECIAL THANKS / THE DEMOSCENE" card before the closing one.
  Seven cards at 96 frames need the Ending at 8 bars (cards end at 768,
  the mark holds alone until the cross-fade at 864). Loop is 57 bars =
  114 s.
- B outside debug builds toggles a **hold** (`timeline.hold`): the
  auto-advance stops. Every part but the Ending is `.endless`: its `t`
  keeps counting past the part length and the out-veil is suppressed (they
  are periodic or settle; the Intro clamps its warp speed at its last
  frame so `t * t` cannot overflow). The Ending is `.loop`: it fades out
  (its seamless cut is replaced by a fade) and restarts at frame 0.
  Releasing the hold on a part that ran past its length cuts to the next
  part, exactly like A/Start. A toast "HOLD ON" / "HOLD OFF" shows
  bottom-right for 75 frames. `debug_hold` export; host test in
  `timeline.zig`; `check_timeline.mjs` goldens regenerated.

Verified: `zig build -Dcart=demosnout`, `zig build test`, `zig build
check-float`, `check_timeline.mjs` PASS (loop 6840 frames), headless
presses (B holds the Intro past frame 900, B again moves on, the held
Ending restarts, A still skips), review GIF `docs/preview_m3.gif` (every
10th frame of the loop), bench spot checks of parts 0, 2 and 10 in the
commit message.
