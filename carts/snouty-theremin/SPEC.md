# Snouty Theremin: spec

A theremin for the SYCL badge, played by hand distance over the SparkFun
Qwiic Mini dToF Imager (ams OSRAM TMF8820: 3x3 zones, or 8 narrow
stripes through a user SPAD mask) on the badge's Qwiic port, or with the
stick when no sensor is plugged in. Milestone M1 of docs/TOF.md (the
ZONES setting is M5). PLAN.md has the status, the bench numbers and the open
questions.

## 1. What the attendee sees and hears

Hold a hand 5 to 50 cm over the sensor: a tone sounds, rising as the hand
comes closer. Wobble the hand and the pitch wobbles with it (vibrato is
yours). Take the hand away and the note fades out. In the two-hand layout
the other hand, over the opposite side of the sensor, is the volume: lower
it toward the sensor to quieten the note, as on a real theremin. Without a
sensor the stick plays it: Up and Down step and glide, Left and Right hold
the note.

The screen shows the note name and how far off it is in cents, a live
scope of the samples being played, the hand heights, the zones (8
stripes, or the 3x3 grid; which play pitch, which volume), the layout, scale and waveform,
whether sound is on, and Snouty the anteater sniffing at the sensor:
snout up for high notes, ear up when loud, notes floating from the snout,
eye shut when muted.

## 2. Controls

| Button | Stick source (no sensor) | Sensor source | Settings menu open |
|---|---|---|---|
| Up / Down | play: a tap steps to the next / previous note of the scale (a semitone when FREE); held past 0.25 s, glide continuously (accelerating) | octave of the range up / down | row up / down |
| Left / Right | hold the current note (sound without moving) | layout: Left 1 HAND, Right 2 HAND | change the row's value |
| A | next waveform | next waveform | next value |
| B | next scale | next scale | close |
| Start (on release) | open the settings menu | open the settings menu | close |
| Select (on release) | mute / unmute | mute / unmute | mute / unmute |
| Start + Select | nothing (the OS's chord: its settings box opens; the cart ignores every button until both are up again) | same | same |
| Joystick click | never bound (the OS's FPS overlay) | | |

Start and Select act on release, and not at all if the other one was held
during the press, so the OS chord never opens the menu or toggles mute.
The bottom line rotates hints for the current source every 2.5 s.

Settings menu rows: LAYOUT (1 HAND, 2 HAND), WAVE (SINE, TRI, SAW, SQR),
SCALE (FREE, CHROM, MAJOR, PENTA), SNAP (SOFT, HARD), KEY (C..B), OCTAVE
(the range's bottom note: the key in octave 2..5), PITCH HAND (RIGHT,
LEFT), MIRROR (OFF, ON: the zones left/right, for a breakout held the
other way round on its cable), ZONES (STRIPES, GRID: section 3.3).
Defaults: 1 HAND, SINE, PENTA (friendly for passers-by at the show; FREE
is the true theremin), SOFT, C, octave 3 (C3..C6), RIGHT, MIRROR OFF,
ZONES STRIPES.

Sound boots ON: the cart is an instrument (docs/TOF.md deferred
question 1; one line in main.zig flips it). Select mutes; the status bar
always shows SOUND or a red MUTED. `-Dsound` does not apply to this cart.

## 3. Input sources and layouts

### 3.1 Source selection (`input.zig`)

- `sensor_frame(now_us)` is the one integration point with the TMF8820
  driver (lib/tof.zig, M0): it returns a frame new since the last call, or
  null. `sensor.zig` polls lib/tof.zig (null in the simulator and the
  host tests, which have no sensor).
- The sensor becomes the source as soon as a frame arrives; the stick takes
  over again after 1.5 s (90 updates) without one. The status bar shows
  SENSOR (green) or STICK (amber, "NO SENSOR").
- The demo hand (`fake_frame`): choreographed frames through the same path
  (Ode to Joy on the pitch hand with a 5.5 Hz, +-3 mm wobble; mode 2 adds a
  volume hand that dips at phrase ends). Enabled by the wasm export
  `debug_set_fake_sensor(1|2)` and the badge-bench poke
  `snouty_theremin_fake`; never on otherwise.

### 3.2 Hands from a frame (`hands.zig`)

- A zone counts when its nearest target has confidence >= 8, and 15 mm
  (STRIPES: 40 mm) <= distance <= 650 mm (closer is the cover glass, or
  under the stripes mask, which has no crosstalk calibration, the
  package's own light; further is the room). Only the nearest target of
  a zone is used (the far one is the ceiling).
- Each frame is read in the layout it was measured with (`frame.layout`;
  the frames in flight around a ZONES switch keep the old one).
- Screen cells: lib/tof_zones.zig's geometry maps the device's zones to
  the screen as the player sees it (flip_x, flip_y, transpose: the
  breakout's mounting, docs/TOF.md deferred question 2; MIRROR in the
  menu sets flip_x). GRID: 3x3. STRIPES: 8 stripes left to right (1x8
  top to bottom if an orientation transposes).
- 1 HAND: the closest valid zone of all plays pitch; volume is fixed
  (full). Pitch stays the nearest zone in both layouts, not the pose's
  near-cluster `height_mm`: a theremin plays the nearest part of the hand,
  a finger pointed down is its tip, and the arm is always further away so
  it never wins; the cluster mean would pull a pointing fingertip's note
  toward the arm above it (lib/tof_pose.zig's pointing-finger test reads
  ~20 mm high). The median of three and the glide in play.zig take out
  the zone-to-zone jitter. The highlight is where the hand is, not that
  zone (M1.2): lib/tof_pose.zig's coverage-weighted centroid of the near
  cluster (M5 arm rejection: a forearm sloping in no longer drags it),
  drawn as a dot, and the cell under it with 0.15 cells of hysteresis
  (`hands.track`; GRID: 41x52 deg wide-map cells; STRIPES: the stripes'
  own centres). Over a hand most zones read about the same distance, so
  the closest one jumps between fingertips, knuckles and forearm and did
  not follow the hand sideways on the badge.
- 2 HAND: the screen's right side plays pitch, the left side volume (a
  classic theremin's pitch antenna is on the right); PITCH HAND LEFT
  swaps them. GRID: the outer columns, the middle column ignored (it sees
  both hands' edges). STRIPES: the outer three stripes of each side, the
  middle two a dead band (the same job). Each side's reading is its
  closest valid zone. A mirrored mounting is `orientation.flip_x`, which
  also swaps the sides; PITCH HAND then restores the player's preference.
  Transposed STRIPES (one column of eight) uses the top and bottom three
  instead.

### 3.3 ZONES (docs/TOF.md M5)

- STRIPES (default): the driver measures through `tof_spad.stripes()`, 8
  full-height stripes 4.8 deg wide (7.2 at the edges) across the 43 deg
  field: side to side about 3x finer than map 6's 13.7 deg columns, which
  the dot shows. GRID: the wide pre-defined map 6 (41x52 deg, 3x3).
- Changing ZONES calls `Tof.set_layout` (stop, pages, MEASURE; ~100 ms on
  the model, no reset), the pose estimator's `set_layout` (its
  background starts afresh: the zones look elsewhere) and resets the
  highlight; the demo hand switches with it. The setting is applied
  before the driver first starts, so a STRIPES boot goes straight to the
  mask.
- If STRIPES looks scrambled or mirrored against GRID on a badge, use
  GRID (docs/TOF.md section 5, M5).

## 4. Mapping (`pitch.zig`, `play.zig`)

- **Distance to pitch:** linear in mm and in cents (so the frequency is
  exponential in distance and equal hand movements are equal intervals):
  60 mm or closer is the top of the range, 480 mm or further the bottom;
  the range is 3 octaves (36 semitones, 11.7 mm per semitone) from the
  KEY in the chosen OCTAVE. Pitches are cents above MIDI note 0; A4 =
  6900 = 440 Hz.
- **Despiking:** the pitch hand's distance goes through a 3-frame median
  per sensor frame (a one-frame spike never sounds).
- **Glide:** per update the pitch closes half its gap to the target (a
  one-pole low-pass at ~6 Hz at 60 Hz updates). It removes the 30 Hz frame
  steps and attenuates sensor jitter (a host test asserts at least half of
  the jitter's power goes) while a 5 Hz hand wobble keeps over half its
  depth (asserted too). The voice glides its phase increment again per
  sample (~12 ms), so the 60 Hz updates are smooth slides, not steps.
- **Scale snap,** relative to KEY: FREE (continuous), CHROM, MAJOR (1 2 3 4
  5 6 7), PENTA (major pentatonic 1 2 3 5 6). SOFT: between two scale
  notes the pitch follows half the identity plus half the curve
  t^3 / (t^3 + (1-t)^3), which is flat at the notes: continuous and
  monotonic, pulled toward the notes, vibrato survives (reduced near a
  note). HARD: the nearest scale note, with 15 cents of hysteresis past
  each midpoint so a hand at a boundary does not warble.
- **Hand absent:** one frame without a hand changes nothing; 3 frames
  (~100 ms) release the note: the level target goes to 0 and the voice
  fades with a 46 ms time constant; the pitch holds where it was. A hand
  returning within 0.2 s (12 updates) of quiet glides from the old note;
  later, the note starts at the hand's own pitch (no slide from the last
  one) with a ~6 ms attack.
- **Volume (2 HAND):** the volume hand at 60 mm or closer is silent, at
  320 mm or further (or absent) full; squared in between so the taper
  sounds even.
- **Stick:** Up/Down taps move to the next scale note from the nearest
  note; held past 15 updates the target glides 8 cents per update rising
  to 40. The note sustains 0.75 s after the last input, then releases. A
  gentle automatic vibrato (+-14 cents, 5.5 Hz) fades in once the pitch
  has settled for 0.3 s; the stick has no hand wobble of its own. The
  pitch bar shows the distance a hand would be at for the stick's pitch.
- Knobs are named constants at the top of `play.zig`, `hands.zig`
  (`Config`) and `pitch.zig` (`Map`).

## 5. Sound (`voice.zig`, `audio.zig`)

- **Format:** the newer firmware's streaming ring (docs/SOUND.md sections
  7 and 8, lib/stream_audio.zig): 44.1 kHz unsigned 8-bit mono, 128 =
  silence. Badge builds never call `cart.tone2`.
- **Voice:** one oscillator, a u32 phase that never resets (pitch changes
  are clickless). SINE: 256-entry Q15 table (tools/gen_tables.py,
  committed) with linear interpolation. TRI: naive (its harmonics fall as
  1/n^2). SAW and SQR: PolyBLEP band-limited edges plus a one-pole
  low-pass (~4.9 kHz) for the small speaker. Peak levels 120, 120, 100,
  84 of 127 so the four sound about equally loud. Changing waveform while
  sounding ducks the level for 128 samples (~3 ms) and switches at the
  bottom, so the shape change never clicks.
- **Glides per sample:** phase increment 1/512 of the gap (11.6 ms);
  level 1/256 (5.8 ms) for attacks and volume moves, 1/2048 (46 ms) for a
  release; the level reaches exactly 0.
- **Integer only per sample:** the render loop is specialised per
  waveform at compile time; PolyBLEP divides only on the one or two
  samples beside an edge. Cost ~25 k cycles per update (bench).
- **Feeding the ring:** every update tops the ring (4096 samples) up to a
  target of 2048 samples (46 ms). The OS takes 512 at a time, so between
  updates the queue falls by 512 or 1024; 2048 rides out one missed frame
  (a 33 ms update). An update that finds fewer than 256 queued (a frame
  slower than that) raises the target by 1024 up to 3584; it creeps back
  128 per 10 s of calm. The voice renders always (silence between notes),
  so the ring never drains and a note never waits behind a cold start.
- **Mute:** a 64-sample gain ramp on the way into the ring; the voice and
  the scope keep running (the scope dims).
- **Wasm:** the pinned simulator has no streaming audio, so the wasm build
  renders the voice only for the scope and re-strikes the simulator's
  `tone` import every update for 3 frames at the voice's pitch (sine and
  triangle on its triangle channel, saw on pulse 25%, square on pulse
  50%; volume follows the level). It follows the hand or stick at 60 Hz
  steps; nothing of the band-limiting or glides is audible there.

## 6. Screen (`screen.zig`, `gfx.zig`)

160x128, `.no_copy_full_frame`, redrawn whole every update at 60 fps.

| Area | Content |
|---|---|
| y 0..9 | status: SENSOR + layout, or STICK + NO SENSOR; SOUND with a speaker (waves while sounding) or a red MUTED |
| x 2..60, y 12..49 | the note name (OS 8x8 font at 2x), a +-50 cent meter (needle green within 8, amber within 25, red beyond), cents and Hz; dim when silent |
| x 62..112, y 12..52 | Snouty, side view, facing the grid |
| x 116..157, y 12..53 | the zones in screen order (3x3 cells, or 8 full-height stripes), coloured by hand distance (blue far, amber near, dark nothing); outlines: cyan pitch (the highlight's cell or stripe in 1 HAND, the side in 2 HAND), magenta volume; "NO TOF" without a sensor |
| x 2..112, y 56..100 | scope: two cycles of the rendered samples, triggered on a rising centre crossing so the trace stands still |
| x 117..156, y 58..99 | P: pitch-hand height (cm); V: volume-hand height in 2 HAND, else the voice's level |
| y 104 | WAVE, SCALE (~ soft, # hard), range (e.g. C3-C6) |
| y 118 | rotating hints |

The settings menu draws over the middle of the screen. All art is code
drawn (repository rule: placeholder art is final).

## 7. Files

- `cart/src/main.zig`: `start`/`update`, buttons, the simulator tone shim,
  the wasm debug exports and the badge-bench poke, the simulator shims.
- `cart/src/input.zig`: the sensor integration point, source selection,
  the demo hand.
- `cart/src/hands.zig`: layouts from a frame (GRID or STRIPES), the
  ZONES enum, the highlight track.
- `cart/src/sensor.zig`: lib/tof.zig on the badge (map 6 for GRID, the
  stripes mask for STRIPES), the model with `-Dtof-fake=true`.
- `cart/src/pitch.zig`: distance map, scale snap, note names, cents to
  phase increment, the median.
- `cart/src/play.zig`: settings, the per-update player (glide, fade,
  stick).
- `cart/src/voice.zig`: the oscillator; `cart/src/audio.zig`: the ring
  feeder.
- `cart/src/screen.zig`, `cart/src/gfx.zig`: drawing.
- `cart/src/gen/`: `tables.zig` (tools/gen_tables.py), `font5x7.zig` and
  `font8.zig` (per-cart copies of paperclips' and snouty-cycles' fonts).
- `cart/src/host_tests.zig`: the root of `zig build test` for the cart.

## 8. Determinism and tests

Everything but drawing and the button glue is pure and host-tested
(`zig build test`): the distance map and its inverse, cents to phase
increment against equal temperament (1 ppm), note names, hard snap per
scale and key, hard-snap hysteresis, soft snap continuity and
monotonicity, the median, layouts from frames with every orientation
flag and handedness in GRID and STRIPES (the 40 mm stripes near limit,
the two-hand sides and dead band, a frame read by its own layout tag),
the highlight track over the grid and the stripes (a synthetic hand
sweeping across the stripes walks all eight in order), the demo hand in
both zone layouts, onset/jump/glide/fade of the player, jitter removed
but vibrato kept, two-hand volume, the stick's steps/glide/sustain/
release, the voice's attack and release ramps (bounded sample steps),
phase continuity through a pitch change, band-limited saw, the waveform
duck, the scope history, and the feeder against a fake OS mixer (steady
60 Hz never underruns, a 35 ms frame never underruns, a 60 ms stall
grows the target so the next one is absorbed, mute ramps). Timing is
update-based; the demo hand is a function of the update count.
