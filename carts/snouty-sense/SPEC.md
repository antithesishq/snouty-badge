# Snouty Sense (SPEC)

The time-of-flight probe cart: a SparkFun Qwiic Mini dToF Imager (ams
TMF8820, 3x3 zones, up to 5 m) on the SYCL badge's Qwiic port, shown
live, with its raw histograms and everything needed to diagnose it from
one photo. It is M0 of the time-of-flight work (docs/TOF.md section 4);
M2 added the EYES and DEPTH pages.

## 1. Hardware

- SYCL Badge V2 revision r2 only (Qwiic SDA/SCL on GPIO12/13 = I2C0).
  r1 dev boards have the lines swapped, r0 has no connector.
- The cart drives I2C0 itself (no OS API exists): `lib/i2c_rp2350.zig`.
- The sensor needs its RAM firmware downloaded at every power-up; the
  driver (`lib/tof.zig`) does it in the background in about 0.3-0.5 s.
- The simulator (and `-Dtof-fake=true` badge builds) use the virtual
  sensor `lib/tof_virtual.zig`: a wall at ~900 mm and a hand wandering in
  front of it; under a user SPAD mask (DEPTH) a SPAD-level scene
  (`lib/tof_scene.zig`: tilted wall, floor, box, a slowly drifting ball,
  five dead SPADs).

## 2. Pages

Left / Right cycle LIVE -> HIST -> EYES -> DEPTH -> DIAG; five dots top
right show the page. Joystick click is never bound; nothing reacts while
Start and Select are both held (the OS's chord), and Select alone acts
on release only if Start did not come in. Sound only on EYES.

| Page | Shows | Buttons |
|---|---|---|
| LIVE | 3x3 grid, false colour by the nearest object (red near .. blue/purple 2 m+), mm and confidence per cell, the second object as a corner swatch and `+mm`, the device zone number top left; frame rate, die temperature, ambient, photon count; orientation flags | A flip X, B flip Y, Up transpose, Down SPAD map normal (1) / wide (6) |
| HIST | one channel's 128-bin histogram as bars, metre ticks (DS000693's ~57 mm bins, zero near bin 15), the frame's nearest (green) and second (yellow) objects marked with mm, confidence and bin; the channel's peak count and the dump rate | Up / Down channel (0 = reference, 1..9 zones), A linear / log |
| EYES | the nine zone histograms as a waterfall, tiles laid out like LIVE (orientation included): distance left to right (bins 9..59, ~-0.35..2.5 m, ticks at 1 and 2 m), the newest set on top, one row per set (32 rows); false colour on a log scale normalised per set over the zones, an octave under each zone's quietest bin as black; crosstalk bins (9..19) and the reference channel (a strip under the tiles) in grey; the frame's first (white) and second (yellow) objects traced; the rate of sets; with sound on, the sound zone outlined, its distance and pitch | A sound on / off (boots off; `-Dsound=true` boots on), Up / Down sound zone (AUTO = nearest object, Z1..Z9), B hold the waterfall |
| DEPTH | the slow-scan depth photo (lib/tof_depth.zig): PHOTO (false colour like LIVE, 9x10 or 17x10, missing pixels hatched and filled from neighbours, low-confidence dotted, the pixels being measured outlined; shot, progress, last photo time, pixels/s, exposure, size, colour key, MODEL on the virtual sensor), CLOUD (the pixels as 3D points along their rays, turning once every 16 s, the sensor as a white mark), MASK (the shot's 18x10 SPAD mask by channel, mask generation of the frame / of the driver, pages written, switch time last / worst, read-back mismatches and the first difference, refused masks, shot time, each channel's distance) | A view, Up / Down exposure (frames per shot, 1..16), B new photo, Select fine pass (17 columns, 20 shots) |
| DIAG | driver state; last error, step, raw status; chip ID, revision, application ID and version; bootloader version, serial, active range; download time and count, status registers; I2C speed, SDA/SCL levels, errors; last abort source, timeouts, recoveries; bus scan; frames, missed, torn, reply-checksum mismatches; poll time; the last four driver steps | A I2C speed 400 -> 1000 -> 100 kHz (restart), B reload (CPU reset + download) |

With no sensor, LIVE and HIST show "NO SENSOR" with what to plug where,
the r2-only note, the bus scan and the line levels. While the sensor
boots (or after an error) they show the state, step, a firmware
progress bar and the error.

Histogram dumps are on only while HIST or EYES is shown (they cut the
frame rate to a few Hz); DEPTH measures through user SPAD masks
(spad_map_id 14) and leaving it restores the normal (or wide) map;
switching pages reconfigures the running sensor.

## 2a. EYES sound

The sound zone's histogram (bins 16..79) becomes a 64-sample
single-cycle wavetable (log-compressed, floor and DC removed, smoothed,
normalised) at a pitch from the zone's first object: 880 Hz at 80 mm to
110 Hz at 1.2 m, equal-tempered. Each new histogram set crossfades in
over ~180 ms; pitch and level glide per sample; the voice releases when
the zone has no object or the page changes. Badge builds render 44.1 kHz
u8 samples into lib/stream_audio.zig's ring (started the first time
sound is turned on; `cart.tone2` is never called); the simulator gets a
pulse tone at the same pitch (no wavetable there).

## 2b. DEPTH scan

Each shot is a user mask of nine horizontal SPAD pairs on two rows (one
row's pairs on channels 1..4, the other's on 5..9: no row mixes channel
1 with 8 or 9, every TDC pair used). Coarse pass: pairs (0,1)..(16,17),
10 shots, 9x10. Fine pass: pairs (1,2)..(15,16), 10 more shots of 8,
17x10 together. Each zone's first object is averaged over `exposure`
frames (weighted by confidence) into its pixel; a pixel no frame saw
is missing, one under confidence 24 low. The photo repeats, overwriting
as it goes.

## 3. Budgets

- The driver gets 3 ms of I2C time per update on LIVE and DIAG (a whole
  result at 400 kHz: 30 Hz without losing frames) and 6 ms on HIST, EYES
  and DEPTH.
- At 100 kHz the cart asks for a 100 ms ranging period (a result read
  then fits between results).
- The bus scan probes 8 addresses per update while DIAG or NO SENSOR is
  on screen.
- Worst update under 16.7 ms with headroom in badge-bench, both the
  no-sensor build and the `-Dtof-fake=true` build (PLAN.md).
