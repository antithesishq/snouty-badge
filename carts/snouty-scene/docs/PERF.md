# Snouty Scene: performance

The rule (SPEC.md section 2): every part's worst frame under **12 ms**
calibrated busy time in badge-bench (72% of the 16.7 ms frame), so the demo
never drops a frame. Budgets: `.text` + `.rodata` under 110 KB, `.bss`
under 150 KB (M0 target: `.text` under 60 KB).

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
