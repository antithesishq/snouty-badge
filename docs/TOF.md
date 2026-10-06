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
  the route to a finer still depth image (M2: `lib/tof_spad.zig`, the
  DEPTH page).

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
- M5: `lib/tof_zones.zig` (the GRID and STRIPES layouts as screen
  geometry after the orientation: per screen cell the device zone,
  centre angles and tangents, widths; which axes resolve), `Layout` and
  `Frame.layout` in tof_types, `tof_spad.stripes()`, `Tof.set_layout`
  / `zone_layout`, `Estimator.set_layout` and the arm-rejected pose
  (`Pose.height_mm`, `near_mm`, `cluster`, `depth_mm`, `cols`, `rows`,
  `has_x`, `has_y`), `tof_synth` layouts / forearm / saturation, and
  the model's SPAD-level hand scene (`Model.user_scene = .hand`).
- M2: `lib/tof_spad.zig` (the user SPAD mask, the datasheet's rules as
  a validator, the SPAD page encoder / decoder, the depth-photo layouts),
  `Tof.set_user_mask` (validate, then write and verify the page; frames
  carry `frame_mask_gen`; `stats.mask_*`, `spad_mismatch`, `spad_diff`),
  `lib/tof_scene.zig` (the model's SPAD-level scene, used for results
  under spad_map_id 14: a tilted wall, a floor, a box, a slowly drifting
  ball, dead SPADs) and `lib/tof_depth.zig` (the slow-scan depth photo).

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
| Never set powerup_select = 2 before RAMREMAP_RESET (DS 8.9.5 suggests it; the C does not) | Hardware, 2026-10-05: M0-M2 wrote it on every other retry; it lives in the always-on domain, and a later reset left the chip hung with ENABLE 0x21 (`cpu_timeout @wait_ready R0021`, retrying forever). The driver now remaps as the C does and clears a 2 it finds (`bl_clear_ps` in the log) |
| Bootloader status reply carries a checksum (`status + size + csum = 0xFF`) | C checks it only for replies with data; not in DS. Counted (`CK` on DIAG), not fatal |
| 10 ms after RAMREMAP and again after cpu_ready before using the application | C (`tmf882x_wait_for_cpu_startup`) |
| CPU reset: powerup_select = 1, bit 6 of 0xEC (PLL) cleared, then 0x80 to 0xF0 | C only (`tmf882x_mode_cpu_reset`); 0xEC and 0xF0 are undocumented in DS. The PLL step was skipped until 2026-10-05 |
| cpu_ready not set by the deadline: force one CPU reset (as the C's `tmf882x_wait_for_cpu_ready` does), then a standby cycle (PON 0, 10 ms, PON 1 with powerup_select 1: the bootloader resets on PON 0 -> 1, DS 8.2.3), then fail and retry | C + DS 8.2.3; `stats.rescues` (DIAG `RS`) counts them |
| CMD_STAT 0x08 busy while >= 0x10; 0 OK, 1 accepted; STOP 0xFF, MEASURE 0x10, LOAD_CONFIG_PAGE_COMMON 0x16, WRITE_CONFIG_PAGE 0x15 | DS 8.3 + C |
| Configuration page at 0x24: period, kilo-iterations, SPAD map 0x34, HIST_DUMP 0x39; edited in place, written back | DS 8.5 + C |
| Short range: commands 0x6E / 0x6F to CMD_STAT, register ACTIVE_RANGE 0x19 reports 0x6E / 0x6F (0 = not supported) | DS 8.3.11 gives the register values; the commands are from memory of later ams drivers, unverified. A failure is noted, not fatal |
| INT_STATUS 0xE1 bit 1 result, bit 3 histogram; write 1 to clear; INT_ENAB 0xE2 | DS 8.2.4/8.2.5 |
| Result record at 0x20: rid 0x10, tid, size, result number 0x24, temperature, ambient 0x28, photons 0x2C, reference 0x30, sys tick 0x34, 36 triplets from 0x38 | DS 8.4 + C |
| 3x3: first object of zone z in triplet z, second object in triplet 18 + z (9..17 empty) | C (`RESULT_IDX_TO_CHANNEL` / `_SUB_CAPTURE`); DS only says "zone 2 to the last zone". DIAG's `MT` counts frames with non-zero triplets 9..17 |
| Histograms: 30 subpackets (rid 0x81, number 0x24, payload 0x80 at 0x25, data 0x27..0xA6) = 5 TDCs x 256 bins x 3 byte planes, LSB plane first | DS 8.8 (subpacket registers, payload always 0x80) + C (`decode_histogram_msg`: 5 TDCs, 256 bins, plane order) |
| Each TDC's 256 bins = two channels of 128: subpacket n is channel n % 10, byte plane n / 10; channel 0 the reference SPAD | Inferred (C has 2 channels per TDC, DS has 10 channels of 128 bins); confirm on HIST: channel 0 should show one huge peak at a low bin |
| The sensor publishes the next subpacket after the host clears INT bit 3; the result follows the last one | Inferred from the C's multi-packet loop (clear, then wait for the tid to change). The driver reads first and clears after, and files subpackets by their number |
| A measurement that falls due mid-dump abandons the dump and its result: a host slower than the ranging period gets histogram scraps and no results | Hardware, 2026-10-05 (HIST/EYES at 400 kHz, 33 ms: `frame_timeout` every few seconds, EYES filling a few lines at a time). With histograms on the driver lengthens the period to `Tof.hist_period_ms()` (a whole dump at the bus speed and per-poll budget: ~255 ms at 400 kHz with HIST's 12 ms budget, ~127 ms at 1 MHz), checks the next subpacket's TID on one byte, and on a stall clears every interrupt and resyncs (`stats.stalls`, DIAG `ST`) before it would restart. The C reads a dump back to back, which hides this |
| After STOP during a dump, that measurement's result can still land in 0x20 over the common page | Hardware, 2026-10-05 (`bad_rid @read_cfg R0010` when leaving HIST). The driver clears all interrupts after STOP (`stop_drain`) and reloads the page up to 3 times (`stats.cfg_retries`, DIAG `CR`) |
| **M2, user SPAD masks** (`lib/tof_spad.zig`, `Tof.set_user_mask`) | |
| spad_map_id 14 = one measurement of up to 9 zones from a user mask; at most 18x10; enable mask and channel map the same size; channel 0 (reference) unused; mask plus offset within 18x12, offsets in Q1 (+-2 = one SPAD); at least two adjacent SPADs per used channel; no row with channel 1 and channel 8 or 9; at least one channel of each pair 2/3, 4/5, 6/7, 8/9 | DS 7.4.1 (the validator checks all of them before anything is sent) |
| SPAD page: command 0x17 loads it, cid 0x17 in 0x20; enable mask 0x24..0x41, channel map 0x42..0x8C, x/y offset 0x8D/0x8E, x/y size 0x8F/0x90; committed with WRITE_CONFIG 0x15 | DS 8.6 + CMD_STAT 0x17 |
| Inside the page: one 24-bit LE enable word per row (bit x = column x); one 32-bit LE word per column at 0x42 + 4x with the SPAD's channel bits at yIdx, 10 + yIdx, 20 + yIdx; channels 8 / 9 stored as 0 / 1 with the row's bit set in the 24-bit select word at 0x8A (so a row cannot hold 1 and 8/9: 1 would read as 9) | C (`encode_spad_config_msg`, `tmf8x2x_config_page_SPAD.h`); DS gives only the first / last addresses |
| Order: stop, common page with spad_map_id 14 written first, then load / write / commit the SPAD page, then MEASURE; a further mask while on map 14 only rewrites the SPAD page | C (`set_spad_config` refuses unless the common page already has 14) + DS status 0x0A (SPAD page ignored while a pre-defined map is selected). DIAG `ERR cmd_status R150A` would mean the order is wrong |
| Read back after writing: load 0x17 again, compare the decoded mask | DS 7.4.1 ("read back the masks for verification"). A difference is counted (MASK `RB`, first difference `D....`), not fatal |
| Register row yIdx 0 is drawn as the top row, bit 0 as the left column | Inferred (the C fills yIdx 0 from its `y = ysize - 1`; which way that faces is not documented). The DEPTH photo with a hand in a known corner confirms it |
| Channel c reports in result triplet c - 1 (zone c) | Inferred (same layout as the pre-defined 3x3 maps) |
| The mask sits on whole SPADs: 18 - xsize + x_offset_2 and 12 - ysize + y_offset_2 even | Inferred; the driver refuses half-SPAD placements (its own layouts are all 18x10 without offset) |
| "Adjacent" means sharing an edge | Inferred (DS: "can be in any direction"); diagonal pairs are refused |
| The first frame after MEASURE is already measured with the new mask | Inferred (`Scan.settle` = 0 frames dropped; raise it if the photo shows the previous layout's values) |
| A user mask has no crosstalk calibration (the driver loads none for any map) | DS 7.3 / 7.4.1: changing the mask invalidates it. Expect short-range crosstalk in the photo's near pixels |
| **M5, STRIPES** (`tof_spad.stripes()`, `Tof.set_layout`) | |
| 8 full-height stripes, channels 2..9, SPAD columns 3 2 2 2 2 2 2 3 wide; channel 1 unused (a full-height channel shares every row, and no row may hold 1 with 8 or 9) | DS 7.4.1 rules, checked by the validator and a host test |
| Stripe k (channel k + 2) reports in result triplet k + 1, `Frame.zones[k + 1]`; zone 0 empty | Inferred (the M2 rule "channel c in triplet c - 1"); a STRIPES frame with zone 0 lit, or one stripe always empty, would say otherwise |
| SPAD column 0 is the device view's left, the same side as zone 1 of maps 1 / 6 | Inferred (M2); `tof_zones.stripes_reversed` flips it if STRIPES comes out mirrored against GRID |
| One SPAD = 2.4 deg across the columns; the stripes span the array's 43 deg | DS 7.4.1 (map 6 is 41 x 52 deg) |
| Each frame carries its layout (`Frame.layout`: grid for maps 1..12, stripes when the active mask is `stripes()`, user for other masks) | Driver: set when the mask is written and when measuring starts |

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

### M1.5: trombone (`snouty-trombone`)

- The theremin's sibling: hand height over the sensor is the slide (1st
  position at 10 cm .. 7th at 45 cm, continuous), hand side to side
  (lib/tof_pose.zig's coverage centroid, never the closest zone) the
  embouchure: which partial of the harmonic series sounds, with
  hysteresis, lip bends and cracks. A brass voice (band-limited pulse,
  state-variable filter, attack blat, plunger wah on B) streamed into
  lib/stream_audio's ring; a pixel-art trombone whose slide follows the
  hand. Stick fallback; a demo hand (lib/tof_synth.zig) for the
  simulator and badge-bench.
- Status 2026-10-06: M1 on branch `trombone/m1` (tag
  `snouty-trombone/m1`), not merged; nothing run on hardware.
  carts/snouty-trombone/PLAN.md has the bench numbers and the cart's own
  questions. On synthetic frames the pose's x moves in steps over the
  3x3 zones, so the middle partials have narrow hand ranges at some
  heights (about 10 mm at 4th position): the badge check below decides
  whether 7 partials across the hand's sweep is too many.

### M2: Sensor Eyes and the depth photo (`snouty-sense` pages)

- EYES: all nine histograms as a scrolling waterfall; sound mode that
  plays the hand's histogram as a wavetable (your hand shapes the
  timbre).
- DEPTH: slow-scan still depth photo from user SPAD masks (target ~9x10
  from SPAD pairs, cycling layouts host-side), false colour plus a
  spinning point cloud. Needs hardware to prove mask switch time, dead
  SPADs and calibration.
- Status 2026-10-05: built on branch `tof/m2` against the model, nothing
  run on hardware (section 5 steps 8 and 9 are its check). Driver:
  `set_user_mask` with the page written, committed and read back; the
  model implements the page and rejects broken ones; host tests cover
  the validator, the encoding, the read-back, switch timing and a whole
  photo against the SPAD scene. Model numbers (60 Hz polls, 400 kHz,
  exposure N = 2 frames per layout): a mask switch takes 99 ms (the
  first, from map 1, 119 ms; at 1 MHz 133 / 166 ms, where every command
  waits a poll), a 9x10 photo 1.33 s (67 pixels/s), 17x10 2.67 s (63
  pixels/s); N = 1: 1.0 s, N = 4: 2.0 s. The real chip's command and
  measurement-start latencies decide the real numbers.
  carts/snouty-sense/PLAN.md has the bench numbers.

### M3: Snouty Morph (`snouty-morph`)

- A demoscene mesh (torus knot, Boing ball, Snouty head, Iris mark) that
  follows the hand in 6DoF and deforms with it (reach, jelly, twist,
  punch shockwave); stick fallback.
- `lib/tof_pose.zig`: hand pose from the 3x3 frame (background model,
  coverage centroid, plane-fit tilt, moment yaw, One Euro filters) and
  `lib/tof_synth.zig` (synthetic frames for tests and the stick field).
  Design and honest limits in carts/snouty-morph/SPEC.md.

### M3.5: Snouty Shader (`snouty-shader`)

- A Shadertoy-style gallery of six abstract per-pixel shaders whose
  uniforms are the sensor: the 3x3 presence/depth field (Catmull-Rom
  upsampled over the screen) and the tof_pose hand pose and punches.
  snouty-morph's sensor wiring and orientation. Design in
  carts/snouty-shader/SPEC.md, status and bench numbers in its PLAN.md.

### M4 (later): gestures and hand modes

- `lib/tof_gesture.zig` (swipe, push/pull, height, presence) and hand
  modes for existing carts (Flyover altitude, Reflections ripple,
  Demosnout speed), wake-on-approach attract.

### M5: stripes and arm rejection (branch `tof/stripes`)

Adrian (2026-10-06): on every sensor cart height tracks much more
consistently than side to side; pointing an arm and finger straight
down over the sensor helped. Why: height is a time-of-flight measurement
(2 mm precision, fine with a partly covered zone), while side to side
comes from three columns of ~14 deg (map 6), the sub-zone interpolation
in lib/tof_pose.zig leans on `confidence` (probably saturated for any
zone the hand touches, so x steps column centre to column centre), and
the background model counts the wrist and forearm as hand, so the arm
drags the centroid.

Plan and decisions (defaulted, not asked):

1. **STRIPES zone layout**: a user SPAD mask (spad_map_id 14, the DEPTH
   page's path) of 8 full-height vertical stripes across the 18x10
   array, on channels 2..9 (`tof_spad.stripes()`).
   - 9 full-height stripes are impossible: every row would hold channel
     1 and channels 8 and 9 (DS 7.4.1). 8 stripes on 2..9 never use
     channel 1, use every TDC pair, and each stripe is a 2- or 3-wide by
     10-tall block of edge-adjacent SPADs.
   - The two spare columns widen the outer stripes (column widths
     3 2 2 2 2 2 2 3): the whole 43 deg field stays live (the same span
     as map 6, which the instruments are tuned to), the edges keep
     seeing a hand leaving the field, and the coarser outer stripes sit
     where lateral precision matters least. Disabling the two edge
     columns instead (8 x 2) would narrow the field to 38 deg for no
     gain in the middle. Each stripe has 20 or 30 SPADs (a map-6 zone
     has ~18-24), so the signal per zone is about the same.
   - Inner stripes are 4.8 deg wide (17 mm at 20 cm) against 13.7 deg
     for a map-6 column: about 3x finer before interpolation, and the
     hand's edges entering and leaving stripes give half-stripe steps
     with no help from confidence at all.
   - Channel c reports in result triplet c - 1 (the M2 inference), so
     stripe k is `frame.zones[k + 1]`; `zones[0]` stays empty. SPAD
     column 0 is taken as the left of the device's view, the same side
     as zone 1 of the pre-defined maps (M2 inference, not yet seen on a
     badge): if STRIPES comes out mirrored against GRID, flip
     `tof_zones.stripes_reversed`.
   - Stripes run along the device's 18-column axis. Under an orientation
     with `transpose` they measure the screen's vertical axis: the pose
     then has y resolution and no x (`Pose.has_x` false, x = 0). No cart
     transposes; a badge that needs it should stay on GRID.
2. **Zone geometry, not a fork**: `lib/tof_zones.zig` gives every layout
   (3x3 grid, 1x8 stripes) as per-zone screen angles and tangents after
   the orientation (flip_x / flip_y / transpose / MIRROR), the device
   zone each screen cell reads, and which screen axes have resolution.
   lib/tof_pose.zig, lib/tof_synth.zig and the carts take the layout
   from there. GRID numbers are unchanged.
3. **Arm rejection in the shared pose**, both layouts: each hand zone's
   ray distance becomes a perpendicular height with its zone's centre
   tangents; the **near cluster** is every hand zone within
   `cluster_mm` (40, the trombone's M1 value) of the nearest. Per
   estimate:
   - x / y centroid and its sub-zone shift: the near cluster only (a
     finger pointing down tracks the fingertip, a forearm sloping in
     from one side no longer pulls x).
   - `Pose.height_mm` (new, raw per frame): the near cluster's mean
     height, what the instruments play (the trombone's M1 rule, now
     shared). `Pose.near_mm`: the nearest hand point.
   - z, the tilt plane fit and yaw: the **hand body**, zones within
     `body_mm` (100) of the nearest, then the old 120 mm outlier cut.
     Measured on synthetic hands: a palm pitched 45 deg reads 39.8 deg
     (confidence 1.0) with the body window and 0 deg (confidence 0)
     with the near cluster alone, which drops its far half; 100 mm
     tracks as well as 150 or no window up to 45 deg and drops more of
     a far forearm. Yaw keeps the wrist (it is the hand's long axis).
   - Cost: a strongly rolled wide hand loses its far edge from the
     lateral cluster, so x leans toward the near edge (a 20 cm wide
     surface rolled 30 deg: -27 mm). A real palm (~9 cm) rolled 30 deg
     spans ~45 mm and stays almost whole. Carts can widen `cluster_mm`.
   - Presence and the coverage map: every hand zone, as before.
   Host tests: an arm sloping in from one side and a pointing finger,
   in both layouts, with arm rejection on and off.
4. **Sub-stripe interpolation**: the existing coverage centroid with the
   sub-zone shift generalises exactly to 1-D stripes (a partly covered
   edge stripe's centre moves toward the blob by (1 - coverage) / 2 of
   its own width, which is the covered part's centre). Coverage comes
   from the near/far signal ratio when the stripe also sees the
   background (this survives a saturated near confidence) and from
   confidence otherwise. When neither carries information the result is
   still half-stripe steps from stripe membership. Measured on synthetic
   sweeps with confidence that does and does not track coverage
   (`tof_synth.Scene.saturate`), map-6 field, 2 mm steps, settled pose
   per position (lib/tof_pose.zig test "stripes follow a sideways
   sweep"):

   | Hand, confidence | GRID: distinct readings, max step, worst error | STRIPES |
   |---|---|---|
   | fingertip at 15 cm (+-36 mm), either | 4, 18.2 mm, 12.0 mm | 10, 6.4 mm, 4.0 mm |
   | palm at 25 cm (+-60 mm), tracks coverage | 30, 11.3 mm, 6.3 mm | 48, 6.3 mm, 6.1 mm |
   | palm at 25 cm, saturated (255 always) | 10, 17.1 mm, 19.2 mm | 10, 12.0 mm, 11.4 mm |

   A fingertip (what Adrian found works) gains most: 3x finer steps and
   errors. A palm gains less while confidence tracks coverage (the
   synthetic 3x3 already interpolates then); with saturated confidence
   STRIPES halves the worst error (half-stripe steps, ~10 mm at 25 cm).
   Arms (test "a forearm sloping in from the left"): a forearm rising
   from the hand at 0.6 mm/mm pulls x 26 mm without rejection; with it,
   STRIPES moves 1 mm and GRID 12 mm (a grid zone holding the hand and
   the start of the arm cannot be split).
5. **Switching**: `Tof.set_layout(layout, grid_config)` uses the paths
   the DEPTH page and LIVE's map toggle already exercise: STRIPES is
   `set_user_mask(stripes)` (stop, common page with map 14, SPAD page,
   read-back, MEASURE), GRID is `configure` with the cart's pre-defined
   map (stop, common page, MEASURE). No CPU reset, no powerup_select,
   no histogram dumps, so none of the recovery history above is
   touched; repeated switches coalesce into one pending configuration.
   The driver tags every frame with the layout it was measured with
   (`Frame.layout`: grid, stripes, or user for any other mask) and the
   pose ignores frames of the other layout, so the frames in flight
   around a switch never reach the estimator; switching resets the
   background model (zone i means another place).
6. **Crosstalk**: a user mask has no crosstalk calibration. The driver
   never loads one for any map, but the pre-defined maps may carry
   factory defaults a user mask does not, so very near targets can merge
   with the package crosstalk. STRIPES therefore ignores hand targets
   nearer than `min_mm_stripes` (40 mm, GRID keeps 15). If STRIPES lights
   every stripe with no hand there, raise it (hardware check M5).
7. **Carts**: a ZONES setting (GRID / STRIPES) in each sensor cart.
   Defaults: STRIPES for snouty-theremin and snouty-trombone (1-D
   lateral instruments), GRID for snouty-morph and snouty-shader (they
   use the vertical axis and tilt). Theremin and trombone get a menu
   row. Morph and shader have every button taken: hold Select for 1 s
   (a gesture neither uses; a tap keeps its meaning, and morph's press
   toggle of the sound is restored when the hold turns out to be ZONES).
   In STRIPES: the theremin's 2 HAND layout splits the stripes into a
   pitch half and a volume half and its grid drawing becomes stripes;
   the shader's depth field is stretched over the full height (no
   vertical structure); morph's pitch confidence is 0 (roll still
   measured), so the mesh only rolls.
8. **Fakes**: lib/tof_synth.zig renders any layout (and an optional
   forearm); lib/tof_virtual.zig gets a SPAD-level hand scene for user
   masks that the carts' `-Dtof-fake=true` builds select (the DEPTH
   page keeps its room scene); each cart's demo hand renders the active
   layout.
9. snouty-sense: no new page; it must build, test and behave unchanged.

Status 2026-10-06: built on branch `tof/stripes`, nothing run on
hardware. All four carts have ZONES (theremin and trombone: a menu row,
default STRIPES; morph and shader: hold Select 1 s, default GRID; no
binding displaced). badge-bench (calibrated, busy ms worst / mean;
each cart's toml run unless noted; 0 frames over budget, 0 underruns):

| Cart | normal | demo hand GRID / STRIPES | `-Dtof-fake` GRID | `-Dtof-fake` STRIPES |
|---|---|---|---|---|
| theremin | 0.98 / 0.58 | 1.10 / 0.62, 1.11 / 0.61 (2-hand) | 3.66 / 2.07 | 4.18 / 2.32 |
| trombone | 2.83 / 1.37 | 3.62 / 2.11, 3.57 / 2.07 (900 frames) | 4.69 / 2.84 (900) | 5.16 / 3.10 (900) |
| morph | 6.83 / 4.23 | (none) | 10.12 / 5.73 | 10.01 / 5.76 |
| shader | 8.95 / 5.08 (GRID), 8.45 / 4.83 (STRIPES) | (none) | 11.39 / 6.13 | 10.30 / 6.06 |

The `-Dtof-fake` STRIPES extra is the model tracing its hand SPAD by
SPAD; the real sensor costs the same bus reads in both layouts.

Open questions (for the badge check, section 5 M5):

1. Whether the real confidence tracks coverage (it decides how much
   sub-stripe interpolation there is beyond half-stripe steps).
2. SPAD column order and the channel-to-triplet mapping for a mask
   that never uses channel 1 (both inferred in M2).
3. Whether 40 mm is the right near limit without crosstalk calibration.
4. Mask-switch time on the real chip (model: ~100 ms).

## 5. Hardware checks (Adrian)

You need: an r2 (production) SYCL badge, the SparkFun Qwiic Mini dToF
Imager, a Qwiic cable. Build from the repository root:

```sh
zig build -Dcart=snouty-sense      # zig-out/firmware/snouty-sense.uf2
```

Flash `snouty-sense.uf2` the usual way, plug the breakout into the
badge's Qwiic port (the cable can go in before or after the cart
starts; unplugging and replugging while it runs is fine and part of the
test), and start the cart. Left / Right switch pages (LIVE, HIST, EYES,
DEPTH, DIAG; the five dots top right show which; Left from LIVE goes
straight to DIAG).

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

7. **Theremin and Morph.** With the breakout still plugged in, start
   `snouty-theremin.uf2`: the top-left source label turns SENSOR and a
   hand 5-50 cm over the sensor plays (closer is higher); Left/Right pick
   1 HAND / 2 HAND (2 HAND uses the wide SPAD map). Then
   `snouty-morph.uf2`: the label turns HAND and the mesh follows your
   hand; push toward it to bulge, jab for the shockwave. Say whether left
   and right come out mirrored in either cart (their orientation
   constants follow the LIVE photo). Then `snouty-trombone.uf2`, sensor
   facing up: a hand 10-45 cm over it blows; raising and lowering it
   moves the drawn slide (the ruler under it shows positions 1-7), moving
   it left and right moves the cyan lip marker along the partial ladder
   (left low, right high; MIRROR in the menu if reversed). Say whether
   every partial (the seven ladder cells) can be held with a still hand
   at a low, middle and high height, and whether the slide jitters.

8. **Shader.** `snouty-shader.uf2`: hold B and the inputs panel's
   source label (top right) turns HAND with a hand over the sensor; its
   3x3 grid lights under your hand (warmer = nearer). Left/Right through
   the six programs: the image should bend toward your hand (INK, CELLS),
   ring under your fingers (RIPPLE), turn into lava where you reach (LAVA),
   swirl and zoom about it (ECHO), and steer the tunnel (KALEIDO); a jab
   flashes and kicks the palette. Say whether it feels mirrored, and
   whether the punch fires too easily or not at all.

Send the photos of LIVE (hand in a corner + which corner), HIST CH0 and
CH5, and DIAG after boot, after the 1 MHz reload, and of anything that
went wrong.

**M2 addendum** (steps 1-7 first: the orientation from step 2 also
orients EYES and DEPTH).

8. **EYES.** Right from HIST. Nine tiles laid out like LIVE's grid, one
   per zone: distance left to right (ticks above each tile every metre,
   up to 2.5 m), time downwards (a new row per histogram set, a few a
   second). Each tile should show a grey band at the left (crosstalk,
   near bin 15), a dim blue noise floor, and a bright vertical line per
   object (the wall or ceiling), with white (first object) and yellow
   (second) dots on it; ticks above each tile at 1 m and 2 m. Move a hand from 40 cm to 10 cm over one zone:
   its line should slant to the left in that tile. **Photograph EYES
   with your hand held still about 30 cm over one corner zone** (B
   freezes the waterfall, HOLD in red; B again resumes) and say which
   corner. A turns the sound on (SND): the tile with the nearest object
   is outlined in blue and plays; pitch rises as the hand comes closer
   (880 Hz at 8 cm, 110 Hz at 1.2 m), and the timbre changes with where
   the peaks sit. Up / Down pick a fixed zone (Z1..Z9, or ZA = auto).
   Say whether the sound is clean or crackles.
9. **DEPTH.** Right from EYES. The cart now measures through user SPAD
   masks: each "shot" lights nine SPAD pairs (outlined in white on the
   photo) and the 9x10 photo fills in shot by shot, then starts over;
   the side panel shows the shot, a progress bar, the last photo's time
   and pixels per second (the badge's own numbers; MODEL appears only
   on the simulator or a fake build), the exposure N (Up / Down: frames
   per shot) and the size (Select: the fine pass, 17x10). A cycles
   PHOTO / CLOUD (the same pixels as a spinning point cloud) / MASK.
   What proves the user-mask path works:
   - DIAG-style errors: on MASK, no red error line; `WR` (pages
     written) goes up by one per shot; `G a/b` turns green (frames come
     with the newest mask); `RB0` (every read-back matched; `RB` > 0
     with `D....` = the first difference: `FF0n` a size or offset, else
     row and column); `RJ0`. **Photograph MASK** after ~10 s. If DEPTH
     stays on "STARTING SENSOR" or shows `ERR cmd_status`, photograph
     DIAG: `R150A` = the SPAD page was ignored (write order), `R1502` =
     page rejected (encoding), `R1702`/`R1706` = command 0x17 not
     accepted, `bad_rid` at `spad_check` = the page did not load.
   - The picture: point the badge at a flat wall about 1 m away: the
     photo should be one smooth colour (green-blue) with maybe a slight
     gradient; then hold a hand 30 cm away in the top-left of the view:
     an orange blob in the photo's top-left (if it comes out mirrored
     or upside down relative to LIVE, the row / column inference in
     section 3 is wrong: say which). Hatched pixels (an X) had no
     object in any frame of their shot: a pair of dead SPADs or out of
     range; dotted ones low confidence. **Photograph PHOTO** for both
     scenes, and CLOUD once.
   - Timing: note `SW..MS` (the last mask switch), `MX..MS` (worst)
     and the photo's seconds and PX/S at N = 2 (model: 99 ms, 1.33 s,
     67 PX/S at 400 kHz).
   Leaving DEPTH goes back to the normal SPAD map (LIVE should look as
   before).

**M5 addendum: stripes and arm rejection** (branch `tof/stripes`;
steps 1-7 first: they set the orientation, and snouty-sense's DIAG is
still the page to photograph when anything fails). Every sensor cart
now has a ZONES setting: GRID (the 3x3 of a pre-defined map, as
before) or STRIPES (8 narrow full-height stripes from a user SPAD mask:
finer side to side, no up/down). A switch stops the sensor, writes the
mask or the map and restarts it in about 0.1 s, with no reset; it
should never show NO SENSOR or stall. Arm rejection is on in both
layouts: side to side and the instruments' height come from the part
of the hand nearest the sensor, so pointing a finger down, or reaching
in from the side, should track the hand or fingertip, not the forearm.

10. **Theremin** (STRIPES by default; ZONES is the last menu row,
    Start opens the menu). The zone picture shows 8 vertical stripes.
    Move a flat hand slowly left and right ~25 cm up: the dot slides
    stripe by stripe, the cyan outline follows without jumping back.
    Point one finger down and sweep sideways: the outline stays on one
    or two stripes under the fingertip, the pitch follows its height.
    2 HAND: pitch over the right three stripes, volume over the left
    three, a hand over the middle two plays neither. A hand nearer
    than ~4 cm does not play in STRIPES (the near limit, below).
11. **Trombone** (STRIPES by default; ZONES row before DEMO). Sweep a
    hand left and right at low, middle and high heights (10-45 cm):
    the cyan lip marker should walk all seven ladder cells, each
    holdable with a still hand (~14 mm of travel per partial at 15 cm,
    ~25 mm at 27 cm). Then ZONES GRID and compare (expect coarser,
    uneven partials). Point a finger down with the arm coming in from
    the side: the lip follows the fingertip.
12. **Morph** (GRID by default): hold Select 1 s (a tap still toggles
    the sound; the hold leaves it as it was): "ZONES STRIPES", the map
    top right turns into 8 bars. A sideways sweep should glide the
    mesh more smoothly than GRID; it stays at centre height and only
    rolls (no pitch, no turn). Reach in from the side: it follows the
    hand, not the arm (both layouts).
13. **Shader** (GRID by default): hold Select 1 s (a tap is still
    MIRROR): "ZONES STRIPES"; with B held the panel shows 8 bars and
    its dot. A slow sweep lights the bars one by one, the field lights
    full-height columns under the hand, INK and CELLS bend toward the
    hand more precisely than in GRID.
14. **Toggle ZONES back and forth** a few times in any cart: each
    switch settles within a fraction of a second.

If STRIPES looks scrambled in any cart (bars or stripes light out of
order, a stripe never lights, the lateral direction is reversed against
GRID, or every stripe lights with no hand there), switch that cart to
ZONES GRID: it is exactly the M1-M4 behaviour (plus arm rejection).
Then tell me which: out of order or a dead stripe = the channel to
triplet mapping (section 3, inferred); reversed against GRID = the SPAD
column order (`tof_zones.stripes_reversed`); every stripe lit at a few
cm = crosstalk without calibration (raise `min_mm_stripes`, 40 mm). A
photo of the theremin's stripes with your hand over one side shows all
three.

## 6. Deferred questions

1. Theremin boots with sound on (it is an instrument) instead of the
   repo's boot-silent rule; Select mutes. Flip if Adrian prefers silent.
2. Default zone orientation: decided from the M0 hardware photos.
3. M2: which way the SPAD page's rows and columns face (section 3,
   inferred), and whether the first frame after a mask switch is clean
   (`Scan.settle`): from the step 9 photos.
4. M2: EYES boots silent like every other cart (A turns the sound on,
   `-Dsound=true` starts with it on), unlike the theremin.
5. M5: ZONES defaults (STRIPES for theremin and trombone, GRID for morph
   and shader), the 40 mm STRIPES near limit, and whether confidence
   tracks coverage on the real chip (it decides whether STRIPES gives
   more than half-stripe steps): from the M5 addendum checks.
