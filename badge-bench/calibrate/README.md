# badge-calibrate: measure the badge, calibrate the model

A cart that times 20 micro-kernels with the Cortex-M33 cycle counter, once
while core 0's LCD DMA is streaming the framebuffer ("busy") and twice
after it has finished ("idle"), and reports the results on screen and on
the USB console. The same ELF run through badge-bench yields the modelled
count for every kernel; `fit.py` turns measured over modelled into a
per-instruction-class cost table plus a DMA contention factor, and
`badge-bench --calibrate` then reports calibrated milliseconds instead of a
floor. Design: `SPEC.md`; build contract and deviations: `PLAN.md`.

## Files

```
calibrate/
  SPEC.md, PLAN.md      design and the C0/C1 contract
  build.zig             cart build module (registered in the root build.zig as badge-calibrate)
  cart/src/main.zig     frame schedule, pages, input, trace output
  cart/src/kernels.zig  K0..K19, one noinline function each, and the kernel table
  cart/src/harness.zig  cycle timing, min/median, checksum, trace formatting
  fit.py                capture + bench.json -> calibration.toml
  dist/                 prebuilt badge-calibrate.uf2 and the tester note
  calibration.toml      the fitted table, once a badge has been measured (C2)
```

## 1. Build and check in the emulator

```sh
cd /path/to/snouty-badge
zig build -Dcart=badge-calibrate
badge-bench/bench.sh zig-out/firmware/badge-calibrate.elf --json --symbols --traces 30
```

`badge-bench/carts/badge-calibrate.toml` makes that run 20 frames (one
pass) with `harness.skip_wait=1` poked in, so the cart skips its 8 ms DMA
wait under emulation. The 21 `CAL` trace lines it prints are the modelled
counts, in the same format the badge prints. `out/badge-calibrate/bench.json`
is the emulator side of the fit; keep it next to the hardware capture.

Self-test of the whole chain without hardware:

```sh
badge-bench/tests/test_calibrate_selftest.sh
```

## 2. Run it on the badge

1. Bootloader mode, plug in over USB-C, copy `dist/badge-calibrate.uf2`
   onto the drive (or `zig-out/firmware/badge-calibrate.uf2`).
2. Start the cart from the badge menu. It runs five passes of the 20
   kernels (about 2 s), then keeps showing the results. A = next page,
   B = start over.
3. Capture the console. The badge's OS console is a USB CDC serial port;
   any terminal works, the baud rate is ignored:

   ```sh
   # macOS
   ls /dev/cu.usbmodem*
   (stty raw; cat) < /dev/cu.usbmodemXXXX | tee capture.txt
   # or: screen /dev/cu.usbmodemXXXX 115200, then C-a H to log to screenlog.0
   # Linux: /dev/ttyACM0, same commands
   ```

   The OS prints `[CART] CAL k=0 n=... idle_min=... busy_min=... sink=...`
   after every pass and `[CART] CAL done pass=<p> sum=<hex>`. Any file
   containing those lines is a capture; `fit.py` uses the last complete pass.
4. No console? Photograph pages 1 and 2 (A cycles pages) and the summary
   page. Type the per-op numbers into a text file, one line per kernel,
   `k=<id> idle=<cycles per op> busy=<cycles per op>`, and use
   `fit.py --manual`. The checksum on the summary page lets a capture and
   a photo be matched.

## 3. Fit

```sh
badge-bench/.venv/bin/python badge-bench/calibrate/fit.py \
    --hardware capture.txt \
    --emulator badge-bench/out/badge-calibrate/bench.json \
    --out badge-bench/calibrate/calibration.toml
```

It prints, per kernel, ops, modelled cycles, idle and busy measured
cycles, and the two ratios; then the fitted cost per instruction class
against the default table, the residual, and the DMA contention factor.
`calibration.toml` holds all of it (layout in `PLAN.md`).

Then:

```sh
badge-bench/bench.sh zig-out/firmware/snouty-bugs.elf --calibrate badge-bench/calibrate/calibration.toml
badge-bench/tests/test_reflections.sh --calibrate badge-bench/calibrate/calibration.toml
```

The second command prints the calibrated ms of the ray tracer's reference
frames; compare with the number the timing build of snouty-reflections
shows in its corner (`carts/snouty-reflections/dist/README.md`). Agreement
within the fit's residual is the end-to-end check (milestone C2).

## Reading the results

- `idle` cycles per op is the core's own cost with an idle bus; the fit's
  cost table comes from these.
- `busy` over `idle` on the load/store kernels (K7 to K11) is the LCD DMA
  contention; on the compute kernels it should be about 1. If it is not,
  instruction fetch from SRAM is also contended and the README of
  badge-bench should say so.
- K2 against K1 gives the VMUL result latency for dependent chains; K6
  against K4 tells whether VDIV pipelines. Neither is a per-instruction
  class, so they appear as residual: the report prints both ratios.
- The emulator reports `busy == idle` because its OS never touches the bus.

## Status

See `PLAN.md` ("Status") and the milestones in `SPEC.md` section 8.
