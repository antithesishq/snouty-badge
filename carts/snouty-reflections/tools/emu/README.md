# tools/emu: emulated cycle benchmark

Runs the ray tracer on an emulated Cortex-M33 (unicorn) and counts every
executed instruction, then prices each one with a simple M33 cycle model.
It answers "did this change make the frame cheaper, and where does the time
go?" in seconds and without a badge. It is a model, not a measurement: the
badge's debug overlay (`zig build -Ddebug_overlay=true`) is the only real
number. Use the emulator to rank and compare changes, and hardware to
confirm them.

```sh
export PATH="$HOME/.local/bin:$PATH"   # example: wherever zig lives
tools/emu/run.sh                       # bench ELF, frames 0 and 300 (about 10 s)
tools/emu/run.sh --sweep               # plus the whole orbit, frames 0..575 step 25
zig build && tools/emu/run.sh --real   # plus the real cart ELF
tools/emu/run.sh --real --sweep --listing   # everything (about 1 min)
```

Needs `zig`, `node` and `python3` (3.9 or newer, with the `venv` module) on
`PATH`. The first run creates `tools/emu/.venv` and installs
`requirements.txt` (unicorn, capstone, pyelftools, numpy) into it; later
runs reuse it and reinstall only when `requirements.txt` changes. Delete
`.venv` to start over. Exit status is 0 when the frame 0 and 300 reference
checks pass, 3 when one fails, 1 on a setup error.

## What it runs

Two binaries, both built from the current `cart/src`:

- **Bench ELF** (`build/bench.elf`, always). `build.sh` copies every `*.zig`
  under `cart/src` except `main.zig`, `input.zig` and `overlay.zig` into
  `build/src/`, adds `src/entry.zig` (an exported `render_frame(frame)` that
  does what `main.update()` does around the render: set the dither mode,
  `dither.begin_frame`, `trace.render_frame`) and links it against a stub
  `cart-api` (`src/cart.zig`) with the badge's target, CPU features and
  `ReleaseFast`. `bench.py` calls `render_frame` directly. Because every
  pixel ends in one framebuffer store, the cost between two consecutive
  stores is that pixel's cost, which gives per-pixel and per-class numbers.
  New cart modules are picked up automatically; if the bench ever needs a
  module that needs the OS, add it to `EXCLUDE` in `build.sh` or stub it.
  `EMU_CART_SRC=/other/cart/src tools/emu/run.sh` builds another tree
  (for example an older tag from `git archive`) for an A/B.
- **Real ELF** (`zig-out/firmware/snouty-reflections.elf`, `--real`). The
  exact firmware you flash, started from its `_start`. `real.py` fakes just
  enough of the OS: the SIO FIFO (time sync and `FRAMEBUFFER_DONE` replies),
  TIMER0 and DWT_CYCCNT. Each window between two present() messages is one
  whole `update()` (input, dither, render, present), so it includes codegen
  effects the bench cannot see, such as the render being inlined into
  `update`. `main.frame` and `dither.mode` are poked before each window.
  The ELF is snapshotted to `out/real.elf` first, so a rebuild during a run
  does not mix binaries. Run `zig build` first.

Both render in dither mode `none` by default (`--mode bayer` for the
default cart mode) and every frame 0 and 300 image goes through
`tools/check_render.mjs` against `tools/reference.py`, so a speed-up that
breaks the picture shows up as a FAIL in the same run. Sweep frames are
checked too, but a sweep FAIL is reported as informational: a grazing
sphere-edge pixel can exceed the 6-unit cap on precision alone
(docs/M1.md).

## The cycle model

`model.py`, issue cycles per instruction, code and data in zero-wait SRAM:

| Instruction | Cycles |
|---|---|
| most ALU, FP add/mul/sub/abs/neg, VMOV, VCVT, VCMP, VMRS, VSEL, VMAXNM | 1 |
| VDIV, VSQRT | 14 |
| VFMA/VFMS/VFNMA/VFNMS, VMLA/VMLS/VNMLA/VNMLS | 3 |
| LDR/STR (any width), VLDR/VSTR | 2 |
| LDRD/STRD | 3 |
| PUSH/POP, LDM/STM, VPUSH/VPOP, VLDM/VSTM | 1 + registers |
| SDIV/UDIV | 6 |
| taken branch (any non-fall-through block entry) | +1 |

Known blind spots, all of which make hardware slower than the model:

- **SRAM bus contention.** Core 0 drives the LCD by DMA out of the other
  framebuffer while core 1 renders; loads, stores and literal-pool reads can
  wait behind it. The model assumes every access gets the bus.
- **FP pipeline stalls.** The M33 FPU has result latency beyond its issue
  cost (a VMUL feeding the next instruction, VDIV/VSQRT blocking a later FP
  op that depends on them). The model counts issue slots only, so
  dependency chains are free.
- **VCMP/VMRS.** Every float compare is VCMP then `VMRS APSR_nzcv, fpscr`
  and a conditional; the VMRS waits for the compare. Priced at 1 + 1.
- **Branch cost.** A taken branch costs 2 in total here. There is no
  predictor, and targets that are unaligned 32-bit instructions, BX and
  POP-to-PC returns can cost more. Instructions inside an IT block are
  charged in full whether or not their condition passes, and the IT itself
  is 1.
- **Instruction fetch from SRAM.** The cart runs from SRAM, so instruction
  fetch goes over the S-AHB bus and competes with data accesses (and with
  core 0). Not modelled: fetch is free.

Treat the absolute milliseconds as a lower bound. At m1 the model said
48.6 ms per frame; compare with the badge overlay before trusting the
absolute scale, and use the relative changes (before vs after an edit)
with more confidence.

## Reading the output

The summary table, per run and frame: executed instructions, modelled
cycles, cycles per pixel (cycles / 20480), milliseconds at 150 MHz and the
fps that would give uncapped (the cart is locked to 20 fps, i.e. 50 ms),
VDIV and VSQRT executions per pixel, and the reference check verdict.

The per-class table groups bench pixels by the path their ray takes,
computed with `tools/reference.py`'s own helpers (`classify.py`), read left
to right from the eye: `sky`, `S>sky` (sphere, then sky), `W>S>W>sky`,
`S>W>S(lambert)` (depth-2 sphere hit shaded with Lambert), and `+sun` when
the final sky lookup takes the sun-glow branch. For each class: pixel count
and share of the screen, mean instructions and cycles per pixel, min/max,
and share of the frame's cycles. Row y=0 of every column also carries the
per-column setup, so it is left out of the means and reported on its own
line. The cost of a class is what one more pixel of that path costs, so
`share x mean cycles` is where the time goes: at m1 the two water-to-sky
classes were 45% of the screen and 55% of the cycles, which is why the
water normal and the sky lookup were the first targets. The `+sun`
variants show the price of the glow branch (about 27-35 cycles).

`--listing` writes `out/listing_{emu,real}_0000.lst`, the capstone
disassembly of every function that ran at least 1% of the frame's
instructions, each instruction annotated with executions per pixel, and
`out/categories_*.txt`: per-pixel counts of literal-pool loads, stack
spills, core/FP moves, conversions, compares and every VDIV/VSQRT site.
Search the listing for the addresses in the divide/sqrt site list.

## After a change

Edit `cart/src`, run `tools/emu/run.sh` (it rebuilds the bench ELF every
time), compare the frame 0 cycles with the previous `out/summary.txt`, and
make sure both checks say PASS. Run `--sweep` before calling a change done:
the worst frame of the orbit (550 at m1) is what has to fit in 50 ms. Run
`zig build && tools/emu/run.sh --real` when the change could affect how
`update()` is compiled (inlining, `noinline`, globals).

## Outputs (`tools/emu/out/`, gitignored)

`summary.txt` (the printed report), `emu_FFFF.png` / `real_FFFF.png` and
`ref_FFFF.png` (frames and references), `diff_*` (amplified differences),
`pixels_FFFF.json` (per-pixel insn/cycles, index x*128+y),
`classes_FFFF.json`, `hist_FFFF.json` / `real_hist_FFFF.json` (mnemonic
histograms), `addr_FFFF.json` / `real_addr_FFFF.json` (per-instruction
execution counts), `result_*.json`, the listings, and `sweep/` with the same
per sweep frame. `build/` holds the copied sources, bench ELF and zig cache.

The Python scripts also run on their own with `tools/emu/.venv/bin/python`
(see each file's docstring): `bench.py`, `real.py`, `classify.py`,
`classes_report.py`, `categorize.py`, `disasm.py ELF [SYMBOL] --counts ...`.

## Baseline (m1 tag, 2026-09-27)

| Run | Insns/frame | Modelled cycles | Cyc/px | ms at 150 MHz |
|---|---|---|---|---|
| bench, frame 0 | 5,365,617 | 7,295,583 | 356.2 | 48.6 |
| bench, frame 300 | 5,169,143 | 7,079,328 | 345.7 | 47.2 |
| real ELF, frame 0 | 5,457,772 | 7,359,615 | 359.4 | 49.1 |

Orbit sweep (real ELF, frames 0..575 step 25): 344.5-364.8 cyc/px, worst
frame 550. The bench ELF over the same sweep: 341.4 (frame 100) to 361.7
(frame 550) cyc/px, all 24 frames PASS.

Per-class cost, bench frame 0, modelled cycles per pixel:

| Path | Cycles |
|---|---|
| sky | 150 |
| sky + sun glow | 184 |
| sphere -> sky | 218 |
| water -> sky | 413 (445 with sun) |
| water -> sphere -> sky | 477 |
| sphere -> water -> sky | 486 |
| water -> sphere -> water -> sky | 719 |

`EMU_CART_SRC=<m1 cart/src> tools/emu/run.sh` reproduces the bench rows and
the class table exactly.
