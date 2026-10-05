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
  badges' stock OS.
- Neither the simulator nor badge-bench has a sensor. `lib/tof_virtual.zig`
  is a register-level model of the TMF8820 with a synthetic scene: the
  wasm build always uses it, a badge build uses it with `-Dtof-fake=true`
  (for badge-bench), and the host tests run the real driver against it.
  badge-bench's I2C0 fake NACKs every address, so a normal badge build
  benches its "no sensor" path.

## 3. The library

- `lib/tof_types.zig`: the data carts see (`Frame`, `Zone`, `Target`,
  `Histograms`, `Orientation`). Fixed before M0 so cart tracks can start.
- `lib/i2c_rp2350.zig`: I2C0 master, short transactions with timeouts,
  100/400/1000 kHz.
- `lib/tof.zig`: the TMF8820 driver, a cooperative state machine.
  `poll(now_us)` every update does a bounded slice of bus work (download,
  configure, read results/histograms), never blocking for more than a
  couple of milliseconds. Exposes the latest `Frame`, optional
  `Histograms`, its state and error for the diagnostics page, and
  `configure(...)` for SPAD map, iterations, period, histograms and
  short-range mode.
- `lib/tof_virtual.zig`: the model above.

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

### M2: Sensor Eyes and the depth photo (`snouty-sense` pages)

- EYES: all nine histograms as a scrolling waterfall; sound mode that
  plays the hand's histogram as a wavetable (your hand shapes the
  timbre).
- DEPTH: slow-scan still depth photo from user SPAD masks (target ~9x10
  from SPAD pairs, cycling layouts host-side), false colour plus a
  spinning point cloud. Needs hardware to prove mask switch time, dead
  SPADs and calibration.

### M3 (later): gestures and hand modes

- `lib/tof_gesture.zig` (swipe, push/pull, height, presence) and hand
  modes for existing carts (Flyover altitude, Reflections ripple,
  Demosnout speed), wake-on-approach attract.

## 5. Hardware checks (Adrian)

Filled in by M0. Plug the breakout into the badge's Qwiic port with a
Qwiic cable, flash `snouty-sense.uf2`, and photograph each page.

## 6. Deferred questions

1. Theremin boots with sound on (it is an instrument) instead of the
   repo's boot-silent rule; Select mutes. Flip if Adrian prefers silent.
2. Default zone orientation: decided from the M0 hardware photos.
