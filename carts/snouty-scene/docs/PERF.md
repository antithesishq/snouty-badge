# Snouty Scene: performance

The rule (SPEC.md section 2): every part's worst frame under **12 ms**
calibrated busy time in badge-bench (72% of the 16.7 ms frame), so the demo
never drops a frame. Budgets: `.text` + `.rodata` under 110 KB, `.bss`
under 190 KB (raised from 150 KB at M1).

## M2 (2026-09-30), the finished show

Calibrated badge-bench (`calibrate/calibration.toml`, fitted 2026-09-29),
ELF sha256 `940b386313ab`. `carts/snouty-scene/tools/bench_parts.sh` over
all eleven parts, each run from the part's frame 0 for its length plus 60
frames (so "run worst" includes the next part's enter() and fade-in):

| # | Part | mean busy ms | part worst busy ms (frame) | run worst | verdict |
|---|---|---|---|---|---|
|  0 | Intro       |  1.20 |  2.44 (t 335) |  2.44 | ok |
|  1 | Plasma      |  0.83 |  1.60 (t 5) |  1.60 | ok |
|  2 | Copper      |  0.50 |  1.21 (t 24) |  1.52 | ok |
|  3 | Rotozoomer  |  1.36 |  2.13 (t 5) |  2.13 | ok |
|  4 | Twister     |  0.77 |  1.53 (t 24) |  2.38 | ok |
|  5 | Tunnel      |  1.62 |  2.38 (t 5) |  3.15 | ok |
|  6 | Metaballs   |  2.55 |  3.49 (t 576) |  5.56 | ok |
|  7 | Voxel       |  4.76 |  5.56 (t 5) |  5.56 | ok |
|  8 | Snouty head |  1.02 |  1.87 (t 594) |  2.71 | ok |
|  9 | Fire        |  1.95 |  2.71 (t 469) |  3.22 | ok |
| 10 | Ending      |  3.35 |  4.68 (t 803) |  4.68 | ok |

Every part is under 6 ms worst, half the 12 ms rule. The worst frames are
veil frames: `fx.fade` is about 1 ms over the whole frame (frame 5 is the
first fade-in frame after the 5-frame black gap; black frames are a plain
clear). The Ending's worst is its closing cross-fade into the Intro
(t 803: every pixel mixed towards the Intro gradient, two multiplies on
the spread RGB565 value); its steady frames are 3 to 3.5 ms (halo box,
the 47-row reflection, one multiply per water pixel, credits text).

Full loop, `badge-bench/bench.sh zig-out/firmware/snouty-scene.elf --frames
6660 --every 600 --symbols` (one loop, 6600 frames, plus 60 of the second
pass through the seamless cut):

- start-up (reset to the first update: every part's `init()`, the tunnel
  and plasma LUTs, the voxel map, textures, palettes): 71.9 ms
- busy ms: min 0.39, mean 1.97, p95 4.75, max 5.56 (frame 3845, a Voxel
  fade-in frame); 0 of 6660 frames over budget, worst frame 33% of 16.7 ms
- hot functions: `parts.voxel.render` 29%, `parts.ending.render` 15%,
  `memcpy` 13% (background column copies and upscale2x's second column),
  `parts.metaballs.render` 10%, fire 6%, rotozoomer 6%, tunnel 6%,
  `api.text` 4%

Sizes (`size -A`): `.text` 89,144 (under the 110 KB budget), `.data` 20,
`.bss` 174,528 (under 190 KB; the Ending adds 5,512: the sky column, the
16-level halo palette per sky row, halo level table, mark masks, stars,
the Intro gradient in spread form). Stack headroom in the 307 KB window is
about 50 KB.

## History

The M1 per-part rows are replaced by the M2 table above (the M1 parts'
own `.bss` deltas: tunnel LUTs 69 KB, voxel map 36 KB, metaballs 14 KB,
fire 11 KB, rotozoomer 4 KB, twister and head 3 KB each). The M0 numbers
below are kept for the record (M0 order and 15-frame fades).

## M0 (2026-09-30)

Calibrated badge-bench (`calibrate/calibration.toml`, fitted 2026-09-29),
ELF sha256 `49024cc29202` (the M0 build).
`carts/snouty-scene/tools/bench_parts.sh 0 1 2 3 10`, each run from the
part's frame 0 for its length plus 60 frames:

| # | Part | mean busy ms | part worst busy ms (frame) | run worst | verdict |
|---|---|---|---|---|---|
|  0 | Intro       |  1.18 |  2.45 (t 350) |  2.45 | ok |
|  1 | Plasma      |  0.81 |  1.59 (t 1) |  1.59 | ok |
|  2 | Copper      |  0.51 |  1.30 (t 715) |  1.73 | ok |
|  3 | Rotozoomer (placeholder) |  0.95 |  1.73 (t 1) |  1.73 | ok |
| 10 | Ending (placeholder)     |  0.94 |  1.73 (t 1) |  1.73 | ok |

The worst frames are fade frames: `fx.fade` is one multiply per pixel over
all 20,480 pixels, about 1 ms, on top of the part. The placeholders cost
more than the plasma because `cart.text` at 6x scale writes pixel by pixel
with bounds checks.

Full loop, `badge-bench/bench.sh zig-out/firmware/snouty-scene.elf --frames
900 --every 60 --symbols` (Intro, then 540 frames of Plasma):

- start-up (every part's `init()`: tables, palettes, the scroller strip):
  2.84 ms
- busy ms: min 0.43, mean 0.95, p95 1.59, max 2.45 (frame 350, the Intro's
  fade-out); 15% of the budget
- hot functions: `parts.plasma.render` 39% (55k cycles per frame on
  average), `api.text` 24%, `memcpy` 23% (the gradient and copper column
  copies, the second column of `upscale2x`), `parts.intro.render` 10%

Sizes (`size -A`): `.text` 39,732 bytes (code and read-only data: the
scroller font is about 1.5 KB, `gen/textures.zig` is not referenced yet so
it is not linked), `.data` 16, `.bss` 28,472 (plasma distance table 11.5 KB
and index field 5 KB, copper strip 6 KB, palettes 1.5 KB).

Plenty of headroom: the M1 parts can spend up to about 9 ms each before a
fade pushes them to the limit.
