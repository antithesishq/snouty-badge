# Snouty Sense (SPEC)

The time-of-flight probe cart: a SparkFun Qwiic Mini dToF Imager (ams
TMF8820, 3x3 zones, up to 5 m) on the SYCL badge's Qwiic port, shown
live, with its raw histograms and everything needed to diagnose it from
one photo. It is M0 of the time-of-flight work (docs/TOF.md section 4);
M2 adds the EYES and DEPTH pages here.

## 1. Hardware

- SYCL Badge V2 revision r2 only (Qwiic SDA/SCL on GPIO12/13 = I2C0).
  r1 dev boards have the lines swapped, r0 has no connector.
- The cart drives I2C0 itself (no OS API exists): `lib/i2c_rp2350.zig`.
- The sensor needs its RAM firmware downloaded at every power-up; the
  driver (`lib/tof.zig`) does it in the background in about 0.3-0.5 s.
- The simulator (and `-Dtof-fake=true` badge builds) use the virtual
  sensor `lib/tof_virtual.zig`: a wall at ~900 mm and a hand wandering in
  front of it.

## 2. Pages

Left / Right cycle LIVE -> HIST -> DIAG; three dots top right show the
page. Joystick click is never bound; nothing reacts while Start and
Select are both held (the OS's chord). No sound.

| Page | Shows | Buttons |
|---|---|---|
| LIVE | 3x3 grid, false colour by the nearest object (red near .. blue/purple 2 m+), mm and confidence per cell, the second object as a corner swatch and `+mm`, the device zone number top left; frame rate, die temperature, ambient, photon count; orientation flags | A flip X, B flip Y, Up transpose, Down SPAD map normal (1) / wide (6) |
| HIST | one channel's 128-bin histogram as bars, metre ticks (DS000693's ~57 mm bins, zero near bin 15), the frame's nearest (green) and second (yellow) objects marked with mm, confidence and bin; the channel's peak count and the dump rate | Up / Down channel (0 = reference, 1..9 zones), A linear / log |
| DIAG | driver state; last error, step, raw status; chip ID, revision, application ID and version; bootloader version, serial, active range; download time and count, status registers; I2C speed, SDA/SCL levels, errors; last abort source, timeouts, recoveries; bus scan; frames, missed, torn, reply-checksum mismatches; poll time; the last four driver steps | A I2C speed 400 -> 1000 -> 100 kHz (restart), B reload (CPU reset + download) |

With no sensor, LIVE and HIST show "NO SENSOR" with what to plug where,
the r2-only note, the bus scan and the line levels. While the sensor
boots (or after an error) they show the state, step, a firmware
progress bar and the error.

Histogram dumps are on only while HIST is shown (they cut the frame
rate to a few Hz); switching pages reconfigures the running sensor.

## 3. Budgets

- The driver gets 3 ms of I2C time per update on LIVE and DIAG (a whole
  result at 400 kHz: 30 Hz without losing frames) and 6 ms on HIST.
- At 100 kHz the cart asks for a 100 ms ranging period (a result read
  then fits between results).
- The bus scan probes 8 addresses per update while DIAG or NO SENSOR is
  on screen.
- Worst update under 16.7 ms with headroom in badge-bench, both the
  no-sensor build and the `-Dtof-fake=true` build (PLAN.md).
