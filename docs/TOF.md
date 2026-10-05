# Time-of-flight sensor carts

The conference organizer gave Adrian a SparkFun Qwiic Mini dToF Imager
(ams OSRAM TMF8820) for the badge's Qwiic I2C port (2026-10-05). This
document holds the hardware facts, how carts talk to the sensor, the
shared library, the plan, and the hardware checks Adrian runs.

## 1. The sensor (datasheet DS000693 v5)

- I2C address 0x41, up to 1 MHz (Fast-mode Plus). 3.3 V. The SparkFun
  breakout has the Qwiic pull-ups.
- Boots into a ROM bootloader (appid 0x80). The host downloads a 2.5 KB
  RAM application (`tof_bin_image`, 0x9AC bytes at 0x00200000, from
  SparkFun's MIT library `src/tof_bin_image.c`, ams firmware for use
  with ams parts) and remaps to it (appid 0x03). ~50 ms at 1 MHz; must
  be repeated after every power loss.
- **3x3 zones only** on the 8820 (4x4/3x6 are the 8821, 8x8 the 8828).
  Pre-defined SPAD maps: 1 = normal 33x32 deg, 2/3 = macro, 6 = wide
  41x52 deg, 11/12 = checkerboard.
- Ranging period vs iterations (3x3): 50 k = 6.1 ms, 550 k = 32.2 ms
  (default, 30 Hz), 4 M = 230 ms. Up to two objects per zone with a
  confidence each, 1 mm steps, 5 m range; accuracy +-3 % beyond 333 mm,
  precision 2 mm (2 sigma); short-range high-accuracy mode up to 1 m.
- Raw histograms: HIST_DUMP (0x39) bit 0 makes the device dump 24-bit
  histograms with each result: 10 channels (channel 0 is the reference
  SPAD in the VCSEL cavity, 1..9 the zones), 128 bins each. From the
  datasheet's example, 35 bins span 2 m, so a bin is roughly 57 mm and
  128 bins cover ~7 m.
- User SPAD masks are allowed on the 8820 (spad_map_id 14: a single
  measurement, up to 9 zones). The SPAD array is 18x10; one SPAD covers
  2.4 deg (x) by 5.6 deg (y); every zone needs at least two adjacent
  SPADs; changing the mask invalidates the crosstalk calibration. This is
  the route to a finer still depth image (M2).

## 2. How the badge talks to it

- The Qwiic connector J2 is on GPIO12/13. On the SYCL 2026 production
  board (revision r2) GPIO12 = SDA, GPIO13 = SCL, which is exactly
  I2C0's pin mux. Revision r1 (purple dev boards) has them the other way
  round, which I2C0 cannot do; r0 has no connector. The carts support r2.
- The OS sets the pins to the I2C function and initialises I2C0 at boot
  (`sycl-badge/src/os/drivers/i2c.zig`), but `poll()` is a TODO: there is
  no cart API, in the pinned SDK or upstream (5955625). Carts therefore
  drive I2C0 (DW_apb_i2c at 0x40090000) directly from core 1, as
  lib/link_rp2350.zig drives PIO2. No firmware change; works on the show
  badges' stock OS. ACCESSCTRL's reset value for I2C0 (0xfc) lets core 1
  reach it.
- `lib/i2c_rp2350.zig` resets I2C0 itself (RESETS bit 4), sets the pads
  (input enable, 4 mA, pull-up, Schmitt, slow slew) and pin functions
  (funcsel 3), and programs fast-mode timing from clk_sys (150 MHz) the
  way pico-sdk's `i2c_set_baudrate` does, for 100 kHz, 400 kHz (the
  default) or 1 MHz. Transactions are blocking but short and bounded: a
  timeout of twice the wire time plus 2 ms, then an abort, nine SCL
  pulses and a STOP bit-banged through SIO (bus recovery) and a fresh
  set-up.
- Neither the simulator nor badge-bench has a sensor. `lib/tof_virtual.zig`
  is a register-level model of the TMF8820 with a synthetic scene: the
  wasm build always uses it, a badge build uses it with `-Dtof-fake=true`
  (for badge-bench; its bus then busy-waits each transfer's wire time so
  the update times include it, and the cart runs its clock on the frame
  count because badge-bench's timer stops during vsync waits), and the
  host tests run the real driver against it. badge-bench's I2C0 fake
  (`os_fake.py` `I2C0Fake`) NACKs every address, so a normal badge build
  benches its "no sensor" path.

## 3. The library

- `lib/tof_types.zig`: the data carts see (`Frame`, `Zone`, `Target`,
  `Histograms`, `Orientation`). Fixed before M0 so cart tracks could
  start; unchanged by M0.
- `lib/i2c_rp2350.zig`: I2C0 master (`Bus`; `NullBus` off the badge),
  `cost_us` (the estimated time of a transaction, which the driver
  budgets with and the model advances its clock by), `Scan` (a rolling
  scan of 0x08..0x77 with one-byte reads, a few addresses per update),
  `Stats` (NACKs, timeouts, the last abort source, recoveries) and
  `lines()` (SDA/SCL levels).
- `lib/tof.zig`: the TMF8820 driver, `Tof(Bus)`; `tof.Sensor(fake)` and
  `tof.open(fake, hz)` pick the bus (I2C0 on the badge, the model in the
  simulator or with `-Dtof-fake=true`). `poll(now_us)` every update does
  at most `budget_us` of estimated bus time (default 3 ms: a whole result
  read at 400 kHz, so a 30 Hz sensor needs one poll per frame; the probe
  cart uses 6 ms on its histogram page). Every step is one transaction;
  long reads are split to fit the rest of the poll. Exposes `state`,
  `latest()` (the `Frame`), `histograms()`, `err` (code, step, raw
  status, time), a 16-entry step log, `info` (IDs, versions, serial,
  active range, the firmware's default configuration), `stats`
  (frames, missed and duplicate result numbers, torn reads, I2C errors,
  histogram sets, ...), `download_us`, `configure(.{ spad_map,
  iterations_k, period_ms, histograms, short_range })` (stops,
  reconfigures and restarts a running sensor), `restart()` (re-probe,
  keeping a running application) and `reload()` (CPU reset and a fresh
  download). Errors retry after 1 s; an absent sensor is re-probed every
  500 ms; no result for 1 s (or 4 periods) while measuring restarts it
  (a power glitch). Clock correction (the ams driver's
  `clock_skew_correction`, under 1 %) is not done.
- `lib/tof_virtual.zig`: the model above (header comment lists what it
  models), with fault injection (absent, a NACK / timeout / abort at the
  Nth transaction, stuck busy, bootloader rejecting chunks, a RAM image
  that does not start, no active-range commands).
- `lib/tof_firmware.bin` (+ `.NOTICE.md`): the 2476-byte RAM application.

### Protocol as implemented, and where each detail comes from

DS = datasheet DS000693 v5; C = ams's host driver inside SparkFun's
library (`tmf882x_mode_bl.c`, `tmf882x_mode_app.c`, `tmf882x_mode.c`).
The hardware check (section 5) confirms the C-only items.

| Detail | Source |
|---|---|
| ENABLE 0xE0: PON bit 0, cpu_ready bit 6, powerup_select bits 5:4; only 0xE0 readable in standby; ID 0xE3 = 0x08 (low 6 bits), REVID 0xE4 | DS 8.2 |
| Wake: write PON, wait for cpu_ready (C polls every 3 ms, up to 10 tries) | DS + C |
| Bootloader commands from 0x08: `cmd, size, data, csum`, csum = ~(cmd + size + data); status busy while >= 0x10 | DS 8.9 + C |
| DOWNLOAD_INIT seed 0x29, ADDR_RAM 0x0000 (the image's 0x00200000 as a 16-bit pointer), W_RAM up to 128 bytes, RAMREMAP_RESET with no status read | C (`bin_fwdl`) |
| Set powerup_select = 2 before RAMREMAP_RESET | DS 8.9.5 only; the C does not. The driver alternates: odd attempts write it (the log shows `bl_remap_ps`) |
| Bootloader status reply carries a checksum (`status + size + csum = 0xFF`) | C checks it only for replies with data; not in DS. Counted (`CK` on DIAG), not fatal |
| 10 ms after RAMREMAP and again after cpu_ready before using the application | C (`tmf882x_wait_for_cpu_startup`) |
| CPU reset: powerup_select = 1, then 0x80 to 0xF0 (the C also clears bit 6 of 0xEC first; skipped) | C only (`tmf882x_mode_cpu_reset`); register 0xF0 is undocumented in DS |
| CMD_STAT 0x08 busy while >= 0x10; 0 OK, 1 accepted; STOP 0xFF, MEASURE 0x10, LOAD_CONFIG_PAGE_COMMON 0x16, WRITE_CONFIG_PAGE 0x15 | DS 8.3 + C |
| Configuration page at 0x24: period, kilo-iterations, SPAD map 0x34, HIST_DUMP 0x39; edited in place, written back | DS 8.5 + C |
| Short range: commands 0x6E / 0x6F to CMD_STAT, register ACTIVE_RANGE 0x19 reports 0x6E / 0x6F (0 = not supported) | DS 8.3.11 gives the register values; the commands are from memory of later ams drivers, unverified. A failure is noted, not fatal |
| INT_STATUS 0xE1 bit 1 result, bit 3 histogram; write 1 to clear; INT_ENAB 0xE2 | DS 8.2.4/8.2.5 |
| Result record at 0x20: rid 0x10, tid, size, result number 0x24, temperature, ambient 0x28, photons 0x2C, reference 0x30, sys tick 0x34, 36 triplets from 0x38 | DS 8.4 + C |
| 3x3: first object of zone z in triplet z, second object in triplet 18 + z (9..17 empty) | C (`RESULT_IDX_TO_CHANNEL` / `_SUB_CAPTURE`); DS only says "zone 2 to the last zone". DIAG's `MT` counts frames with non-zero triplets 9..17 |
| Histograms: 30 subpackets (rid 0x81, number 0x24, payload 0x80 at 0x25, data 0x27..0xA6) = 5 TDCs x 256 bins x 3 byte planes, LSB plane first | DS 8.8 (subpacket registers, payload always 0x80) + C (`decode_histogram_msg`: 5 TDCs, 256 bins, plane order) |
| Each TDC's 256 bins = two channels of 128: subpacket n is channel n % 10, byte plane n / 10; channel 0 the reference SPAD | Inferred (C has 2 channels per TDC, DS has 10 channels of 128 bins); confirm on HIST: channel 0 should show one huge peak at a low bin |
| The sensor publishes the next subpacket after the host clears INT bit 3; the result follows the last one | Inferred from the C's multi-packet loop (clear, then wait for the tid to change). The driver reads first and clears after, and files subpackets by their number |

### Timings (from the model, which runs the real driver; 60 Hz polls)

| Bus, budget | Download | Boot to measuring | Results | Histogram sets |
|---|---|---|---|---|
| 400 kHz, 3 ms | 350 ms | 0.45 s | 30 Hz, none lost | 1.7 /s |
| 400 kHz, 6 ms (HIST) | 170 ms | 0.27 s | 30 Hz | 3.6 /s |
| 1 MHz, 3 ms | 135 ms | 0.27 s | 30 Hz | 4.3 /s |
| 1 MHz, 6 ms | 68 ms | 0.20 s | 30 Hz | 8.6 /s |
| 100 kHz, 3 ms | 2.0 s | 2.1 s | 10 Hz (period 100 ms) | 0.2 /s |

At 100 kHz a result read (110 bytes, ~11 ms) spans several polls, so a
33 ms period overwrites results mid-read (counted as torn and dropped);
the probe cart sets a 100 ms period at 100 kHz. The real chip may differ
from the model in command and boot latencies (the model's: bootloader
1.5 ms to cpu_ready, application 3 ms, commands 250 us, bootloader
commands 40 us).

## 4. Plan

### M0: the driver and a probe cart (`snouty-sense`)

- lib/i2c_rp2350, lib/tof, lib/tof_virtual, host tests that boot,
  download, configure, measure and dump histograms against the model,
  including NACK, timeout and bad-checksum paths.
- `carts/snouty-sense`, first pages:
  - LIVE: the 3x3 grid in false colour with mm and confidence per zone,
    second object marked, frame rate, temperature, ambient.
  - HIST: one zone's live histogram (zone picked with the stick), with
    the detected targets marked.
  - DIAG: bus scan (every ACKing address), sensor IDs/revision, driver
    state and last error, firmware download time, I2C speed, register
    dump, frame counters. What Adrian photographs when it does not work.
  - Orientation (flip X / flip Y / rotate) chosen on the badge, since
    how the breakout faces depends on the cable.
- badge-bench: I2C0 NACK fake; `-Dtof-fake=true` build benched too.
- Gate: `zig build`, `zig build test`, bench under 16.7 ms, preview GIF
  from the wasm build (virtual sensor), hardware check list below.

### M1: theremin (`snouty-theremin`)

- Hand distance to pitch, glide, with a second hand on the other column
  for volume (two-hand layout) or one-hand mode (pitch only).
- Scale snap (off, chromatic, major, pentatonic), waveform choice, natural
  vibrato from hand wobble, a scope and the note name on screen.
- No sensor: the stick plays it (Up/Down pitch), so it works in the
  simulator and on a badge without the breakout.
- Sound: its own continuous-phase voice rendered into lib/stream_audio's
  ring. Boots with sound ON (the cart is an instrument); Select mutes and
  the mute state is shown on screen (deferred question 1).
- Status 2026-10-05: built on branch `tof/theremin` against
  `lib/tof_types.zig` only; `carts/snouty-theremin/cart/src/input.zig`
  `sensor_frame` is the one place lib/tof.zig plugs in. Merged to main
  with the stick only, then wired to the driver (`cart/src/sensor.zig`,
  wide SPAD map 6 for two hands; tag snouty-theremin/m1.1).
  carts/snouty-theremin/PLAN.md has the bench numbers and the cart's own
  questions.

### M2: Sensor Eyes and the depth photo (`snouty-sense` pages)

- EYES: all nine histograms as a scrolling waterfall; sound mode that
  plays the hand's histogram as a wavetable (your hand shapes the
  timbre).
- DEPTH: slow-scan still depth photo from user SPAD masks (target ~9x10
  from SPAD pairs, cycling layouts host-side), false colour plus a
  spinning point cloud. Needs hardware to prove mask switch time, dead
  SPADs and calibration.

### M3: Snouty Morph (`snouty-morph`)

- A demoscene mesh (torus knot, Boing ball, Snouty head, Iris mark) that
  follows the hand in 6DoF and deforms with it (reach, jelly, twist,
  punch shockwave); a ghost hand in attract mode, stick fallback.
- `lib/tof_pose.zig`: hand pose from the 3x3 frame (background model,
  coverage centroid, plane-fit tilt, moment yaw, One Euro filters) and
  `lib/tof_synth.zig` (synthetic frames for tests and the ghost hand).
  Design and honest limits in carts/snouty-morph/SPEC.md.

### M4 (later): gestures and hand modes

- `lib/tof_gesture.zig` (swipe, push/pull, height, presence) and hand
  modes for existing carts (Flyover altitude, Reflections ripple,
  Demosnout speed), wake-on-approach attract.

## 5. Hardware checks (Adrian)

You need: an r2 (production) SYCL badge, the SparkFun Qwiic Mini dToF
Imager, a Qwiic cable. Build from the repository root:

```sh
zig build -Dcart=snouty-sense      # zig-out/firmware/snouty-sense.uf2
```

Flash `snouty-sense.uf2` the usual way, plug the breakout into the
badge's Qwiic port (the cable can go in before or after the cart
starts; unplugging and replugging while it runs is fine and part of the
test), and start the cart. Left / Right switch pages (LIVE, HIST, DIAG;
the three dots top right show which).

1. **Boot.** Within about half a second LIVE should show "STARTING
   SENSOR", a firmware progress bar, then the 3x3 grid. If it stays on
   "NO SENSOR", or shows an error, go to DIAG and photograph it (step 4).
2. **LIVE.** Hold a hand 20-40 cm in front of the sensor and move it:
   the cells under it turn orange/red with smaller numbers, the rest show
   the wall or ceiling (green/blue, larger numbers or "----" beyond
   range). The header shows the frame rate (expect about 30 Hz) and the
   die temperature. Find the orientation that makes the grid move the way
   your hand does, with A (flip X), B (flip Y) and Up (transpose); the
   active ones turn green at the bottom. **Photograph LIVE with your hand
   in one corner of the view and tell me which corner, and which
   orientation buttons you needed** (that sets the default, section 6
   question 2). Down switches the SPAD map to the wide one (`W` in the
   header) and back (`N`).
3. **HIST.** Histogram dumps switch on here (the frame rate drops to a
   few Hz). Up / Down pick the channel: `CH0 REF` should show one tall
   narrow peak at a low bin (the reference SPAD); `CH1..9` the zones,
   each with a peak near bin 15 (crosstalk) and one per object, marked
   by the green (N, nearest) and yellow (F) ticks at the top, with the
   object's distance, confidence and bin below. A switches linear / log.
   **Photograph CH0 and CH5 with your hand about 30 cm away.** If CH0
   shows no big peak, or the marks are far from the peaks, the channel
   layout or bin scale in section 3 is wrong and the photo shows how.
4. **DIAG.** The page to photograph whenever anything looks wrong. Rows:
   - state (green `measuring` is good); `ERR` code, the step it happened
     at and its raw status (`R....`, e.g. bootloader status or
     `cmd << 8 | status`), or the current step when there is no error;
   - `ID08 R. A03 V.....`: chip ID (must be 08), revision, application
     ID (03 = running, 80 = bootloader) and version;
     `BL.. SN........ AR..`: bootloader version, serial number, active
     range register (6F long, 6E short, 00 no support);
   - `FW...MS D. S.. M..`: firmware download time, downloads so far (`R`
     = reused an application already running), application and measure
     status registers;
   - `I2C400K SDA1 SCL1 E.`: speed, line levels (both 1 when idle; a 0
     means a line is held low: wrong board revision, a short, or a
     device stuck mid-byte) and the I2C error count;
   - `AB........ TO. RC.`: the controller's last abort source
     (00000001 = address not acknowledged), timeouts, bus recoveries;
   - `SCAN ..`: every address that acknowledges (41 is the sensor; other
     numbers are other things on the bus; `NONE` with the sensor plugged
     in means wiring, revision or power);
   - `FR. MS. TN. CK.`: frames, missed result numbers, torn reads,
     bootloader replies whose checksum did not add up (non-zero only
     says the reply has no checksum, not an error);
   - `POLL a/bMS MT.`: the driver's time this update and the worst in
     the last second (should stay under ~3 ms on LIVE, ~6 ms on HIST),
     and frames whose triplets 9..17 were not empty (non-zero means the
     two-object layout guess is wrong);
   - the last four driver steps with their time (ms) and status (red =
     error).
5. **1 MHz.** On DIAG press A to cycle the speed 400K -> 1000K (-> 100K
   -> 400K); the driver restarts on the new speed, keeping the running
   firmware. Then press B (reload: CPU reset and a fresh download) to
   measure the download time at that speed (`FW...MS`, expect ~70-140 ms
   at 1 MHz, ~170-350 ms at 400 kHz). If 1 MHz shows errors, timeouts or
   a stuck `SCAN`, photograph DIAG; 400 kHz stays the default either way.
6. **Unplug / replug.** Pull the cable while measuring: within a frame or
   two LIVE shows NO SENSOR (DIAG: `absent`, `ERR lost`); plug it back:
   it boots again (`D` goes up by one) and measures.

Send the photos of LIVE (hand in a corner + which corner), HIST CH0 and
CH5, and DIAG after boot, after the 1 MHz reload, and of anything that
went wrong.

## 6. Deferred questions

1. Theremin boots with sound on (it is an instrument) instead of the
   repo's boot-silent rule; Select mutes. Flip if Adrian prefers silent.
2. Default zone orientation: decided from the M0 hardware photos.
