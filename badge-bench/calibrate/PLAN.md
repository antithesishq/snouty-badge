# Plan: badge-calibrate (C0 + C1)

Started 2026-09-27. Builds the cart and the fitting side described in
`SPEC.md`. This file is the contract between the two work streams (the Zig
cart, the Python side) and records what changed relative to the spec.

## Corrections to SPEC.md after reading the OS

1. **When the DMA runs.** `sycl-badge/src/os/kernel.zig` sends
   `FRAMEBUFFER_DONE` only after the LCD transfer has finished
   (`.data_transfer -> .draw_debug -> send`). So `present()` for frame N
   first blocks until frame N-1's flush is done, then sends frame N and
   returns; core 0 picks the message up on its next poll and starts the DMA
   of frame N. Consequence for the schedule: the DMA window is the first
   ~5.2 ms *after `present()` returns*, i.e. the start of the next
   `update()`, exactly as the spec's schedule assumes, with a small
   start-up latency on core 0. The busy run starts 15 k cycles (100 us)
   after `update()` begins and must end by 4.5 ms (675 k cycles).
   40 KB over SPI at 62.5 MHz = 5.24 ms (lcd.zig: `spi_baudrate =
   62_500_000`).
2. **No chip id word.** SYSINFO (0x40000000) is not mapped by badge-bench
   and is not part of the cart API; the summary page shows the results
   checksum instead. The fitted table is shared across badges (spec open
   question 3: yes, shared).
3. **Select does nothing.** Idle and busy are two columns on the same page,
   so no toggle is needed. A = next page, B = restart the passes.
4. **Emulator pairing by trace, not by frame.** In badge-bench DWT_CYCCNT
   *is* the modelled cycle count, so the cart's own `CAL k=...` trace lines
   from an emulator run are the modelled per-kernel counts, in the same
   format as the hardware capture. `fit.py` pairs the two captures by
   kernel id. No frame-order bookkeeping.
5. **The DMA wait is skipped under emulation.** Spinning 1.2 M modelled
   cycles per frame would cost badge-bench hundreds of thousands of Python
   block hooks per frame. `badge-bench/carts/badge-calibrate.toml` pokes
   `harness.skip_wait=1` before `start()`; the cart reads it as a volatile
   and skips the spin. Hardware never sets it.
6. **K19 is self-contained.** Carts do not import each other's sources
   (root CLAUDE.md). K19 is a ~64-op mix written in `kernels.zig` in the
   shape of `trace.zig`'s water shading (dot products, a reciprocal, a
   Schlick term, a lerp, a table lookup), not a copy.

## Contract: trace lines

Emitted after every complete pass (after the kernel 19 frame), one line per
kernel, then one summary line. Identical on hardware (`[CART]` prefix
added by the OS console) and in badge-bench (`[trace frame f]` prefix).
Every number is decimal unless marked hex; each line is under 120 bytes
(the trace buffer is 128).

```
CAL k=<id> n=<N> ops=<N*ops_per_iter> idle_min=<c> idle_med=<c> busy_min=<c> busy_med=<c> sink=<hex8>
CAL done pass=<p> sum=<hex8>
```

`c` is the raw DWT delta around one run of the whole kernel (N iterations),
not per op and with nothing subtracted; `fit.py` divides by `ops` and uses
K0 as the loop-overhead baseline. `idle_*` come from the two idle runs per
frame accumulated over all passes so far (min, and median of all values
seen); `busy_*` from the one busy run per frame. `sink` is the kernel's
volatile sink after the last run (a check that the body ran). `sum` is
FNV-1a-32 over all eight numbers of all 20 kernels, in id order, so a photo
of the summary page can be checked against a capture.

## Contract: kernel table

`kernels.zig` exposes `pub const list: [20]Kernel` with
`.{ .name, .run: *const fn () void, .n, .ops_per_iter }`. Names are the
spec's ids without the `K<n> ` prefix (`empty`, `vmul_indep`, ...). Each
`run` is `noinline`, so it is one sized `STT_FUNC` symbol in the ELF named
`kernels.k<id>_<name>`; badge-bench's per-function tables are then the
kernel's own instruction mix. `n` per kernel is chosen so an idle run is
300 k to 500 k cycles on the model (under 3.5 ms on hardware even at 1.3x).

## Contract: badge-bench JSON additions

`bench.json` `hot[]` entries gain `mnemonics`: `{base_name: executions over
the run}` (capstone base mnemonic as `model.base_name`, so `vmul`, `ldr`,
`b<cc>`, ...) and `taken`: taken-branch entries into the function's blocks.
`fit.py` divides by the function's `entries` to get per-call counts.

`badge_bench/classes.py` (no unicorn/capstone imports) maps a base mnemonic
to a model class; `model.cycles_of` and `fit.py` both use it. Classes and
default costs (the current table, unchanged):

| class | mnemonics | default |
|---|---|---|
| `alu` | everything not listed | 1 |
| `vmul` | vmul, vnmul | 1 |
| `vaddsub` | vadd, vsub, vabs, vneg, vmov, vcvt*, vsel*, vmaxnm, vminnm | 1 |
| `vcmp` | vcmp, vcmpe, vmrs | 1 |
| `vdiv` | vdiv | 14 |
| `vsqrt` | vsqrt | 14 |
| `vfma` | vfma, vfms, vfnma, vfnms, vmla, vmls, vnmla, vnmls | 3 |
| `ldr` | ldr* (integer loads, any width) | 2 |
| `str` | str* | 2 |
| `vldr`, `vstr` | vldr / vstr | 2 |
| `ldrd_strd` | ldrd, strd | 3 |
| `multi` | push/pop/ldm/stm/vpush/vpop/vldm/vstm | 1 + regs (not fitted) |
| `udiv` | udiv, sdiv | 6 |
| `taken` | a taken branch (block entry, not a mnemonic) | 1 |

## Contract: calibration.toml

Written by `fit.py`, read by `badge-bench --calibrate FILE`:

```toml
[meta]
date = "2026-..."           # of the fit
elf_sha256 = "..."          # the badge-calibrate ELF both captures came from
hardware_capture = "..."    # file name
emulator_run = "..."        # bench.json used
residual_rms = 0.0          # of the per-kernel fit, in cycles/op

[costs]                     # fitted issue cycles per class (idle bus)
alu = 1.0
vmul = 1.0
...
taken = 1.0

[contention]
dma_ms = 5.24               # length of the DMA window after present()
factor = 1.0                # measured busy/idle over memory-class cycles
ldr = 1.0                   # per-class busy/idle ratios for the record
str = 1.0
...

[[kernels]]                 # raw data, one per kernel
id = 0
name = "empty"
ops = 16384
modelled = 1234             # emulator cycles per run
idle_min = 1300
idle_med = 1301
busy_min = 1350
busy_med = 1352
ratio_idle = 1.05
ratio_busy = 1.09
```

`badge-bench --calibrate FILE` replaces the class costs with `[costs]`
(rounded to the nearest 0.25 cycle, applied per instruction as fractional
cycles and summed per block) and reports, per frame, `idle ms` (the
calibrated count) and `busy ms` = idle + memory-class cycles x
(factor - 1) x min(1, dma_ms / idle ms). The run keeps a second per-frame
counter of memory-class cycles for this (one extra add per block hook).
Without `--calibrate` nothing changes: `tests/test_reflections.sh` stays
exact. The report header names the calibration file and date, and the
"treat as a floor" line becomes "calibrated on <date>; residual <r>
cycles/op".

## Work streams

**A: the cart** (`badge-bench/calibrate/build.zig`, `cart/src/*.zig`, root
`build.zig` entry `badge-calibrate`, `badge-bench/carts/badge-calibrate.toml`).
Gate: `zig build -Dcart=badge-calibrate` at the root; `badge-bench/bench.sh
zig-out/firmware/badge-calibrate.elf --json --symbols --listing` runs 20
frames without fault, prints 21 trace lines whose `idle_min` per op orders
as expected (vdiv about 14x vmul, loads 2x alu, empty near 0), and the
listing of every `kernels.k*` function shows the intended body. The wasm
build must compile too (the root builds both), but the simulator is not a
target: on wasm `cycles()` is unavailable, so the cart shows a
"hardware only" page and does nothing else.

**B: the Python side** (`badge_bench/classes.py`, JSON `mnemonics`/`taken`,
`--calibrate`, memory-class counter, `calibrate/fit.py` with `--selftest`,
`tests/test_reflections.sh --calibrate`). Gate: `fit.py --selftest` on the
cart's own bench.json gives ratios 1.000 for every kernel and reproduces
the default table within 0.01; `test_reflections.sh` still exact;
`--calibrate` on the selftest toml reproduces the uncalibrated ms.

**C: docs and dist**: `calibrate/README.md` (run, capture, fit), the
badge-bench README (new section, new flag, JSON keys), the root README row,
`calibrate/dist/badge-calibrate.uf2` plus a tester note (force-added; the
repository ignores `*.uf2`), memory of the status.

## Deviations found while building (the code is authoritative)

- Trace lines go out **one per frame** from a snapshot taken when a pass
  completes (frames 20..39 for pass 1; the `done` line shares row 19's
  frame but is sent after that frame's kernel runs). Back-to-back
  `trace()` calls would overwrite the single shared trace buffer before
  core 0 prints it. `carts/badge-calibrate.toml` therefore runs 40 frames.
- `hot[]` JSON entries also carry `class_cyc` ({class: cycles over the
  run}) so `fit.py` can charge `multi` at its real 1 + regs cost.
- The contention `factor` is per memory-class cycle: `1 + sum(busy - idle)
  / sum(fitted memory-class cycles)` over K7..K11, which is how `busy ms`
  applies it; the plain whole-kernel busy/idle ratio is written next to it
  as `whole_kernel_ratio`.
- No fitted intercept: the cycles outside the kernel function per run come
  from the emulator (`meta.call_overhead`, 14 cycles, warned if it varies),
  because a free constant made the system ill-conditioned.
- `fit.py` verifies the `CAL done sum` (FNV-1a-32 over k, n, ops, idle_min,
  idle_med, busy_min, busy_med, sink as little-endian u32s, kernels in id
  order) and refuses a capture whose rows do not hash to it.
- `Kernel` has a `short` name for the 20-column pages; K19 has
  `ops_per_iter = 60`; K13 and K10 are inline asm (LLVM hoisted the bit
  tests of K13 so every branch was taken, and copies floats through core
  registers); each loop holds an empty `asm volatile` against unrolling.
- No kernel exercises `vfma` or `ldrd_strd`; the fit keeps their defaults
  and says so. VLDR and VSTR are only separable through K19.
- `ldmdb` stays in `alu` (the old table never priced it as multi; the
  exactness test requires bit-identity).

## Status

- 2026-09-27: plan written; A and B start in parallel, C after.
- 2026-09-27: **C0 and C1 built.** Cart builds (thumb + wasm), 102 KB;
  emulator run clean, 21 lines, every kernel body reviewed in the listing;
  `tests/test_calibrate_selftest.sh` PASS (ratios 1.000, residual 0.000,
  defaults reproduced, `--calibrate` reproduces the model); `tests/
  test_reflections.sh` still exact after the model refactor;
  `dist/badge-calibrate.uf2` committed with a tester note. Modelled per-op
  costs from the emulator, for reference: empty 0.19 (loop overhead 3
  cycles per 16 ops), vmul 1.19, vdiv 14.19, vsqrt 15.19, ldr/str 2.38,
  vldr/vstr 2.44, framebuffer ldrh/strh 2.50, branch_taken 4.00, udiv 6.19,
  vcmp_vmrs 4.25, table_lerp 14.19, mixed_tracer 1.55.
- Next, **C2**: a tester flashes `dist/badge-calibrate.uf2`, captures the
  console (or photographs the pages), `fit.py` writes `calibration.toml`,
  and `tests/test_reflections.sh --calibrate` is compared with the timing
  build's on-screen number.

## C3: apply the badge fit, model FP result latency

Started 2026-09-29, from the first badge capture (2026-09-28, a coworker's
SYCL Badge V2, `badge-2026-09-28-pass5.txt` in this directory; the run
needed the kernel's `DEMCR.TRCENA` fix on core 1, see the sycl-badge
branch `fix/core1-dwt-trcena`). `fit.py` on that capture: residual 0.350
cycles/op, udiv 11.9 (default 6), ldr/str 1.1 (default 2), taken 1.6,
vcmp 1.8, vstr clamped to 0. Applying it moves the carts' worst-frame
budget use by -17% (maze) to +41% (snouty-boy), so the defaults are no
longer a useful floor: the calibration goes on by default (item 5).

What the residual is. The kernels say the FPU stalls one cycle when an
instruction consumes the result of the FP instruction *immediately before
it*, and not otherwise:

| pair | measured cycles/op | reading |
|---|---|---|
| K1 vmul x4 chains 1.19 vs K2 one chain 2.06 | +0.87 | back-to-back dependent VMUL stalls ~1 |
| K3 two chains interleaved 1.20 | +0.01 over K1 | a dependency two instructions back is free |
| K6 vdiv x4 chains 14.00 vs K4 one chain 15.00 | +1.00 | same stall after VDIV |
| K5 `a = sqrt(a) + 1` 17.00 | 14 + 1 + 2 | VSQRT->VADD and VADD->VSQRT, one stall each |

A per-class cost cannot express this (K1 and K2 have the same mix), so the
fit smeared it over `vmul`, `vsqrt`, `vcmp` and `vldr` (K18/K19 have many
such pairs, which is also why `vstr` went negative: `vldr` absorbed
K18/K19's stalls and `vstr` had to compensate in K10).

1. **New model class `fp_dep`** (`classes.py`, `model.py`): counted, like
   `taken`, per instruction rather than per mnemonic: 1 when the
   instruction reads a register that the *immediately preceding*
   instruction of the same block wrote, and that instruction is FP data
   processing (classes `vmul`, `vaddsub`, `vcmp`, `vdiv`, `vsqrt`, `vfma`;
   registers s0-s31, d0-d15 and the FPSCR flags, so VCMP->VMRS counts).
   Detected statically per block with capstone's `regs_access()` in
   `decode_block`; a pair split across a block boundary is not counted
   (a taken branch sits between them). Default cost **0**, so every
   uncalibrated number and `tests/test_reflections.sh` stay bit-identical;
   the fit prices it. Which producers and consumers count is decided by
   the capture: variants (producer = FP data processing, consumer = any;
   producer also VLDR; consumer only FP data processing) are each fitted
   and the one with the lowest residual is kept, the others recorded here.
2. **Plumbing.** `decode_block` returns the block's stall count; `blocks`
   rows gain it; `hot[]` entries gain `fp_dep` (stalls over the run, like
   `taken`) and `class_cyc.fp_dep`; the listing marks stalled instructions;
   `fit.py` builds the `fp_dep` column from `hot[].fp_dep / entries` and
   writes it to `[costs]`; the fixture generator emits `fp_dep = 0`
   (unidentifiable there, kept at the default, selftest unchanged);
   `config.load_calibration` accepts the new key.
3. **VLDR/VSTR.** After 1, if `vstr` still fits negative, tie `vldr = vstr`
   in `fit.py` (one unknown; they are only separable through K19's mix).
4. **Refit** on the capture -> `calibration.toml` (committed) and rerun
   the six carts; record before/after per cart in the badge-bench README.
5. **Calibration on by default.** `badge-bench` loads
   `calibrate/calibration.toml` when it exists; `--no-calibrate` gives the
   raw model; `--calibrate FILE` names another file. Reports keep saying
   which. `tests/test_reflections.sh` and the model half of
   `tests/test_calibrate_selftest.sh` pass `--no-calibrate` (they check
   the raw model's exactness). `carts/*.toml` budgets are judged on the
   calibrated busy ms as before.
6. **Docs.** badge-bench README (model table gains `fp_dep`; the FP stall
   blind spot becomes a measured term; "no badge has been measured yet"
   goes; the calibrated per-cart table), `calibrate/README.md` status,
   `SPEC.md` status, `dist/README.md` (the kernel needs the TRCENA fix or
   the cart hangs before its first line).

Not in C3, needs another badge run (**C4**): kernels for `ldrd/strd`
(6-7% of snouty-bugs' and snouty's cycles, unmeasured, default 3), `vfma`
(under 1% everywhere) and a load-use pair (VLDR feeding the next FP op);
flash the fixed kernel first.

Gates: `tests/test_calibrate_selftest.sh` PASS; `tests/test_reflections.sh`
exact with `--no-calibrate`; the refit residual well under 0.350 cycles/op
with `vstr` positive; the six carts rerun.
