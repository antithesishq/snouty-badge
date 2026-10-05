# Snouty Sense (PLAN)

The time-of-flight probe cart and the driver under it (docs/TOF.md
section 4). SPEC.md has the design, docs/RUNNING.md how to build and run.

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

Status: in progress. Plan (docs/TOF.md section 4):

- [ ] `lib/tof_spad.zig`: the user SPAD mask (up to 18x10, channel per
      SPAD, Q1 offsets), the datasheet's constraints as a validator, the
      SPAD configuration page (cid 0x17, registers 0x24..0x90) encoder and
      decoder in the ams driver's layout, the depth-scan layouts.
- [ ] `lib/tof.zig`: `set_user_mask` (validate, then stop -> common page
      with spad_map_id 14 -> load SPAD page 0x17 -> write it -> write
      config -> read it back and compare -> measure), mask generation per
      frame, switch time, read-back mismatches; DIAG rows for them.
- [ ] `lib/tof_virtual.zig` + `lib/tof_scene.zig`: the SPAD page in the
      model (load, validate, reject, read back) and a SPAD-level scene
      (tilted wall, floor, box, moving sphere, dead SPADs) that zone
      results under spad_map_id 14 are rendered from.
- [ ] `lib/tof_depth.zig`: the slow-scan depth photo (pairs: 9x10 in 10
      shots; fine pass: 17x10 in 20), N frames per layout, missing and
      low-confidence pixels.
- [ ] Host tests: valid / invalid masks, encode / decode, read-back,
      switch timing, zone results against the SPAD scene, a whole photo.
- [ ] EYES page: nine-zone waterfall (log, crosstalk and reference
      dimmed, targets traced), wavetable sound from the hand's histogram
      (boots silent, A toggles, seeded from `-Dsound`).
- [ ] DEPTH page: false-colour image, progress, scan time, spinning point
      cloud (A), exposure (Up / Down), restart (B), fine pass (Select).
- [ ] badge-bench: both builds, every page; docs; preview GIF.
