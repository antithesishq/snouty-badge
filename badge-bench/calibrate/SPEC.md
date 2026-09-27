# badge-calibrate: hardware calibration cart for badge-bench

Owner: Adrian Hatch (Antithesis). Lives in `badge-bench/calibrate/` as a
cart plus a fitting script; the output is a calibrated cycle table that
`badge-bench` loads with `--calibrate`. Read `../PLAN.md` and
`../README.md` first for the model being calibrated.

## 1. One paragraph

A cart that times a fixed set of micro-kernels with the Cortex-M33 cycle
counter (`cart.cycles()`, DWT_CYCCNT, exact core cycles, enabled for the
cart by the OS) and shows the results on screen and over the trace
channel. Each kernel isolates one row of badge-bench's cycle model. Each
runs twice per frame: once right after `present()` returns, while core 0's
DMA is streaming the 40 KB framebuffer to the LCD (about 5.2 ms at the
62.5 MHz SPI clock), and once after that window has passed. The same ELF
run through badge-bench gives the modelled count for each kernel, and
`fit.py` turns measured over modelled into per-row costs plus a DMA
contention factor. After this, badge-bench reports a measured error bar
instead of "a floor".

## 2. Hardware facts the design leans on

- DWT_CYCCNT at 0xE0001004 is enabled by the OS for core 1
  (`sycl-badge/src/os/cart.zig`), read via `cart.cycles()` (i64, wraps
  handled). Reading it costs a load; the harness subtracts an empty-kernel
  baseline.
- `present()` returns after core 0 acknowledges; the LCD DMA then reads
  the just-presented framebuffer for about 5.2 ms. The cart can therefore
  choose "DMA busy" by timing immediately, and "DMA idle" by first
  spinning until `cycles()` has advanced 1.2 M cycles (8 ms).
- Cart code and data live in SRAM (0x20035100 up); striped banks 0..7.
  SRAM8/9 at 0x20080000 are non-striped and belong to the OS, so the cart
  must not use them. Bank placement is therefore tested only within the
  cart's own region by address pattern, not by bank choice.
- `cart.trace()` sends a string through the mailbox; the OS prints it as
  `[CART] ...` on its console (USB serial). If nobody is attached, on-screen
  is the fallback: the table is drawn with `cart.text`.
- Inputs: A advances to the next results page, B re-runs, Select toggles
  DMA-busy/idle display, Start+Select is OS-owned.
- Cart budget is irrelevant here; keep it small anyway.

## 3. Kernels

Every kernel is a function with `noinline` and its loop body written so
LLVM cannot fold it (results accumulated into a `volatile` sink, inputs
loaded from a `volatile` source once before the loop). Each runs `N`
iterations with `N` chosen so a run is 200 k to 1 M cycles (long enough
to drown the counter read, short enough to fit inside the 5.2 ms DMA
window: the busy run must finish in under 4 ms, so `N` is per kernel).
The unrolled loop body is 16 operations so loop overhead is under 7 %,
and the fit accounts for it because the emulator counts the same
branches.

| id | model row(s) tested | body (x16 unrolled) | expected cycles/op |
|----|--------------------|----------------------|--------------------|
| K0 empty | loop overhead, counter read | nothing | 0 |
| K1 vmul_indep | VMUL.F32 throughput | 4 independent accumulators, `a_i *= k` | 1 |
| K2 vmul_dep | VMUL.F32 latency (dependent chain) | `a = a * k` | 1 to 3, unknown; this is what we want |
| K3 vadd_vmul_mix | VADD/VMUL interleaved, 2 chains | `a = a*k + c` written as two ops, not fma | 1 to 2 |
| K4 vdiv | VDIV.F32 dependent | `a = a / k` | 14 |
| K5 vsqrt | VSQRT.F32 dependent | `a = sqrt(a) + 1` | 14 (+1) |
| K6 vdiv_indep | VDIV.F32 independent x4 | 4 chains | 14 if not pipelined, less if it is |
| K7 ldr_seq | LDR sequential, 16-word stride 4 | sum over a 4 KB array | 2 |
| K8 ldr_stride | LDR with 64 B stride over 32 KB | same, stride 64 | 2, or more if banks collide |
| K9 str_seq | STR sequential | fill 4 KB | 2 |
| K10 vldr_vstr | VLDR/VSTR sequential | copy 4 KB of f32 | 2 each |
| K11 ldrh_strh_fb | LDRH/STRH into the back framebuffer (the DMA reads the front one) | fill 160 columns x 128 | 2, contention sensitive |
| K12 branch_taken | taken conditional branch | countdown loop with body of 1 op, `N` iterations, unrolled x1 | 2 |
| K13 branch_pattern | alternating taken/not-taken | `if (i & 1)` on a volatile | 1.5 avg |
| K14 udiv | UDIV | `a = a / k` with k volatile | 3 to 12 |
| K15 nop_fetch | instruction fetch only | 16 `nop`s (`asm volatile`), 2-byte, tests the S-AHB fetch path from SRAM | 1 |
| K16 nop_fetch_w | same with 4-byte `nop.w` | | 1, or 2 if fetch is 32-bit limited |
| K17 vcmp_vmrs | VCMP + VMRS + IT sequence | `if (a > b) c += 1` on floats | 3 to 5 |
| K18 table_lerp | the tracer's sin lookup (cvt, and, ldr x2, sub, mul, add) | copied from `snouty-reflections` `math.sin_turns` | ~12 |
| K19 mixed_tracer | 64-op excerpt of `trace.zig`'s water path, constants in registers | representative mix | whatever it is |

Kernel sources are Zig, compiled with the carts' flags (ReleaseFast,
`cortex_m33+dsp+fp_armv8d16sp`, hard float). After building, the spec
requires eyeballing the capstone listing of each kernel (badge-bench
`--listing`) to confirm the body is the intended instruction mix; the fit
uses the emulator's actual counts, not the intended ones, so a
mis-compiled kernel is still measured correctly, just labelled wrong.

## 4. Schedule per frame

```
present()                       // frame N-1 goes out; DMA starts
t0 = cycles()
run kernel k, busy phase        // must finish < 4 ms
spin until cycles() - t0 > 1.2M // 8 ms: DMA finished
run kernel k, idle phase
run kernel k, idle phase again  // repeat to measure noise
draw results page
```

One kernel per frame, `vsync` disabled so frames run back to back; 20
kernels x 5 repetitions = 100 frames, about 2 s. Repetition results are
kept as min and median; min is what the fit uses (interrupts on core 1
are disabled, so noise should be tiny, and the report shows it).

## 5. Output

**Screen.** Three pages, A cycles: (1) per kernel: name, idle cycles/op,
busy cycles/op, busy/idle ratio; (2) the same for the second half of the
list; (3) summary: chip id word, `N` per kernel, run count, a checksum of
all results so a photo can be verified against the trace dump. Font is
the OS 8x8; 16 rows fit with a header.

**Trace.** After every full pass, one `cart.trace()` line per kernel:
`CAL k=<id> n=<N> idle_min=<c> idle_med=<c> busy_min=<c> busy_med=<c> sink=<hex>`
and a final `CAL done pass=<p> sum=<hex>`. Whoever has the badge attached
over USB captures the console; the OS prefixes `[CART]`. If no console is
attached, the photo of page 1 and 2 is enough for the fit (the fitter
accepts hand-typed numbers).

**Emulator side.** `badge-bench calibrate/zig-out/firmware/badge-calibrate.elf
--frames 100 --json` produces the modelled count per frame; a small
`calibrate/fit.py` pairs each frame with its kernel (frame order is fixed
and also printed in the trace) and computes:

- per kernel: `ratio_idle = measured_idle / modelled`, `ratio_busy`.
- a least-squares fit of the per-row costs in `model.py` (vmul, vadd, vdiv,
  vsqrt, ldr, str, branch taken, udiv, vcmp/vmrs, fetch) against the
  measured idle cycles, using the emulator's per-kernel instruction
  histograms as the design matrix.
- a DMA contention factor per memory-touching kernel, and one summary
  factor `busy_over_idle` weighted by a typical cart's memory-instruction
  share.
- writes `calibrate/calibration.toml`: the fitted table, the contention
  factor, the raw measurements, the ELF hash and date.

`badge-bench --calibrate calibrate/calibration.toml` then uses the fitted
table and reports two numbers per frame: idle-bus ms and DMA-busy ms
(the latter applies the contention factor to the first 5.2 ms of each
frame's memory instructions, or, simpler and stated as such, scales the
whole frame's memory cost by the factor weighted by 5.2 ms over the frame
time). The README gains a "Calibrated on <date> against <badge id>" line.

## 6. Layout

```
badge-bench/calibrate/
  SPEC.md            this file
  build.zig, build.zig.zon   copied from snouty-reflections (path dep ../../sycl-badge),
                     ReleaseFast, no assets, no options
  src/os/system/tracy_protocol.zig -> ../../../../../sycl-badge/src/os/system/tracy_protocol.zig
  cart/src/main.zig  schedule, pages, trace output, input
  cart/src/kernels.zig  K0..K19, each noinline with a comptime N
  cart/src/harness.zig  timing wrapper, min/median, checksum
  fit.py             pairs trace/JSON, fits, writes calibration.toml
  README.md          how to run on the badge, how to capture, how to fit
```

`badge-bench/carts/badge-calibrate.toml`: frames 100, budget none,
script none.

## 7. Verification

- `zig build` in `calibrate/`; `badge-bench` runs the ELF for 100 frames
  without fault and the per-frame modelled counts differ by kernel as
  expected (K4 about 14x K1 per op, etc.). This checks the harness before
  any hardware.
- Listing review of each kernel body (section 3).
- `fit.py --selftest`: feed it the emulator's own counts as if measured;
  it must return all ratios 1.0 and reproduce `model.py`'s table.
- Hardware: Adrian or the coworker flashes `badge-calibrate.uf2`, waits
  5 s, photographs pages 1 and 2 (or captures the console), and sends
  them back. `fit.py` then writes `calibration.toml`, and
  `tests/test_reflections.sh --calibrate` reports the calibrated ms for
  the ray tracer next to the measured overlay number from the timing
  build, which is the end-to-end check: the two should agree within the
  fit's residual.

## 8. Milestones

- **C0**: scaffold, K0 to K6 (FP), schedule, page 1, trace lines, runs in
  badge-bench. Gate: emulator run clean, listings look right.
- **C1**: K7 to K19, pages 2 and 3, `fit.py` with selftest,
  `--calibrate` in badge-bench, `dist/badge-calibrate.uf2` committed with
  a one-paragraph tester note like `snouty-reflections/dist/README.md`.
- **C2** (after a badge run): fitted table checked in, README updated,
  reflections timing-overlay number compared with the calibrated model,
  residual reported.

## 9. Open questions

1. Where the coworker can capture USB console output easily (any serial
   terminal at the badge's CDC port should do; confirm the OS enables CDC
   in `sycl-badge/src/os/drivers/usb.zig`). If not, photos suffice.
2. Whether to also time a kernel with core 0 deliberately idle (vsync
   disabled and no present for a few frames) to separate LCD DMA from
   core 0's own SRAM traffic. Cheap to add as a third phase; default yes.
3. Whether the fitted table should be per-badge or shared. Same silicon
   and clock, so shared; keep the badge id in the file anyway.

## Status

- 2026-09-27: spec written. Nothing built. Adrian plans to implement it in
  a fresh session; start at C0 with `../PLAN.md`, this file and
  `snouty-reflections/build.zig` open.
