# M2.1 perf variants

**Shipped: `cut20`** (Adrian, 2026-09-29) is the default build; pass
`-Dreflections_variant=<name>` for the others.

The full M2 scene (glass, shore, water shadows) is 74.85 ms at worst, and the
20 fps budget is 47 ms. These are three ways to fit it, built from one tree
for side-by-side comparison, plus the over-budget baseline. PLAN.md "M2.1 Perf
variants" has the contract; `cart/src/variant.zig` has the settings.

M2.2 update (names, skyline, Iris logo): full20 73.88, cut20 46.33, full15
58.05, half30 22.57 ms worst; the table below is the M2.1 measurement.

| variant  | res          | fps | scene                                    | worst ms (frame) | mean ms | budget | verdict |
|----------|--------------|-----|------------------------------------------|------------------|---------|--------|---------|
| `full20` | 160x128      | 20  | everything (M2 baseline)                 | 75.00 (531)      | 60.09   | 47.0   | over    |
| `cut20`  | 160x128      | 20  | no glass sphere, no water shadows        | 45.37 (558)      | 42.43   | 47.0   | ok      |
| `full15` | 160x128      | 15  | everything; glass seen directly looks its two rays up (knob 4) | 57.19 (257) | 53.78 | 62.7 | ok |
| `half30` | 80x64, 2x2   | 30  | everything                               | 20.81 (799)      | 17.07   | 31.3   | ok      |

Calibrated badge-bench busy ms, one full orbit (30 s) per variant, default
Bayer dither. Budgets are 94% of the frame period. Every variant passes
`check_render` against the reference on frames 0, 1/4, 1/2, 3/4 of the
orbit and on its worst frame.

`cut20` first kept depth-0 shadows as planned (47.97 ms, 0.97 over), so its
shadows were turned off entirely. `half30` has 10 ms of spare time; locking it
to 20 fps instead would leave 26 ms for more features.

What `cut20` loses besides the glass: the spheres' shadows on the water.
They are clearest while the camera faces the sun, as a darker wedge on the
water beyond the sphere (also visible in its reflection) with less glitter;
with the sun behind the camera they are mostly hidden behind the sphere. Reference frame 525,
shadows on (left) and off (right):

![water shadows on and off](water_shadows_on_off.png)

The same moment (25.2 s into the orbit) in each, left to right: full20, cut20,
full15, half30.

![same frame in all four](variants_montage.png)

One-orbit GIFs, sampled every 0.6 s of scene time (so they play 6x fast and
show equal scene time): `variant_full20.gif`, `variant_cut20.gif`,
`variant_full15.gif`, `variant_half30.gif`.

## `tufty20` (Tufty 2350 port, 2026-10-02)

The Pimoroni Tufty 2350 runs the same RP2350 Cortex-M33 core at 250 MHz
instead of the SYCL badge's 150 MHz. The snouty-tufty repository builds this
cart with `-Dreflections_variant=tufty20`: **full15's scene (glass sphere,
water shadows, glass seen directly through `env`, the M2.2 logo cuts and the
M3 cuts) at 20 fps**. Only the frame rate differs from full15
(`tests/variant_unit.zig` checks that). The frozen path tracer slice is
36 ms, as in cut20. The variant is not meant for the SYCL badge, where it
drops to about 15 fps on heavy frames. The picture is full15's, so
`variant_full15.gif` shows it (played at 20 fps instead of 15).

**The gate, converted.** badge-bench models a 150 MHz core. The Tufty's
20 fps budget is 47.0 ms (94% of 50 ms) at 250 MHz, which is
47.0 x 250 / 150 = **78.3 ms modelled at 150 MHz**. Cycle counts carry over
1:1 to the higher clock because this is a RAM cart: code and data are in
SRAM, which runs at the system clock, so the XIP flash stalls of an XIP
cart do not apply. The `fp_dep` stalls are cycles too. Not modelled: SRAM
bank contention with the Tufty OS's scaler on core 0, so keep about 10%
spare.

Calibrated busy ms at 150 MHz on all four presets, and the estimate at
250 MHz (x 0.6). Command: `M3_VARIANT=tufty20 M3_BUDGET=78.3
tools/bench_variants.sh --m3 2 3`.

| Row | Preset | Worst (frame) | Mean | Worst @ 250 MHz | Verdict vs 78.3 |
|---|---|---|---|---|---|
| 2 attract (4 orbits, motion, fades) | sunset | **63.44** (324) | 59.17 | 38.1 | PASS |
| | midnight | 51.95 (847) | 47.52 | 31.2 | PASS |
| | noon | 52.02 (1447) | 46.72 | 31.2 | PASS |
| | storm | 48.30 (2058) | 45.07 | 29.0 | PASS |
| | all | 63.44 | 49.62 | 38.1 | PASS, 19% spare |
| 3 height (a table rebuild every frame) | sunset | **65.72** (356) | 59.54 | 39.4 | PASS |
| | midnight | 54.25 (836) | 48.08 | 32.6 | PASS |
| | noon | 54.58 (1444) | 47.23 | 32.7 | PASS |
| | storm | 50.51 (2052) | 45.09 | 30.3 | PASS |
| | all | 65.72 | 49.98 | 39.4 | PASS, 16% spare |

Sunset is the heaviest preset because it is the only one with the glass
sphere. The worst frame, 65.72 ms, leaves 12.6 ms of the 78.3 ms gate. That
covers the 10% contention reserve, so no knob was cut. A controls run (orbit
and height, preset, dither, freeze and unfreeze, 600 updates) peaks at
62.72 ms. Frozen updates take about 42 ms. The 36 ms slice is wall-clock, so
on the Tufty the tracer gets 1.67x more work done per update. It should
reach 256 passes in about 35 s instead of 58 s.

Build sizes (`size -A`): `.text` 109,616, `.data` 64, `.bss` 109,552.
