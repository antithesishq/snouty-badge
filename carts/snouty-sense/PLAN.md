# Snouty Sense (PLAN)

The time-of-flight probe cart and the driver under it (docs/TOF.md
section 4). SPEC.md has the design, docs/RUNNING.md how to build and run.

## M2.2: histogram pages on hardware (2026-10-05)

With M2.1 the sensor recovered, and HIST/EYES showed what was really
wrong: `ERR frame_timeout` every few seconds, EYES filling its waterfall a
few lines at a time, and DIAG `ERR bad_rid @read_cfg R0010` after leaving
HIST. The driver read a dump over ~30 updates (~0.5 s) while the sensor
measured every 33 ms. The model held each measurement until the host
finished a dump; the real sensor evidently abandons the dump (and its
result) when the next measurement falls due. New model faults
`hist_overrun` and `late_result_us` reproduce both (0 results and 0 sets
in 10 s on the old driver; bad_rid on leaving HIST).

- With histograms on, the ranging period becomes `Tof.hist_period_ms()`:
  long enough to read a whole dump at the bus speed and the poll budget
  (HIST/EYES budget now 12 ms: 3 subpackets an update; 255 ms = ~4 sets
  a second at 400 kHz, 127 ms = ~7 at 1 MHz, ~1.3 s at 100 kHz).
- The next subpacket is awaited on its TID (1 byte) with immediate
  re-reads, as the C does, instead of re-reading the whole packet a poll
  later.
- A stall with histograms on first clears every interrupt and resyncs
  (DIAG `ST`); only a second one restarts the sensor.
- After STOP the driver clears all interrupts, and a configuration page
  that reads back as a result is loaded again (DIAG `CR`, up to 3 times).
- DIAG: new row `RS ST CR P..MS` (rescues, stalls, config reloads, the
  ranging period in use); the step log shows 3 entries.
- Bench (`-Dtof-fake`, calibrated, 1800 frames, bench.json): worst 14.86
  ms (EYES with sound, frame 660: three subpackets on the bus that
  update), mean 6.03, p95 14.32, 0 frames over 16.7 ms. Tight but only on
  the histogram pages; lower `budget_hist_us` to 8000 (2 subpackets an
  update, ~2.8 sets a second at 400 kHz) if a badge drops frames there.

## M2.1: recovery fix from the first badge run (2026-10-05)

On Adrian's badge snouty-sense measured on LIVE, then (with a hand over
the unmounted breakout) failed and never came back: `STARTING SENSOR ...
FIRMWARE 2476/2476 ERR cpu_timeout @wait_ready R0021 RETRYING`, on every
page. ENABLE 0x21 = PON with powerup_select 2 and cpu_ready never set.
The first boot (the ams driver's sequence) is proven on hardware; the
recovery path was not, and differed from the C in two ways:

- Every other retry set powerup_select = 2 before RAMREMAP_RESET (a
  DS 8.9.5 variant). It survives resets and standby, so the next CPU
  reset started a stale "RAM application" and hung. Removed; a 2 found
  at remap time is cleared (`bl_clear_ps`), and every CPU reset writes 1.
- The CPU reset skipped the C's PLL-off step (0xEC bit 6). Added.
- New: cpu_ready late -> one forced CPU reset, then a standby cycle, then
  the error (`stats.rescues`, DIAG `RS`).
- The status screen and DIAG now show the FIRST error of a failure run
  (`1ST ...`): the latest one is usually the recovery's, not the cause.
  What tripped the first failure is still unknown (the photo of `1ST`
  will say).

Model: `Fault.ps2_hang` and `Fault.reset_needs_pll_off` reproduce both;
host tests: a chip left at 2 recovers on reload, a hung chip is rescued
by a forced reset within the first attempt, resets never hang on the
PLL, and 24 injected failures of every kind all come back with no
powerup_select 2 remap.

## M0: driver, model and probe cart (branch `tof/m0`)

Status: built, host-tested and benched against the model; **waiting for
the hardware check** (docs/TOF.md section 5).

- [x] `lib/i2c_rp2350.zig`: I2C0 master, bounded transactions, bus
      recovery, `Scan`, `cost_us`, 100 / 400 / 1000 kHz.
- [x] `lib/tof.zig`: TMF8820 driver as a budgeted state machine
      (bootloader download, configuration, results, raw histograms,
      `configure` / `restart` / `reload`, retries, re-probe, frame
      timeout), step log, diagnostics.
- [x] `lib/tof_virtual.zig`: register-level model with a synthetic scene
      and fault injection; the simulator and `-Dtof-fake=true` use it.
- [x] `lib/tof_firmware.bin` (+ NOTICE): the ams RAM application from
      SparkFun's MIT library, extracted by `tools/tof_firmware_bin.py`.
- [x] `lib/tests/tof_unit.zig` (in `zig build test`): boot at every
      speed (every bootloader checksum verified by the model), frames
      against the model's scene with none lost at 400 kHz, histograms bin
      for bin, configure / restart / reload, short range with and without
      firmware support, absent / unplug / replug / power glitch, a NACK,
      timeout, arbitration loss or abort at every third transaction of
      the boot, stuck busy (bootloader and application), bootloader
      rejection, an image that does not start (CPU reset path), the bus
      scan, the log, orientation; every poll's bus time within the budget.
- [x] `carts/snouty-sense`: LIVE, HIST, DIAG, NO SENSOR / starting.
- [x] badge-bench: `os_fake.py` `I2C0Fake` (every address NACKs, not
      reported as unexpected traffic), `badge-bench/carts/snouty-sense.toml`
      and `tools/scripts/bench.json` (LIVE, HIST at 300, DIAG at 600).
- [x] `docs/preview_m0.gif` (wasm build, virtual sensor).
- [ ] Hardware check (Adrian, docs/TOF.md section 5).

### Bench (2026-10-05, calibrated, 900 frames, worst `busy ms`)

| Build | LIVE (0..299) | HIST (300..599) | DIAG (600..899) | Mean |
|---|---|---|---|---|
| `zig build -Dcart=snouty-sense` (no sensor: I2C0 NACKs) | 2.76 | 2.76 | 3.02 | 2.84 |
| `-Dtof-fake=true` (virtual sensor, wire time busy-waited) | 5.37 | 7.81 | 7.54 | 5.80 |

Worst 7.81 ms of 16.7 (47 %). The fake build's numbers include the bus
time the real I2C would take (the virtual bus spins for each transfer's
`cost_us`), so they approximate the badge with a sensor: drawing ~2.7-3
ms (mostly `api.text`) plus up to the driver's budget (3 ms LIVE / DIAG,
6 ms HIST) plus the bus scan on DIAG (8 probes, ~0.5 ms). Size: text
58 KB, bss 11 KB.

Model timings at 60 Hz polls (docs/TOF.md section 3): boot to measuring
0.45 s at 400 kHz (download 350 ms), 0.27 s at 1 MHz; 30 Hz results with
none lost at 400 kHz and 1 MHz; histogram sets 3.6 /s at 400 kHz and
8.6 /s at 1 MHz on HIST's 6 ms budget.

### What the hardware check must confirm

From the ams C driver, not the datasheet (docs/TOF.md section 3 table):
second objects in triplets 18..26 (DIAG `MT` should stay 0); the
histogram channel layout (CH0 = reference: one tall low peak); the
subpacket handshake (HIST sets keep coming, `hist_errors` low); the
bootloader reply checksum (DIAG `CK`, informational); the CPU reset via
0xF0; the short-range commands 0x6E / 0x6F (not used by the cart yet).
From the datasheet only: powerup_select = 2 before RAMREMAP (the driver
tries both: odd attempts write it). Unknown: real command latencies,
whether 1 MHz works over the Qwiic cable, the default orientation.

### Deferred questions

1. Default orientation of the grid (docs/TOF.md section 6 question 2):
   from Adrian's LIVE photo with a hand in a known corner.
2. Keep 400 kHz as the default, or 1 MHz if the hardware check shows it
   works?
3. Clock correction (the ams driver's distance scaling by the host /
   sensor clock ratio, under 1 %) is skipped; add it if accuracy matters
   for M2.
4. Factory calibration (crosstalk) is never run or loaded; the ams
   driver supports it. Worth it only if the hardware shows crosstalk
   problems at short range.

## M2: EYES and DEPTH pages, user SPAD masks (branch `tof/m2`)

Status: built, host-tested and benched against the model; nothing has
run on hardware: **waiting for the hardware check** (docs/TOF.md section
5, M2 addendum steps 8 and 9, after the M0 steps).

- [x] `lib/tof_spad.zig`: the user SPAD mask (up to 18x10, channel per
      SPAD, Q1 offsets), the datasheet's constraints as a validator, the
      SPAD configuration page (cid 0x17, registers 0x24..0x90) encoder and
      decoder in the ams driver's layout, the depth-scan layouts.
- [x] `lib/tof.zig`: `set_user_mask` (validate, then stop -> common page
      with spad_map_id 14 -> load SPAD page 0x17 -> write it -> write
      config -> read it back and compare -> measure; mask-only switches
      while on map 14), `frame_mask_gen`, `stats.mask_writes`,
      `mask_rejects`, `spad_mismatch` / `spad_diff`, `mask_switch_us` /
      `_max_us`; `poll` is `noinline` (see Bench).
- [x] `lib/tof_virtual.zig` + `lib/tof_scene.zig`: the SPAD page in the
      model (load, validate, reject with 0x02, ignore with 0x0A without
      map 14, read back; fault `spad_corrupt`) and a SPAD-level scene
      (tilted wall, floor, box, slowly drifting ball, five dead SPADs)
      that zone results under spad_map_id 14 are rendered from.
- [x] `lib/tof_depth.zig`: the slow-scan depth photo (pairs: 9x10 in 10
      shots; fine pass: 17x10 in 20), N frames per layout, missing and
      low-confidence pixels, repeat.
- [x] Host tests (lib/tests/tof_unit.zig, lib/tof_spad.zig,
      lib/tof_scene.zig): every layout valid and the 17 columns covered
      once, encode / decode inverse, each broken rule refused, a mask
      written with map 14 and read back, frames equal to the SPAD scene,
      refused masks never sent, the model rejecting / ignoring pages, a
      corrupted read-back counted and not fatal, mask-only switches, the
      normal map back, the mask rewritten after a reload, a whole photo
      (both passes) matching the scene with the dead pair missing.
      Cart: `cart/src/host_tests.zig` (the EYES voice and feeder).
- [x] EYES page (eyes.zig, audio.zig): nine-zone waterfall, wavetable
      sound (boots silent, A toggles, seeded from `-Dsound`).
- [x] DEPTH page (depth_view.zig): PHOTO / CLOUD / MASK, exposure, new
      photo, fine pass; leaving it restores the normal map.
- [x] badge-bench: both builds, every page (`tools/scripts/bench.json`,
      1800 frames); `docs/preview_m2.gif` (wasm build, virtual sensor).
- [ ] Hardware check (Adrian, docs/TOF.md section 5 steps 8 and 9).

### Bench (2026-10-05, calibrated, 1800 frames, worst / mean `busy ms`)

| Build | LIVE 0..299 | HIST 300..599 | EYES 600..899 | DEPTH 900..1499 | DIAG 1500..1799 | All |
|---|---|---|---|---|---|---|
| no sensor (I2C0 NACKs) | 2.76 / 2.76 | 2.76 / 2.76 | 3.56 / 2.98 | 3.13 / 3.03 | 3.41 / 3.30 | 3.56 / 2.97 |
| `-Dtof-fake=true` | 5.38 / 4.00 | 7.81 / 7.51 | 8.41 / 8.12 | 8.47 / 4.50 | 7.46 / 6.06 | 8.47 / 5.78 |

Worst 8.47 ms of 16.7 (51 %), in DEPTH's CLOUD view on the fake build
(over half of it the virtual bus waiting out the wire time, as a real
sensor's I2C would). The sound is on from frame 660 in both runs (the
ring is fed every update from then on, ~0.3 ms): no underruns. No-sensor
EYES / DEPTH show the NO SENSOR screen. Size (no sensor): text 94 KB,
data 6 KB, bss 28 KB.

The other sensor carts in their no-sensor paths, against c33e9785:
snouty-theremin 0.93 / 0.56 (unchanged), snouty-morph 9.34 / 4.69
(unchanged). With the driver's `poll` inlined, morph's own float code
compiled worse (+0.12 ms a frame mean, +0.10 worst); `poll` is
`noinline` since. Their text grows by ~5 KB (the mask steps in the
driver): theremin 57 KB, morph 101 KB.

### Model numbers (not hardware; docs/TOF.md section 4)

60 Hz polls, the model's command latency (250 us) and 33 ms period:

| Bus, budget | Mask switch (last / first from map 1) | 9x10, N = 1 / 2 / 4 | 17x10, N = 2 |
|---|---|---|---|
| 400 kHz, 3 or 6 ms | 99 / 119 ms | 1.00 / 1.33 / 2.00 s (89 / 67 / 44 px/s) | 2.67 s (63 px/s) |
| 1 MHz, 3 or 6 ms | 133 / 166 ms | 1.33 / 1.67 / 2.17 s | 3.33 s (50 px/s) |

At 1 MHz the three immediate busy re-reads (`timing.busy_spins`) end
before a 250 us command does, so each command waits a poll; at 400 kHz
they outlast it. A switch is about three polls plus a measurement
period.

### What the hardware check must confirm (M2)

All inferred or from the ams C driver only (docs/TOF.md section 3): the
SPAD page layout and the common-page-first order (`R150A` would refute
it), that command 0x17 loads the page, the read-back (`RB0`), which way
the page's rows and columns face (the PHOTO with a hand in a corner),
channel c in triplet c - 1, whether the first frame after a switch is
clean, the real switch time and photo rate, dead SPADs (hatched pixels
on a flat wall), and how bad uncalibrated crosstalk is under a user
mask.

### Deferred questions (M2)

1. If 1 MHz works on hardware, a time-based busy wait (instead of three
   immediate re-reads) would make mask switches a poll faster there.
2. The scan keeps no frame after a switch (`Scan.settle` = 0); raise it
   if the hardware's first frame after a switch carries the old layout.
3. Crosstalk calibration per user mask (DS 7.3) is not done (M0
   question 4); the photo's nearest pixels may show it.
4. EYES boots silent (repo rule) unlike the theremin; `-Dsound=true`
   boots with it on.
5. The fine pass interleaves two passes taken over a second apart: anything
   moving in between smears into stripes (a rolling shutter).
